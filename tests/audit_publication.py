#!/usr/bin/env python3
"""Audit a clean source release without printing matched text or secret values.

Optional --private-values accepts an external UTF-8 JSON array of nonempty strings.
Keep that file outside this checkout. It is read locally and is never transmitted.
This conservative check supplements review; it cannot prove the absence of secrets.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote


MAX_SOURCE_BYTES = 2_000_000
FORBIDDEN_SUFFIXES = {
    '.bin', '.elf', '.uf2', '.hex', '.o', '.a', '.dylib', '.so', '.pyc',
    '.dmg', '.pkg', '.zip', '.tar', '.gz', '.7z', '.rar', '.shortcut',
    '.p12', '.pfx', '.pem', '.key', '.keystore', '.sqlite', '.sqlite3', '.db',
    '.log', '.png', '.jpg', '.jpeg', '.heic', '.pdf', '.mov', '.mp4',
}
FORBIDDEN_DIRS = {
    '.local', '.env', '.venv', 'node_modules', '__pycache__', '.pio',
    'build', 'dist', 'backups', 'original-backup',
}
FORBIDDEN_NAMES = {
    '.DS_Store', '.env', '.env.local', '.dev.vars', 'config.json',
    'wake_config.json', 'cloud-secrets.json', 'cloud-endpoint.json',
    'device-info.json', 'unlock_secret.h', 'secrets.json',
}

# These expressions locate candidates. Reports never include the match itself.
RULES = (
    ('private-key', re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----')),
    ('provider-token', re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{25,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})\b')),
    ('personal-home-path', re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+')),
    ('device-mac-address', re.compile(r'(?<![A-Fa-f0-9:])(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}(?![A-Fa-f0-9:])')),
    ('relay-hostname', re.compile(r'\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.workers\.dev\b', re.I)),
    ('private-network-address', re.compile(r'\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b')),
)
SENSITIVE_NAME = (
    r'(?:[A-Za-z0-9_]*_)?(?:password|passwd|pwd|psk|ssid|token|secret|api_key|'
    r'account_id|namespace_id|kv_id|device_id|authorization|wifi_name|wifi_pass|wifi_ssid)'
)
ASSIGNMENT = re.compile(
    r'(?<![A-Za-z0-9_])(?P<name>' + SENSITIVE_NAME + r')[\"\']?\s*[:=]\s*'
    r'@?(?P<quote>[\"\'])(?P<value>[^\"\'\r\n]*)(?P=quote)', re.I,
)
AUTH_LITERAL = re.compile(r'\bBearer\s+(?P<value>[A-Za-z0-9_.~+/=-]{12,})', re.I)


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    rule: str


def placeholder(value: str) -> bool:
    """Allow explicit templates and reserved examples, never arbitrary short values."""
    value = value.strip()
    lower = value.lower()
    if not value:
        return True
    if any(marker in lower for marker in (
        'your_', 'your-', '<', '>', '${', '{{', 'replace_me', 'replace-me',
        'change_me', 'change-me', 'replace_with_', 'example.invalid', '.example',
    )):
        return True
    if lower in {'example', 'placeholder', 'redacted', 'device-id', 'mac-mini'}:
        return True
    return False


def line_number(text: str, offset: int) -> int:
    return text.count('\n', 0, offset) + 1


def private_variants(values: list[str]) -> list[str]:
    """Check literal, JSON-escaped and URL-encoded copies without revealing them."""
    variants: set[str] = set()
    for value in values:
        if value:
            variants.update((value, json.dumps(value, ensure_ascii=True)[1:-1],
                             quote(value, safe='')))
    return sorted(variants, key=len, reverse=True)


def scan(root: Path, private_values: list[str] | None = None) -> dict:
    root = root.resolve()
    findings: set[Finding] = set()
    count = 0
    known = private_variants(private_values or [])

    def safe_path(path: Path) -> str:
        relative = path.relative_to(root).as_posix()
        if any(value in relative for value in known):
            findings.add(Finding('[redacted-path]', 0, 'known-private-value-in-path'))
            return '[redacted-path]'
        return relative

    for parent, dirs, files in os.walk(root, followlinks=False):
        base = Path(parent)
        # A source-tree scan does not inspect Git object history; publish from a new
        # reviewed history or run a separate history audit before reusing old history.
        dirs[:] = sorted(d for d in dirs if d != '.git')
        for name in list(dirs):
            path = base / name
            rel = safe_path(path)
            if path.is_symlink():
                findings.add(Finding(rel, 0, 'symlink'))
                dirs.remove(name)
            elif name in FORBIDDEN_DIRS or name.endswith('.app'):
                findings.add(Finding(rel, 0, 'forbidden-artifact-directory'))
                # Do not read third-party/dependency trees or private local outputs.
                dirs.remove(name)
        for name in sorted(files):
            path = base / name
            rel = safe_path(path)
            count += 1
            if path.is_symlink():
                findings.add(Finding(rel, 0, 'symlink'))
                continue
            is_template = '.example.' in name or name.endswith('.example')
            if (path.suffix.lower() in FORBIDDEN_SUFFIXES or
                    (name in FORBIDDEN_NAMES and not is_template) or
                    name.startswith('.env.') and not is_template):
                findings.add(Finding(rel, 0, 'forbidden-artifact-file'))
            try:
                if path.stat().st_size > MAX_SOURCE_BYTES:
                    findings.add(Finding(rel, 0, 'oversized-source-file'))
                    continue
                data = path.read_bytes()
                if b'\0' in data:
                    findings.add(Finding(rel, 0, 'binary-content'))
                    continue
                source = data.decode('utf-8')
            except UnicodeError:
                findings.add(Finding(rel, 0, 'non-utf8-content'))
                continue
            except OSError:
                findings.add(Finding(rel, 0, 'unreadable-file'))
                continue
            # Even private values inside filenames must not be published. Report a
            # generic location if the filename itself contains a known private value.
            report_path = rel
            for value in known:
                start = 0
                while (at := source.find(value, start)) != -1:
                    findings.add(Finding(report_path, line_number(source, at), 'known-private-value'))
                    start = at + len(value)
            for rule, pattern in RULES:
                for match in pattern.finditer(source):
                    if placeholder(match.group()):
                        continue
                    findings.add(Finding(report_path, line_number(source, match.start()), rule))
            for match in ASSIGNMENT.finditer(source):
                value = match.group('value')
                if match.group('name').lower() == 'authorization' and value.strip().lower() in {'bearer', 'undefined'}:
                    continue
                if not placeholder(value):
                    findings.add(Finding(report_path, line_number(source, match.start()), 'sensitive-literal'))
            for match in AUTH_LITERAL.finditer(source):
                if not placeholder(match.group('value')):
                    findings.add(Finding(report_path, line_number(source, match.start()), 'authorization-literal'))
    return {
        'passed': not findings,
        'files_checked': count,
        'private_values_checked': len(private_values or []),
        'findings': [asdict(finding) for finding in sorted(findings)],
        'scope': 'working-tree source files; excludes .git history',
    }


def scan_staged(root: Path, private_values: list[str] | None = None) -> dict:
    """Audit exact index blobs, excluding ignored working-tree build products."""
    root = root.resolve()

    def git(*args: str) -> bytes:
        try:
            result = subprocess.run(['git', '-C', str(root), *args], check=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            return result.stdout
        except (OSError, subprocess.CalledProcessError):
            raise ValueError('Cannot read Git index; details withheld.') from None

    if Path(os.fsdecode(git('rev-parse', '--show-toplevel')).strip()).resolve() != root:
        raise ValueError('For --staged, --root must be the Git repository root.')
    entries = git('ls-files', '--stage', '-z').split(b'\0')
    exported = 0
    with tempfile.TemporaryDirectory(prefix='publication-index-') as temporary:
        snapshot = Path(temporary)
        for entry in entries:
            if not entry:
                continue
            meta, raw_path = entry.split(b'\t', 1)
            mode, oid, stage = meta.decode('ascii').split()
            relative = Path(os.fsdecode(raw_path))
            if stage != '0' or relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unmerged or invalid Git index entry; details withheld.')
            if mode not in {'100644', '100755', '120000'}:
                raise ValueError('Unsupported Git index mode; source-only publication required.')
            destination = snapshot / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if mode == '120000':
                # No need to recreate the original link target: all links fail review.
                destination.symlink_to('AUDIT_REJECTS_ALL_SYMLINKS')
            else:
                size = int(git('cat-file', '-s', oid).strip())
                if size > MAX_SOURCE_BYTES:
                    with destination.open('wb') as file:
                        file.truncate(MAX_SOURCE_BYTES + 1)
                else:
                    destination.write_bytes(git('cat-file', 'blob', oid))
            exported += 1
        if not exported:
            raise ValueError('The Git index is empty; nothing has been audited for publication.')
        report = scan(snapshot, private_values)
    report['scope'] = 'exact Git index snapshot; excludes unstaged files and past commits'
    return report


def load_private_values(path: Path, root: Path) -> list[str]:
    path = path.expanduser().resolve()
    if path.is_relative_to(root.resolve()):
        raise ValueError('Private-value input must be outside the publication tree.')
    try:
        values = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, UnicodeError, ValueError):
        raise ValueError('Cannot read private-value input; details withheld.') from None
    if not isinstance(values, list) or not all(isinstance(v, str) and v for v in values):
        raise ValueError('Private-value input must be a JSON array of nonempty strings.')
    return list(dict.fromkeys(values))


def self_test() -> None:
    # Synthetic markers only. Deliberate split strings keep this test source clean.
    canary = 'synthetic-' + 'private-canary-for-tests'
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        p = root / 'sample.txt'
        p.write_text('SSID = "YOUR_WIFI_SSID"\nTOKEN = "YOUR_CLIENT_TOKEN"\n', encoding='utf-8')
        assert scan(root)['passed']
        p.write_text('SSID = "' + 'synthetic-wireless-name' + '"\n' + canary, encoding='utf-8')
        result = scan(root, [canary])
        assert {'sensitive-literal', 'known-private-value'} <= {f['rule'] for f in result['findings']}
        assert canary not in json.dumps(result)
        p.write_text('A path: /' + 'Users/test-person/Desktop\n', encoding='utf-8')
        assert any(f['rule'] == 'personal-home-path' for f in scan(root)['findings'])
        p.unlink()
        (root / 'dump.bin').write_bytes(b'\0\1')
        assert any(f['rule'] == 'binary-content' for f in scan(root)['findings'])
        (root / 'dump.bin').unlink()
        (root / 'private.json').write_text(json.dumps([canary]), encoding='utf-8')
        try:
            load_private_values(root / 'private.json', root)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted a private corpus inside the public tree')
        (root / 'private.json').unlink()
        private_name = root / (canary + '.bin')
        private_name.write_bytes(b'\0')
        assert canary not in json.dumps(scan(root, [canary]))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        def git_test(*args: str) -> None:
            subprocess.run(['git', '-C', str(root), *args], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git_test('init', '-q')
        (root / 'safe.txt').write_text('Safe staged content', encoding='utf-8')
        git_test('add', 'safe.txt')
        (root / 'safe.txt').write_text(canary, encoding='utf-8')
        assert scan_staged(root, [canary])['passed']
        assert not scan(root, [canary])['passed']
        git_test('add', 'safe.txt')
        assert not scan_staged(root, [canary])['passed']
    print('Publication audit self-test passed (synthetic values only).')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--private-values', type=Path,
                        help='External local JSON array; values never appear in output.')
    parser.add_argument('--json', action='store_true', help='Print a redacted JSON report.')
    parser.add_argument('--staged', action='store_true', help='Audit the exact Git index snapshot.')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.root.is_dir():
        parser.error('The source root must be an existing directory.')
    try:
        values = load_private_values(args.private_values, args.root) if args.private_values else []
    except ValueError as error:
        parser.error(str(error))
    try:
        report = scan_staged(args.root, values) if args.staged else scan(args.root, values)
    except ValueError as error:
        parser.error(str(error))
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for finding in report['findings']:
            print(f"{finding['path']}:{finding['line']}: {finding['rule']} [value withheld]")
        print(f"{'PASS' if report['passed'] else 'FAIL'}: {report['files_checked']} files; "
              f"{len(report['findings'])} findings; {report['private_values_checked']} private values checked.")
        print('Scope: ' + report['scope'] + '.')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
