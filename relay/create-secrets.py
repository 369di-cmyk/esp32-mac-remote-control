#!/usr/bin/env python3
"""Create local relay secrets without printing their values. Never commit the output."""
import json
import os
from pathlib import Path
import secrets

destination = Path(__file__).resolve().parents[1] / ".local" / "relay-secrets.json"
destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
try:
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit("Already exists; no secrets overwritten / 文件已存在，未覆盖。")
with os.fdopen(descriptor, "w") as output:
    json.dump({"DEVICE_TOKEN": secrets.token_hex(32), "PHONE_TOKEN": secrets.token_hex(32)}, output, indent=2)
    output.write("\n")
print("Created local secret file / 已创建本地密钥文件:", destination)
