# ESP32 与云端中转 / ESP32 and relay

## 工作方式 / How it works

手机通过 HTTPS 向自己的 Cloudflare Worker 提交唤醒请求；ESP32 每约 3 秒轮询一次，再向已配对的 Mac 发送一次蓝牙键盘 Shift 按下与松开。ESP32 需要独立持续供电、互联网连接和 Mac 附近的蓝牙覆盖。Mac 不需要与 ESP32 连接同一个 Wi-Fi，也不用为此修改 Mac 网络。

The phone submits an HTTPS wake request to your Cloudflare Worker. The ESP32 polls about every 3 seconds, then sends one Shift press and release to its paired Mac over Bluetooth. The ESP32 needs continuous power, internet access, and Bluetooth range to the Mac. The Mac does not need to share the ESP32's Wi-Fi network or change its network settings.

固件只有唤醒能力，不接收、保存或输入 Mac 登录密码；锁屏检查及自动输入由本机助手完成。这里的“唤醒”指睡眠恢复，不是断电开机，也不能代替重启后的 FileVault 首次解锁。

Firmware only wakes the Mac. It never receives, stores, or types the Mac login password. Lock-state checking and optional password entry run in the local Mac helper. Wake means resuming from sleep; it does not power on a shut-down Mac or handle the initial FileVault login after restart.

## 硬件与编译 / Hardware and build

已编译验证：经典 ESP32 的 AI Thinker ESP32-CAM，Arduino ESP32 core **3.3.12**，ArduinoJson **7.4.3**。相机不使用。启用 PSRAM，TLS 缓冲优先使用 PSRAM；服务器证书仍正常验证。其他带 BLE 的 ESP32 板型需要自行验证内存、引脚与蓝牙行为；不能把不同芯片的固件互刷。

Compile-checked target: classic ESP32 AI Thinker ESP32-CAM, Arduino ESP32 core **3.3.12**, ArduinoJson **7.4.3**. The camera is unused. PSRAM is enabled and preferred for TLS buffers; server certificates remain verified. Other BLE-capable ESP32 boards need separate memory, pin, and Bluetooth testing. Do not flash a binary built for a different chip.

安装 Arduino CLI，并配置 Espressif 官方板卡索引，然后在仓库根目录运行：

Install Arduino CLI and configure the official Espressif board index, then run from the repository root:

```sh
arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32@3.3.12
arduino-cli lib install ArduinoJson@7.4.3
arduino-cli compile --fqbn esp32:esp32:esp32cam --build-path build/firmware firmware/ESP32MacWake
```

确认串口与板型后，自行上传；下面的端口名必须改成自己的。不要同时运行串口监视器。

After confirming your serial port and board, upload manually. Replace the example port with your own. Close any serial monitor first.

```sh
arduino-cli board list
arduino-cli upload --fqbn esp32:esp32:esp32cam --port /dev/cu.YOUR_SERIAL_PORT --input-dir build/firmware firmware/ESP32MacWake
```

带 IO0/RST 的下载底板若不能自动进入下载模式，可按住 IO0 再接电，约 3 秒后松开，上传完成后正常断电再接电（不按 IO0）。优先使用可靠电源及数据线。串口不稳定时降低上传速率，并核对底板接线；反复失败时不要盲目擦除原固件。

If an IO0/RST programming board cannot enter download mode automatically, hold IO0 while connecting USB, release after about 3 seconds, upload, then reconnect normally without pressing IO0. Use a reliable power supply and data cable. For unstable transfers, reduce upload speed and check the board wiring; do not erase existing firmware blindly after repeated failures.

## 自己部署中转 / Deploy your own relay

本仓库没有已部署地址、账户 ID 或有效令牌。安装 Node.js 22 或更高版本（本项目固定的 Wrangler 4.149.0 要求）后，在仓库根目录创建本地令牌，再进入 `relay`。`create-secrets.py` 生成不同的设备和手机令牌，文件权限为仅本账户可读写；已有文件不会被覆盖。

This repository contains no deployed endpoint, account ID, or usable token. Install Node.js 22 or newer, as required by the pinned Wrangler 4.149.0, create local tokens from the repository root, then enter `relay`. `create-secrets.py` creates distinct device and phone tokens with owner-only file permissions and refuses to overwrite an existing file.

```sh
python3 relay/create-secrets.py
cd relay
npm install
npm test
npm run check
npx wrangler login
```

在 `wrangler.jsonc` 中选择自己的 Worker 名称。以下命令会在你自己的 Cloudflare 账户创建/更新服务，并上传本地文件里的两个令牌作为 Worker secrets；执行前确认账户正确。Worker 使用一个 SQLite Durable Object，采用 Cloudflare 当前账户的额度/计费规则。

Choose your own Worker name in `wrangler.jsonc`. The following command creates or updates a service in your Cloudflare account and uploads the two local tokens as Worker secrets; verify the account before running it. The Worker uses one SQLite Durable Object and your account's applicable service limits and billing.

```sh
npx wrangler deploy --secrets-file ../.local/relay-secrets.json
```

部署输出的 `https://…workers.dev` 地址是你的 `relay_url`，不带路径或末尾斜杠。Mac 登录密码和 Wi-Fi 密码都不应填入 Cloudflare。Secrets 文件及导入后的快捷指令含有效凭据，不能上传仓库或公开分享。Cloudflare 的 [Secrets 文档](https://developers.cloudflare.com/workers/configuration/secrets/) 说明了本地配置文件与上传 secrets 的处理方法。

The resulting `https://…workers.dev` origin is your `relay_url`, without a path or trailing slash. Never enter your Mac login password or Wi-Fi password into Cloudflare. The secrets file and imported personal shortcuts contain usable credentials and must remain private. See Cloudflare's [Secrets documentation](https://developers.cloudflare.com/workers/configuration/secrets/) for local configuration and secret uploads.

## 首次配置与蓝牙配对 / First setup and Bluetooth pairing

1. 用 115200 波特率打开串口。全新设备会显示随机生成的本地管理密码和配置热点 `ESP32-Remote-Setup`。这些输出只用于本地配置，请勿上传日志。<br>Open a serial monitor at 115200 baud. A fresh device prints its randomly generated local management password and the `ESP32-Remote-Setup` access point. Keep these provisioning logs private.
2. 用手机连接此热点，密码为上一步的本地管理密码。打开串口显示的 HTTP 地址，用户名 `wake`，密码相同。无须更改 Mac 的网络。<br>Connect your phone to this access point using the generated password. Open the HTTP URL printed on serial; use username `wake` and the same password. The Mac's network stays unchanged.
3. 在“云端配置”填写自己的 Worker 地址和本地 secrets 文件里的 `DEVICE_TOKEN`，保存后返回首页。再填写自己的 2.4 GHz Wi-Fi 名称和密码，保存后 ESP32 自动重启。手机可返回常用网络。<br>Save your Worker origin and `DEVICE_TOKEN` from your local secrets file in Relay configuration, then return to the page. Save your own 2.4 GHz Wi-Fi SSID and password. The ESP32 restarts; reconnect the phone to its usual network.
4. 在 Mac 的蓝牙设置配对 `CAM Mac Wake`。状态中的 `connected`、`encrypted`、`subscribed` 均须为 `true` 才能发送唤醒。首次配置应保持 Mac 在桌面。<br>Pair `CAM Mac Wake` in Mac Bluetooth settings. `connected`, `encrypted`, and `subscribed` must all be `true` before a wake report is sent. Keep the Mac at its desktop during initial setup.
5. 为快捷指令配置同一个 `relay_url` 及 `PHONE_TOKEN`（`client_token`）。勿把设备令牌作为手机令牌。完成本机助手设置后，再测试锁屏及睡眠恢复。<br>Configure shortcuts with the same `relay_url` and `PHONE_TOKEN` as `client_token`. Do not use the device token as the phone token. Set up the local Mac helper before testing lock/unlock and sleep/wake.

ESP32 的 Wi-Fi、云端令牌和蓝牙绑定保存在本机 NVS。普通示例构建未启用 flash encryption；持有板子或完整 flash 备份的人可能读取这些内容。设备转交他人前，应擦除其配置并重新生成令牌。本地管理页面使用 HTTP Basic，仅用于配置热点或可信内网；不要将端口 80 转发到互联网。

The ESP32 stores its Wi-Fi details, relay token, and Bluetooth bonding in local NVS. The default example build does not enable flash encryption, so physical access or a full flash backup may expose them. Erase configuration and rotate tokens before transferring the device. The local management page uses HTTP Basic authentication for the setup access point or a trusted LAN; never forward port 80 to the internet.

## API 与状态 / API and status

| 调用 / Call | 认证 / Authentication | 内容 / Body |
| --- | --- | --- |
| `POST /v1/wake` | `Authorization: Bearer <PHONE_TOKEN>` | `{}` |
| `GET /v1/status` | 同上 / same | 无 / none |
| `POST /v1/device/poll` | `Authorization: Bearer <DEVICE_TOKEN>` | `ready`, `uptime_ms`, 可选 / optional `ack` |

这是单设备队列，无需提交设备 ID。可选的 `DOT_TOKEN` 是独立客户端令牌，不设置则禁用。支持的设备指令只有 `wake`。无文件读取、密码输入或邮件功能。

This is a single-device queue; no device ID is submitted. Optional `DOT_TOKEN` is a separate client token and is disabled when unset. The only device command is `wake`. The relay has no file access, password entry, or email functionality.

- `202 accepted`：已入队；不代表 Mac 已醒。`report_sent`：设备报告已发送蓝牙按键；不代表已解锁。`mac_awake` 始终为 `unknown`，实际结果由 Mac 助手与用户观察确认。<br>`202 accepted` means queued; `report_sent` means the device reported a BLE keypress. Neither confirms wake or unlock. `mac_awake` remains `unknown`; use the Mac helper and actual observation to verify the result.
- 最近 20 秒没有设备轮询时返回离线；蓝牙未准备好则拒绝。队列有效期 30 秒；待处理请求去重，已完成请求另有 10 秒冷却。命令仅认领一次，设备发送前先持久化命令 ID，防止断电后的重复输入。<br>No poll for 20 seconds is treated as offline; an unready BLE connection is rejected. Commands expire after 30 seconds. Pending requests are deduplicated, with a 10-second cooldown for recently completed requests. Each command is claimed once; the ESP32 persists its ID before sending to avoid replay after reboot.
- HTTPS 响应丢失可能让一次请求未执行或无法确认，系统不会无限重发按键。重新尝试前先确认当前屏幕状态。<br>A lost HTTPS response can leave a request unexecuted or unconfirmed. The system does not repeatedly send keys indefinitely. Check the current screen before retrying.

## 验证 / Validation

公开源码版通过了 ESP32-CAM 编译，以及 8 组离线中转测试（权限隔离、离线/蓝牙拒绝、单次认领与确认、并发去重、过期、无效状态、请求大小、可选令牌）。这些检查不会刷写设备、改变网络或部署云端。

The public source build passed ESP32-CAM compilation and eight offline relay test groups covering authorization boundaries, offline/BLE rejection, single claim and acknowledgment, concurrent deduplication, expiry, invalid status, request sizes, and optional tokens. These checks do not flash devices, change networks, or deploy cloud services.

本次离线测试通过 Node REPL 加载测试模块执行；未在本轮运行 Wrangler，也未将公开整理版重新刷入实物。下列命令供已安装 Node.js 的使用者复现。

These offline tests ran by importing the test module into a Node REPL. Wrangler was not run, and this public source package was not reflashed onto hardware during packaging. The command below reproduces the tests with Node.js installed.

```sh
node tests/relay.test.mjs
```

实际睡眠测试请先确认 Mac 已进入睡眠（不仅是熄屏），ESP32 接独立电源，再仅用手机触发一次唤醒并解锁。请记录是否自动亮屏、是否回到桌面，避免把手动唤醒、自动定时唤醒或控制软件遮罩误认为测试成功。

For hardware testing, first verify that the Mac is asleep, not merely displaying a black screen. Power the ESP32 independently and trigger wake-and-unlock once from the phone. Observe whether the display wakes and the desktop appears; distinguish this from manual wake, scheduled wake, or a remote-control overlay.
