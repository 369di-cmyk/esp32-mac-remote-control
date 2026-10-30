# 睡眠与快捷指令 / Sleep and Shortcuts

手机与 Mac 使用同一个 Apple 账户的 iCloud 云盘，并开启快捷指令同步。ESP32 通过现有 Wi-Fi 连接中继服务，再通过蓝牙唤醒 Mac；无需切换 Mac 的网络。独立 USB 电源只负责给 ESP32 供电。

Use the same Apple account for iCloud Drive on the iPhone and Mac, with Shortcuts sync enabled. The ESP32 reaches the relay through its configured Wi-Fi and wakes the Mac over Bluetooth. The Mac keeps its existing network. A separate USB supply can power the ESP32.

## 五个入口 / Five shortcuts

| 快捷指令 / Shortcut | 图标 / Icon | 行为 / Behavior |
| --- | --- | --- |
| Mac自动睡眠 | 灰色计时器 / Gray timer | 闲置 20、30、50、60、120、180、240、300 分钟后睡眠；菜单也能查看回执。 / Set the idle sleep duration or view the latest receipt. |
| Mac远程睡眠 | 紫色月亮 / Purple moon | 请求接收后约 8 秒调用系统睡眠，超过 2 分钟的请求失效。 / Request system sleep about 8 seconds after receipt; requests expire after 2 minutes. |
| Mac在线查询 | 蓝色放大镜 / Blue magnifier | 发送新的查询码，等 40 秒，核对本次回复。 / Send a fresh challenge, wait 40 seconds, then match the reply. |
| Mac蓝牙唤醒 | 橙色太阳 / Orange sun | 手机 → HTTPS 中继 → ESP32 → 蓝牙按键。 / iPhone → HTTPS relay → ESP32 → Bluetooth key report. |
| Mac 唤醒并解锁 | 绿色开锁 / Green open lock | 唤醒后发送一次有时限的请求；本机助手检查锁屏后才输入本地保存的密码。 / Wake, then send one expiring request; the local helper checks the lock screen before entering the locally stored password. |

快捷指令名称及操作提示目前为中文。上表提供英文对照；导入后可以自行改名，文件协议不依赖快捷指令名称。图标使用原生快捷指令符号，系统版本不同可能显示略有差异。

Shortcut names and action messages currently use Chinese. The table provides English equivalents; you may rename them after import because the protocol does not depend on their names. Native Shortcuts symbols may render differently across OS versions.

“自动睡眠时间”是系统闲置计时，不是点击按钮后的倒计时；屏幕熄灭计时不变。应用的电源保持请求可能阻止入睡。在线回复只证明回复时接收器正在运行，不能证明屏幕已亮。提交回执、蓝牙发送成功、真正唤醒、真正解锁是不同阶段。

The automatic sleep setting is an idle timer, not a countdown from tapping the shortcut. Display sleep is unchanged, and application power assertions can delay actual sleep. An online reply proves the receiver was running at reply time, not that the display was on. Submission, a Bluetooth report, actual wake, and actual unlock are separate stages.

请先在 macOS 的“锁定屏幕”设置中，把睡眠或屏幕保护程序开始后的密码要求设为“立即”。远程睡眠动作调用系统睡眠；是否需要密码由 macOS 设置决定，它不会单独发送锁屏操作。安装器不会自动修改此设置。

In macOS Lock Screen settings, require the password immediately after sleep or the screen saver begins. Remote sleep requests system sleep; macOS settings determine the password requirement. It does not separately issue a lock-screen command, and the installer does not change this setting automatically.

## 安装睡眠接收器 / Install the sleep receiver

需要 macOS 13 或更高版本、Python 3 和 Xcode Command Line Tools。源代码构建不修改睡眠设置；下面安装步骤由使用者自行执行。安装器只安装本项目的服务，不切换网络、不改变共享或远程登录设置。

Requires macOS 13 or later, Python 3, and Xcode Command Line Tools. Building does not change sleep settings. Run the installation steps yourself; they install this project's services without changing networks, sharing, or Remote Login settings.

在仓库根目录执行： / From the repository root:

```sh
zsh macos/sleep/build.sh
sudo "$(command -v python3)" macos/sleep/install.py --system "$USER"
python3 macos/sleep/install.py
```

管理员步骤安装一个受限的系统接收器，只允许指定本地账户请求白名单中的睡眠时间或立即睡眠。普通用户步骤安装 `~/Applications/Mac Sleep Sync.app` 并加入登录启动。首次弹窗中，选择 **iCloud Drive → Shortcuts → MacSleepControl** 专用文件夹。无需完全磁盘访问权限。若要重新安装应用，请先退出并把旧应用移走；安装器不会直接覆盖它。

The administrator step installs a restricted system receiver. It accepts only the selected local account's requests for the allowed sleep durations or immediate sleep. The normal-user step installs `~/Applications/Mac Sleep Sync.app` and its login agent. In its first-run window, select the dedicated **iCloud Drive → Shortcuts → MacSleepControl** folder. Full Disk Access is not required. Before reinstalling the app, quit it and move the old copy aside; the installer will not overwrite it.

系统接收器每 30 秒检查一次本地请求；菜单栏应用每 5 秒同步一次 iCloud 文件。iCloud 另有同步延迟。接收器必须在 Mac 已开机且用户已登录后运行，不能靠 iCloud 唤醒睡眠中的 Mac。

The system receiver checks local requests every 30 seconds; the menu-bar app syncs iCloud files every 5 seconds. iCloud adds its own delay. The receiver needs a booted Mac and a logged-in user. iCloud alone cannot wake a sleeping Mac.

## 本地生成并导入 / Generate and import locally

先按仓库主页完成中继、ESP32 和本机解锁助手的配置，再运行：

First configure the relay, ESP32, and local unlock helper as described in the main README, then run:

```sh
python3 scripts/configure.py
python3 shortcuts/generate.py --config .local/shortcuts.json --output generated/shortcuts
```

如果已经按主页创建了 `.local/shortcuts.json`，跳过第一行配置命令，保留现有令牌；重复创建会被拒绝，避免覆盖本机助手正在使用的配置。

If you already created `.local/shortcuts.json` by following the README, skip the first command and preserve the existing tokens. Recreating the configuration is refused to avoid replacing values already used by the helper.

配置字段为 `relay_url`、`client_token`、`unlock_request_token`。`client_token` 对应中继的手机令牌；`unlock_request_token` 必须与本机助手配置的 `request_token` 完全一致。使用仓库的配置程序可以生成对应值。**这里不填写 Mac 登录密码。** 登录密码只在本机助手界面保存到钥匙串。

The configuration fields are `relay_url`, `client_token`, and `unlock_request_token`. `client_token` is the relay's phone token. `unlock_request_token` must exactly match `request_token` in the local helper's configuration. Use the repository's configuration script to create the matching values. **Do not put the Mac login password here.** Save it only through the local helper's interface into Keychain.

生成文件包含个人访问令牌，目录权限为 `0700`、文件权限为 `0600`。`.local/`、`generated/` 和所有 `.shortcut` 均应保持 Git 忽略。不要把生成文件上传仓库、发给别人或创建公开 iCloud 分享链接。密码没有离开本机，但解锁授权令牌会在你自己的快捷指令与 iCloud 请求文件中出现。

Generated files contain personal access tokens. The directory uses mode `0700` and files use `0600`. Keep `.local/`, `generated/`, and all `.shortcut` files ignored by Git. Do not upload generated files, send them to other people, or create public iCloud sharing links. The password stays on the Mac; the unlock authorization token is present in your own shortcut and iCloud request file.

macOS 需要为本地生成的快捷指令签名后导入。以下命令仅在本机生成私用文件；Apple 的签名过程可能需要联网。签名不等于公开分享：

macOS requires signing generated shortcuts before import. The following creates local files for personal use; Apple's signing process may require network access. Signing does not publish a sharing link:

```sh
mkdir -p generated/signed-shortcuts
chmod 700 generated/signed-shortcuts
for input in generated/shortcuts/*.shortcut; do
  shortcuts sign --mode people-who-know-me --input "$input" \
    --output "generated/signed-shortcuts/$(basename "$input")"
done
chmod 600 generated/signed-shortcuts/*.shortcut
open generated/signed-shortcuts
```

逐个双击导入，确认动作中的 iCloud 保存位置是 `Shortcuts/MacSleepControl`，然后等待同步到手机。首次运行时允许快捷指令访问该文件夹及你自己的中继地址。部分系统可能要求在保存/读取文件动作中重新选择专用文件夹。请先在 Mac 桌面状态完成权限提示，再做锁屏测试。

Double-click each file to import it. Confirm the file actions target `Shortcuts/MacSleepControl`, then let Shortcuts sync to the phone. On first use, allow access to that folder and your own relay URL. Some OS versions may require reselecting the dedicated folder in save/read actions. Complete permission prompts while the Mac is at the desktop before testing the lock screen.

## 协议与验证 / Protocol and verification

| 文件 / File | 内容 / Content |
| --- | --- |
| `request.txt` | `minutes\|nonce` 或 / or `sleep\|nonce\|ISO8601` |
| `status.txt` | 睡眠回执，含执行时间与 `请求码：nonce` / Sleep receipt with execution time and nonce |
| `ping.txt` | `nonce\|ISO8601` |
| `online.txt` | 在线回复，含 `请求码：nonce` / Online reply with matching nonce |
| `unlock-request.txt` | `nonce\|ISO8601\|request_token` |
| `unlock-result.txt` | 解锁检查结果，含 `请求码：nonce` / Unlock result with matching nonce |

每次请求生成 9 位随机码；日期使用含时区的 ISO 8601。在线与睡眠请求超过 120 秒失效，解锁请求超过 90 秒失效。接收器消费睡眠请求后才执行，避免重启或重复同步造成再次睡眠。相同请求码的回执用于核对本次结果；不会把历史回执当成本次成功。

Each request uses a fresh nine-digit random nonce and, where required, an ISO 8601 timestamp with timezone. Online and sleep requests expire after 120 seconds; unlock requests expire after 90 seconds. The receiver consumes a sleep request before executing it to avoid replay after restart or repeated synchronization. Matching the nonce ties a receipt to the current request instead of treating a historical receipt as a new success.

离线测试不会联网、运行快捷指令、睡眠或输入密码：

Offline tests do not use the network, run shortcuts, put the Mac to sleep, or enter a password:

```sh
python3 -m unittest discover -s tests -p 'shortcuts*_test.py' -v
perl -c macos/sleep/apply.pl
```

实际测试顺序：桌面状态完成配置 → 在线查询 → 设置一个闲置睡眠时间并核对回执 → 手动锁屏测试一次解锁 → ESP32 改用独立电源 → 锁屏并睡眠 → 等屏幕熄灭 90 秒 → 只在手机运行一次“Mac 唤醒并解锁”，确认不用碰 Mac 就能亮屏回到桌面。失败后先查看回执与本机助手状态，不连续重复提交密码请求。

For a live test: finish setup at the desktop → query online status → change one idle sleep setting and check its receipt → manually lock and test one unlock → power ESP32 independently → lock and sleep the Mac → wait 90 seconds after the display goes dark → run “Mac 唤醒并解锁” once on the phone. Confirm it returns to the desktop without touching the Mac. If it fails, inspect the receipt and local helper state before sending another request.

## 卸载 / Uninstall

下面的命令停止本项目的两个睡眠服务。之后可删除对应应用、配置和启动文件。它们不会恢复以前的睡眠时间；请在系统设置中手动选择希望的时间。解锁助手的卸载单独处理。

These commands stop this project's two sleep services. You can then remove their app, configuration, and launch files. They do not restore a previous sleep duration; choose your preferred duration in System Settings. The unlock helper is managed separately.

```sh
launchctl bootout "gui/$(id -u)/io.github.esp32macremote.sleep-sync"
sudo launchctl bootout system/io.github.esp32macremote.sleep
```

对应位置 / Related locations:

```text
~/Applications/Mac Sleep Sync.app
~/Library/LaunchAgents/io.github.esp32macremote.sleep-sync.plist
/Library/LaunchDaemons/io.github.esp32macremote.sleep.plist
/Library/Application Support/ESP32MacRemoteSleep
/var/db/io.github.esp32macremote.sleep
```

`MacSleepControl` iCloud 文件夹与解锁助手共用；只有在两项功能都停用后才删除。

The `MacSleepControl` iCloud folder is shared with the unlock helper; remove it only after disabling both features.
