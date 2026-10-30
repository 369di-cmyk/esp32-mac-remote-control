# 验证范围与复测 / Validation and retesting

截至 2026-10-30。原型的真实硬件测试与公开版离线测试分开记录；公开版更换了通用应用标识、安装路径和配置流程，未替换作者当前运行的助手。 / As of 2026-10-30. Prototype hardware results and public-source offline checks are recorded separately. The public version uses generic application identifiers, installation paths, and configuration; it did not replace the author’s running helper.

| 项目 / Item | 结果 / Result |
|---|---|
| 原型真实密码锁屏 → 本机密码输入 → 桌面 / Prototype real lock screen → local entry → desktop | 已确认 / Confirmed |
| 原型手机快捷指令亮屏并进入桌面 / Prototype iPhone Shortcut lights screen and reaches desktop | 用户确认 / User confirmed |
| ESP32 独立 USB 电源后蓝牙重连 / BLE reconnect after moving ESP32 to independent USB power | 已确认 / Confirmed |
| 独立电源试验中的自动解锁 / Automatic unlock in the independent-power trial | 助手确认退出锁屏 / Helper confirmed unlocked state |
| 独立电源、持续系统睡眠后、仅靠蓝牙唤醒的完整链路 / Independent-power, sustained-system-sleep, Bluetooth-only wake chain | 尚缺完整系统电源日志证据 / Complete power-log evidence still missing |
| 公开版本机助手构建与核心离线测试 / Public helper build and offline core tests | 通过；没有真实输入或钥匙串读取 / Passed; no real input or Keychain reads |

USB 连接试验的实际系统睡眠仅约一秒，唤醒记录包含 USB/HID 活动，因此不能据此排除 USB 的影响。独立供电试验确认了解锁，但没有获得与手机请求顺序一致的完整系统睡眠记录。 / The USB-connected trial showed about one second of actual system sleep, with USB/HID wake activity, so it cannot rule out USB involvement. The independent-power trial confirmed unlock but did not yield a complete system-sleep sequence aligned with the phone request.

公开版额外检查：ESP32 固件编译通过（ESP32 core 3.3.12，程序约 1.96 MB）；睡眠同步应用编译通过；快捷指令生成器 12 项离线测试通过；云端转发 8 组离线测试通过。没有部署转发服务、刷写用户设备或运行真实解锁测试。 / Additional public-source checks: ESP32 firmware compiled (ESP32 core 3.3.12, about 1.96 MB); sleep-sync app compiled; all 12 Shortcut tests and 8 relay test groups passed. No relay deployment, device flashing, or live unlock test was performed for this source release.

## 离线检查 / Offline checks

```sh
bash macos/unlock/build.sh
bash tests/test_unlock.sh
python3 tests/audit_publication.py --staged  # after staging the source files
```

其他组件的测试命令见相应教程。核心测试覆盖锁屏未知/冲突状态、用户身份、目标白名单、字符边界、定向事件构造、取消与模拟投递；它们不会验证你的蓝牙接收距离或系统是否接受密码。 / See the component guides for their tests. Core tests cover unknown/conflicting lock states, user identity, the target allowlist, character boundaries, event construction, cancellation, and mocked delivery. They do not verify Bluetooth range or whether your system accepts a password.

## 实际复测 / End-to-end retest

1. 在电脑旁完成配置，先运行在线查询，确认本次请求码匹配。 / Set up beside the Mac and verify a fresh matching online receipt.
2. 将 ESP32 接到独立电源，确认蓝牙连接，拔除与 Mac 的 USB 数据线。 / Power the ESP32 independently, confirm Bluetooth connection, and remove any USB data connection to the Mac.
3. 关闭 Caps Lock，锁屏。不要把“ChatGPT is Using your Mac”遮罩误认为真正的密码界面。 / Disable Caps Lock and lock. Do not mistake the “ChatGPT is Using your Mac” overlay for the actual password screen.
4. 请求系统睡眠，等待至少 90 秒，并通过 `pmset -g log` 确认发生了系统 Sleep。只熄屏不算。 / Request system sleep, wait at least 90 seconds, and confirm a system Sleep event with `pmset -g log`. Display-off alone is insufficient.
5. 用手机蜂窝网络运行一次唤醒并解锁；测试期间不要触碰 Mac，也不要开启会操控桌面的远程会话。 / Run wake-and-unlock once over cellular data. Do not touch the Mac or start a desktop-control session during the test.
6. 核对屏幕、对应请求的助手回执以及 Sleep→Wake→解锁的时间顺序。任何环节缺证据都记作未确认，不自动重试密码。 / Check the screen, matching helper receipt, and Sleep→Wake→unlock ordering. Mark missing evidence as unconfirmed; do not automatically retry passwords.

`pmset` 的设置值不保证电脑真的睡眠：正在运行的任务可能持有电源断言。转发服务的成功响应仅表示接受请求，ESP32 的发送计数仅表示发出了 HID 事件。 / A `pmset` timer does not guarantee sleep; running tasks can hold power assertions. A relay response confirms request acceptance, and an ESP32 send counter confirms HID transmission only.
