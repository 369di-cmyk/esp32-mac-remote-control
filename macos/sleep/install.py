#!/usr/bin/env python3
"""Explicit two-stage installer. Never invoked by builds or tests."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[1]
LABEL = 'io.github.esp32macremote.sleep'
AGENT = 'io.github.esp32macremote.sleep-sync'


def run(*args, check=True):
    subprocess.run(args, check=check)


def write(path, content, mode=0o644):
    path = Path(path)
    if path.is_symlink():
        raise SystemExit('Refusing a symbolic-link destination: ' + str(path))
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(content)
    temporary.chmod(mode)
    temporary.replace(path)


def system_install(username):
    if os.geteuid() != 0:
        raise SystemExit('Run the --system stage with sudo; see docs/sleep-shortcuts.md.')
    account = pwd.getpwnam(username)
    home = Path(account.pw_dir)
    if account.pw_uid < 500 or not home.is_absolute() or home.is_symlink() or home.stat().st_uid != account.pw_uid:
        raise SystemExit('Select a normal local login account with its own home directory.')
    service = Path('/Library/Application Support/ESP32MacRemoteSleep')
    state = Path('/var/db') / LABEL
    for directory in (service, state):
        if directory.is_symlink() or (directory.exists() and directory.stat().st_uid != 0):
            raise SystemExit('Refusing an unsafe system directory: ' + str(directory))
        directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        directory.chmod(0o755)
        os.chown(directory, 0, 0)
    run('/usr/bin/perl', '-c', str(SOURCE / 'apply.pl'))
    write(service / 'apply.pl', (SOURCE / 'apply.pl').read_bytes())
    write(service / 'receiver.json', json.dumps({'uid': account.pw_uid, 'home': str(home)}).encode(), 0o600)
    daemon = Path('/Library/LaunchDaemons') / (LABEL + '.plist')
    write(daemon, plistlib.dumps({
        'Label': LABEL, 'ProgramArguments': ['/usr/bin/perl', str(service / 'apply.pl')],
        'StartInterval': 30, 'RunAtLoad': True, 'LowPriorityIO': True,
        'ProcessType': 'Background', 'StandardOutPath': '/dev/null',
        'StandardErrorPath': '/var/log/' + LABEL + '.log',
    }))
    run('/bin/launchctl', 'bootout', 'system/' + LABEL, check=False)
    run('/bin/launchctl', 'bootstrap', 'system', str(daemon))
    print('System receiver installed. Continue the normal-user stage. / 系统接收器已安装，请继续普通用户步骤。')


def user_install(app):
    if os.geteuid() == 0:
        raise SystemExit('Run the app installation without sudo.')
    if not (app / 'Contents/MacOS/MacSleepSync').is_file():
        raise SystemExit('Build the app first: zsh macos/sleep/build.sh')
    home = Path.home()
    applications = home / 'Applications'
    applications.mkdir(exist_ok=True)
    destination = applications / 'Mac Sleep Sync.app'
    if destination.exists():
        raise SystemExit('App already exists. Quit it and move it aside before reinstalling: ' + str(destination))
    shutil.copytree(app, destination)
    local = home / 'Library/Application Support/MacSleepControl'
    local.mkdir(mode=0o700, parents=True, exist_ok=True)
    local.chmod(0o700)
    cloud = home / 'Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/MacSleepControl'
    cloud.mkdir(parents=True, exist_ok=True)
    agents = home / 'Library/LaunchAgents'
    agents.mkdir(parents=True, exist_ok=True)
    (home / 'Library/Logs').mkdir(parents=True, exist_ok=True)
    agent = agents / (AGENT + '.plist')
    write(agent, plistlib.dumps({
        'Label': AGENT, 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False},
        'ProcessType': 'Interactive',
        'ProgramArguments': [str(destination / 'Contents/MacOS/MacSleepSync')],
        'StandardOutPath': '/dev/null',
        'StandardErrorPath': str(home / 'Library/Logs' / (AGENT + '.log')),
    }))
    domain = 'gui/' + str(os.getuid())
    run('/bin/launchctl', 'bootout', domain + '/' + AGENT, check=False)
    run('/bin/launchctl', 'bootstrap', domain, str(agent))
    print('Choose the dedicated MacSleepControl folder in the app. / 请在应用中选择专用 MacSleepControl 文件夹。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--system', metavar='LOCAL_USERNAME', help='Install the root sleep receiver for this account (requires sudo).')
    parser.add_argument('--app', type=Path, default=ROOT / 'generated/apps/Mac Sleep Sync.app')
    args = parser.parse_args()
    if args.system:
        system_install(args.system)
    else:
        user_install(args.app)


if __name__ == '__main__':
    main()
