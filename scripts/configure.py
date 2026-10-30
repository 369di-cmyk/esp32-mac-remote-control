#!/usr/bin/env python3
"""Generate private local Shortcut settings. Never reads a Mac login password."""
import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
from urllib.parse import urlsplit

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('.local/shortcuts.json'))
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Configuration already exists; preserve it or choose another output path.')
    url = input('Your HTTPS relay URL / 你的 HTTPS 转发地址: ').strip().rstrip('/')
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        parser.error('Use an HTTPS base URL without credentials, query, or fragment.')
    token = getpass.getpass('Relay client token / 转发服务的客户端令牌 (hidden): ').strip()
    if len(token) < 32 or not token.isascii() or not token.isprintable() or '|' in token:
        parser.error('Use a printable ASCII client token of at least 32 characters.')
    os.umask(0o077)
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with args.output.open('x') as f:
        json.dump({'relay_url': url, 'client_token': token,
                   'unlock_request_token': secrets.token_urlsafe(32)}, f, indent=2)
        f.write('\n')
    args.output.chmod(0o600)
    print('Private configuration saved locally. Do not upload it or generated Shortcuts.')

if __name__ == '__main__':
    main()
