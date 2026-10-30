"""Offline tests: create synthetic plists only; no HTTP, Shortcuts, sleep or login actions."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shortcut_generator', ROOT / 'shortcuts/generate.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)
TEST_PHONE_TOKEN = secrets.token_hex(32)
TEST_UNLOCK_TOKEN = secrets.token_hex(32)


def config():
    return {'relay_url': 'https://relay.unit.test', 'client_token': TEST_PHONE_TOKEN,
            'unlock_request_token': TEST_UNLOCK_TOKEN}


def walk(value):
    yield value
    if isinstance(value, dict):
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def actions(flow, action):
    return [item['WFWorkflowActionParameters'] for item in flow['WFWorkflowActions']
            if item['WFWorkflowActionIdentifier'] == 'is.workflow.actions.' + action]


class ShortcutTests(unittest.TestCase):
    def setUp(self):
        self.flows = generator.build_flows(config())

    def test_exact_five_distinct_icons(self):
        self.assertEqual(set(self.flows), set(generator.ICONS))
        self.assertEqual(len(self.flows), 5)
        icons = [flow['WFWorkflowIcon'] for flow in self.flows.values()]
        self.assertEqual(len({icon['WFWorkflowIconStartColor'] for icon in icons}), 5)
        self.assertEqual(len({icon['WFWorkflowIconGlyphNumber'] for icon in icons}), 5)

    def test_all_references_resolve_to_earlier_actions(self):
        for flow in self.flows.values():
            defined = set()
            for action in flow['WFWorkflowActions']:
                parameters = action['WFWorkflowActionParameters']
                for item in walk(parameters):
                    if isinstance(item, dict) and item.get('Type') == 'ActionOutput':
                        self.assertIn(item['OutputUUID'], defined)
                if 'UUID' in parameters:
                    self.assertNotIn(parameters['UUID'], defined)
                    defined.add(parameters['UUID'])

    def test_control_groups_balance(self):
        for flow in self.flows.values():
            stack = []
            for action in flow['WFWorkflowActions']:
                parameters = action['WFWorkflowActionParameters']
                if 'WFControlFlowMode' not in parameters:
                    continue
                mode = parameters['WFControlFlowMode']
                group = parameters['GroupingIdentifier']
                if mode == 0:
                    stack.append(group)
                else:
                    self.assertEqual(stack[-1], group)
                    if mode == 2:
                        stack.pop()
            self.assertEqual(stack, [])

    def test_idle_choices_and_nonce(self):
        flow = self.flows['Mac自动睡眠']
        payloads = actions(flow, 'gettext')
        self.assertEqual([p['WFTextActionText']['Value']['string'] for p in payloads],
                         [str(m) + '|\ufffc' for m in generator.MINUTES])
        for flow in self.flows.values():
            for nonce in actions(flow, 'number.random'):
                self.assertEqual((nonce['WFRandomNumberMinimum'], nonce['WFRandomNumberMaximum']),
                                 (100000000, 999999999))

    def test_dated_requests_use_formatted_date_output(self):
        for name in ('Mac远程睡眠', 'Mac在线查询', 'Mac 唤醒并解锁'):
            flow = self.flows[name]
            date, = actions(flow, 'date')
            formatted, = actions(flow, 'format.date')
            self.assertEqual(formatted['WFDateFormat'], "yyyy-MM-dd'T'HH:mm:ssXXX")
            self.assertEqual(formatted['WFDate']['Value']['attachmentsByRange']['{0, 1}']['OutputUUID'], date['UUID'])
            payload, = actions(flow, 'gettext')
            attachments = payload['WFTextActionText']['Value']['attachmentsByRange'].values()
            self.assertIn(formatted['UUID'], [item['OutputUUID'] for item in attachments])

    def test_receipts_match_exact_nonce_line(self):
        for name in ('Mac在线查询', 'Mac 唤醒并解锁'):
            flow = self.flows[name]
            nonce, = actions(flow, 'number.random')
            condition = actions(flow, 'conditional')[0]['WFConditionalActionString']['Value']
            self.assertEqual(condition['string'], '请求码：\ufffc\n')
            self.assertEqual(next(iter(condition['attachmentsByRange'].values()))['OutputUUID'], nonce['UUID'])
            self.assertEqual(actions(flow, 'delay')[0]['WFDelayTime'], 40)

    def test_only_unlock_shortcut_contains_unlock_token(self):
        for name, flow in self.flows.items():
            serialized = plistlib.dumps(flow).decode()
            self.assertEqual(config()['unlock_request_token'] in serialized, name == 'Mac 唤醒并解锁')
            self.assertEqual(config()['client_token'] in serialized, name in ('Mac蓝牙唤醒', 'Mac 唤醒并解锁'))
            self.assertNotIn('login_password', serialized)

    def test_wake_uses_https_post_empty_json_and_bearer(self):
        for name in ('Mac蓝牙唤醒', 'Mac 唤醒并解锁'):
            request, = actions(self.flows[name], 'downloadurl')
            self.assertEqual(request['WFURL'], config()['relay_url'] + '/v1/wake')
            self.assertEqual(request['WFHTTPMethod'], 'POST')
            self.assertEqual(request['WFHTTPBodyType'], 'JSON')
            self.assertEqual(request['WFJSONValues']['Value']['WFDictionaryFieldValueItems'], [])
            header, = request['WFHTTPHeaders']['Value']['WFDictionaryFieldValueItems']
            self.assertEqual(header['WFKey']['Value']['string'], 'Authorization')
            self.assertEqual(header['WFValue']['Value']['string'], 'Bearer ' + config()['client_token'])

    def test_token_offsets_are_utf16(self):
        value = generator.text('🟢 \ufffc', ('test-uuid', 'Test'))['Value']
        self.assertEqual(set(value['attachmentsByRange']), {'{3, 1}'})

    def test_config_rejects_placeholders_and_unsafe_fields(self):
        generator.validate_config(config())
        for key, bad in (('relay_url', 'https://YOUR_WORKER.example.invalid'),
                         ('relay_url', 'http://relay.unit.test'),
                         ('relay_url', 'https://user:pass@relay.unit.test'),
                         ('relay_url', 'https://relay.unit.test?token=anything'),
                         ('client_token', 'REPLACE_ME'),
                         ('client_token', 'c' * 40 + '\n'),
                         ('unlock_request_token', 'd' * 40 + '|injected')):
            value = config()
            value[key] = bad
            with self.assertRaises(ValueError):
                generator.validate_config(value)

    def test_generate_roundtrip_private_modes_no_placeholders(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'shortcuts'
            generator.generate(config(), output)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            files = list(output.glob('*.shortcut'))
            self.assertEqual(len(files), 5)
            for path in files:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                data = path.read_bytes()
                self.assertIsInstance(plistlib.loads(data), dict)
                for placeholder in (b'REPLACE_ME', b'YOUR_', b'example.invalid'):
                    self.assertNotIn(placeholder, data)

    def test_symlink_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'real').mkdir()
            (root / 'linked').symlink_to(root / 'real', target_is_directory=True)
            with self.assertRaises(ValueError):
                generator.generate(config(), root / 'linked')


if __name__ == '__main__':
    unittest.main()
