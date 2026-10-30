#!/usr/bin/env python3
"""Explicit local installation only; never called by tests or builds."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, default=Path('.local/shortcuts.json'))
    parser.add_argument('--replace', action='store_true', help='Replace an earlier public-project installation')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source = repo / 'generated/Mac Wake Unlock.app'
    config = json.loads(args.config.read_text())
    token = config.get('unlock_request_token', '')
    if not isinstance(token, str) or len(token) < 32 or '|' in token:
        parser.error('Generate local configuration first: python3 scripts/configure.py')
    if not source.is_dir():
        parser.error('Build first: bash macos/unlock/build.sh')
    home = Path.home()
    target = home / 'Applications/Mac Wake Unlock.app'
    support = home / 'Library/Application Support/ESP32MacRemoteUnlock'
    plist = home / 'Library/LaunchAgents/io.github.esp32macremote.unlock.plist'
    if target.exists() and not args.replace:
        parser.error('Already installed; use --replace to update this project installation.')
    if support.exists() and (support/'config.json').exists():
        old = json.loads((support/'config.json').read_text())
        if old.get('request_token') != token:
            parser.error('Existing request token differs. Preserve it in your local shortcut config before updating.')
    os.umask(0o077)
    plist.parent.mkdir(parents=True, exist_ok=True)
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    target.parent.mkdir(parents=True, exist_ok=True)
    if plist.exists():
        subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}', str(plist)], capture_output=True)
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    (support/'config.json').write_text(json.dumps({'request_token': token})+'\n')
    (support/'config.json').chmod(0o600)
    with plist.open('wb') as f:
        plistlib.dump({'Label': 'io.github.esp32macremote.unlock',
            'ProgramArguments': [str(target/'Contents/MacOS/MacWakeUnlock'), '--background'],
            'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False},
            'ProcessType': 'Interactive'}, f)
    subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)], check=True)
    print('Installed. Use the menu-bar icon to complete Accessibility, iCloud folder access, and password setup locally.')

if __name__ == '__main__':
    main()
