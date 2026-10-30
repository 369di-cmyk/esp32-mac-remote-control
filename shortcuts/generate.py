#!/usr/bin/env python3
"""Build five local, unsigned Apple Shortcuts. Never executes a shortcut."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
MINUTES = (20, 30, 50, 60, 120, 180, 240, 300)
# Glyph numbers checked against native Shortcuts metadata. Colors are RGBA.
ICONS = {
    'Mac自动睡眠': (0x8E8E93FF, 61512),       # gray timer
    'Mac远程睡眠': (0x7B72E9FF, 59782),       # purple moon
    'Mac在线查询': (0x1B9AF7FF, 59772),       # blue magnifying glass
    'Mac蓝牙唤醒': (0xFD6631FF, 59845),       # orange sun
    'Mac 唤醒并解锁': (0x34C759FF, 59862),    # green open lock
}


def uid():
    return str(uuid.uuid4()).upper()


def act(name, **parameters):
    return {'WFWorkflowActionIdentifier': 'is.workflow.actions.' + name,
            'WFWorkflowActionParameters': parameters}


def ref(identifier, name='文本'):
    return {'WFSerializationType': 'WFTextTokenAttachment',
            'Value': {'Type': 'ActionOutput', 'OutputUUID': identifier, 'OutputName': name}}


def text(value, *references):
    attachments, start = {}, 0
    for identifier, name in references:
        index = value.index('\ufffc', start)
        # Shortcuts ranges are UTF-16 offsets, including when UI text has emoji.
        position = len(value[:index].encode('utf-16-le')) // 2
        attachments['{%d, 1}' % position] = {
            'Type': 'ActionOutput', 'OutputUUID': identifier, 'OutputName': name}
        start = index + 1
    if value.count('\ufffc') != len(references):
        raise ValueError('Unbound text attachment')
    return {'WFSerializationType': 'WFTextTokenString',
            'Value': {'string': value, 'attachmentsByRange': attachments}}


def flow(name, actions):
    color, glyph = ICONS[name]
    return {'WFWorkflowClientVersion': '4000', 'WFWorkflowMinimumClientVersion': 900,
            'WFWorkflowMinimumClientVersionString': '900',
            'WFWorkflowIcon': {'WFWorkflowIconStartColor': color, 'WFWorkflowIconGlyphNumber': glyph},
            'WFWorkflowActions': actions, 'WFWorkflowInputContentItemClasses': [],
            'WFWorkflowOutputContentItemClasses': [], 'WFWorkflowTypes': [],
            'WFWorkflowHasOutputFallback': False}


def read_result(filename):
    file_id, output = uid(), uid()
    return [act('documentpicker.open', WFGetFilePath='MacSleepControl/' + filename,
                WFGetFileErrorIfNotFound=False, UUID=file_id),
            act('detect.text', WFInput=ref(file_id, '文件'), UUID=output)], output


def send(command='', filename='request.txt', dated=False, token=None):
    nonce, output = uid(), uid()
    actions = [act('number.random', WFRandomNumberMinimum=100000000,
                   WFRandomNumberMaximum=999999999, UUID=nonce)]
    prefix = command + '|' if command else ''
    if dated:
        date, formatted = uid(), uid()
        actions += [act('date', UUID=date), act('format.date',
                    WFDateFormatStyle='Custom', WFTimeFormatStyle='None',
                    WFDateFormat="yyyy-MM-dd'T'HH:mm:ssXXX",
                    WFDate=text('\ufffc', (date, '日期')), UUID=formatted)]
        value = text(prefix + '\ufffc|\ufffc' + ('|' + token if token else ''),
                     (nonce, '随机数'), (formatted, '格式化日期'))
    else:
        if token:
            raise ValueError('Authenticated requests must have an issue date')
        value = text(prefix + '\ufffc', (nonce, '随机数'))
    actions += [act('gettext', WFTextActionText=value, UUID=output),
                act('documentpicker.save', WFInput=ref(output), WFAskWhereToSave=False,
                    WFSaveFileOverwrite=True, WFFileDestinationPath='MacSleepControl/' + filename)]
    return actions, nonce


def wake(config):
    url_id, output = uid(), uid()
    url = config['relay_url'].rstrip('/') + '/v1/wake'
    dictionary = lambda values: {'WFSerializationType': 'WFDictionaryFieldValue',
                                 'Value': {'WFDictionaryFieldValueItems': values}}
    header = {'WFKey': text('Authorization'), 'WFItemType': 0,
              'WFValue': text('Bearer ' + config['client_token'])}
    return [act('url', WFURLActionURL=url, UUID=url_id),
            act('downloadurl', WFHTTPMethod='POST', WFHTTPBodyType='JSON',
                WFJSONValues=dictionary([]), WFHTTPHeaders=dictionary([header]),
                WFInput=ref(url_id, 'URL'), WFURL=url, UUID=output)]


def match_receipt(actions, nonce, filename, missing):
    actions += [act('delay', WFDelayTime=40)]
    steps, result = read_result(filename)
    actions += steps
    group = uid()
    actions += [act('conditional', WFControlFlowMode=0, GroupingIdentifier=group,
                    WFInput={'Type': 'Variable', 'Variable': ref(result)}, WFCondition=99,
                    WFConditionalLegacyComparisonBehavior=True,
                    WFConditionalActionString=text('请求码：\ufffc\n', (nonce, '随机数'))),
                act('showresult', Text=text('\ufffc', (result, '文本'))),
                act('conditional', WFControlFlowMode=1, GroupingIdentifier=group),
                act('showresult', Text=missing),
                act('conditional', WFControlFlowMode=2, GroupingIdentifier=group)]


def build_flows(config):
    workflows = {}
    titles = [f'闲置 {m} 分钟后睡眠' for m in MINUTES]
    group = uid()
    actions = [act('comment', WFCommentActionText='调整闲置睡眠时间，不是倒计时。Mac 需已开机、登录并连接 iCloud。'),
               act('choosefrommenu', WFControlFlowMode=0, GroupingIdentifier=group,
                   WFMenuItems=titles + ['查看 Mac 执行结果'], WFMenuPrompt='Mac 闲置多久后自动睡眠？')]
    for minutes, title in zip(MINUTES, titles):
        actions += [act('choosefrommenu', WFControlFlowMode=1, GroupingIdentifier=group, WFMenuItemTitle=title)]
        steps, nonce = send(str(minutes))
        actions += steps + [act('alert', WFAlertActionTitle='设置请求已发送',
                               WFAlertActionMessage=text(f'闲置 {minutes} 分钟后睡眠\n请求码：\ufffc\n稍后查看回执并核对请求码。这不是已执行确认。', (nonce, '随机数')),
                               WFAlertActionCancelButtonShown=False)]
    steps, result = read_result('status.txt')
    actions += [act('choosefrommenu', WFControlFlowMode=1, GroupingIdentifier=group, WFMenuItemTitle='查看 Mac 执行结果')]
    actions += steps + [act('showresult', Text=text('\ufffc', (result, '文本'))),
                        act('choosefrommenu', WFControlFlowMode=2, GroupingIdentifier=group)]
    workflows['Mac自动睡眠'] = flow('Mac自动睡眠', actions)

    actions = [act('alert', WFAlertActionTitle='让 Mac 现在睡眠？',
                   WFAlertActionMessage='Mac 接收后约 8 秒请求系统睡眠，远程连接可能中断。之后可用“Mac蓝牙唤醒”。',
                   WFAlertActionCancelButtonShown=True)]
    steps, nonce = send('sleep', dated=True)
    actions += steps + [act('showresult', Text=text('睡眠请求已发送。\n请求码：\ufffc\n2 分钟内未收到的请求会失效。请在“Mac自动睡眠”中查看回执；回执不独立证明 Mac 已经入睡。', (nonce, '随机数')))]
    workflows['Mac远程睡眠'] = flow('Mac远程睡眠', actions)

    actions, nonce = send(filename='ping.txt', dated=True)
    match_receipt(actions, nonce, 'online.txt', '尚未收到本次在线查询回复。可能是睡眠、关机、断网、助手未运行或 iCloud 延迟；未回复不等于离线。')
    workflows['Mac在线查询'] = flow('Mac在线查询', actions)

    actions = wake(config)
    response = actions[-1]['WFWorkflowActionParameters']['UUID']
    actions += [act('showresult', Text=text('唤醒中继返回：\n\ufffc\n\n中继回执不代表 Mac 已经亮屏；请运行“Mac在线查询”或检查远程会话。', (response, 'URL 的内容')))]
    workflows['Mac蓝牙唤醒'] = flow('Mac蓝牙唤醒', actions)

    actions = [act('comment', WFCommentActionText='先通过 ESP32 蓝牙唤醒，再发送有时限的解锁请求。登录密码仅保存在 Mac 钥匙串中。解锁权限令牌在本快捷指令及专用 iCloud 文件中，务必保密。')]
    actions += wake(config)
    steps, nonce = send(filename='unlock-request.txt', dated=True, token=config['unlock_request_token'])
    actions += steps
    match_receipt(actions, nonce, 'unlock-result.txt', '尚未收到本次解锁回执。iCloud 延迟、助手未运行或保护检查均可能导致未执行；这不代表已解锁。请求在 90 秒后失效，请在 Mac 查看助手状态。')
    workflows['Mac 唤醒并解锁'] = flow('Mac 唤醒并解锁', actions)
    return workflows


def validate_config(config):
    if not isinstance(config, dict):
        raise ValueError('Configuration must be a JSON object')
    for key in ('relay_url', 'client_token', 'unlock_request_token'):
        value = config.get(key)
        if not isinstance(value, str) or not value or value != value.strip():
            raise ValueError('Missing or invalid configuration field: ' + key)
        if re.search(r'[\r\n\x00\ufffc<>]', value) or any(word in value.lower() for word in ('replace_me', 'your_', 'placeholder')):
            raise ValueError('Replace the placeholder locally: ' + key)
    parts = urlsplit(config['relay_url'])
    if (parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or
            parts.query or parts.fragment or parts.path not in ('', '/') or parts.hostname.endswith('.invalid')):
        raise ValueError('relay_url must be an HTTPS origin, without credentials, path, query or fragment')
    for key in ('client_token', 'unlock_request_token'):
        if len(config[key]) < 32 or '|' in config[key]:
            raise ValueError('Token must contain at least 32 characters and no pipe: ' + key)
    return config


def generate(config, output):
    validate_config(config)
    output = Path(output)
    if output.is_symlink():
        raise ValueError('Output must not be a symbolic link')
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.chmod(0o700)
    for name, workflow in build_flows(config).items():
        path = output / (name + '.shortcut')
        # O_NOFOLLOW prevents replacing a link to an unrelated local file.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            plistlib.dump(workflow, stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.local/shortcuts.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'generated/shortcuts')
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        generate(config, args.output)
    except (ValueError, OSError) as error:
        # Do not include JSON content or credential values in diagnostics.
        raise SystemExit('Generation failed. Check local configuration and paths. ' + type(error).__name__) from None
    print('Created five unsigned shortcuts locally. They contain access tokens; do not upload or share them.')


if __name__ == '__main__':
    main()
