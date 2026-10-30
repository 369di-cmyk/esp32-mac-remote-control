# 本机唤醒解锁助手 / Local wake-and-unlock helper

此助手在已经登录过的 macOS 用户会话中运行。ESP32 只发送唤醒事件，密码由 Mac 自己处理。它不能处理完全关机、重启后的首次 FileVault 解锁或多用户切换。当前密码输入限制为 1–64 个可打印 ASCII 字符；请不要为了适配本工具而弱化密码。

This helper runs inside a macOS user session that has already logged in. The ESP32 sends wake events; the Mac handles its password locally. It does not handle shutdown, FileVault preboot after restart, or fast user switching. Password input currently supports 1–64 printable ASCII characters; do not weaken a password to accommodate this tool.

## 构建与安装 / Build and install

需要 Xcode Command Line Tools、Python 3 和 macOS。开发原型在 Apple Silicon、macOS 27.0 上验证；没有覆盖所有系统版本。下面的构建和离线测试不会解锁或修改睡眠设置。 / Requires Xcode Command Line Tools, Python 3, and macOS. The development prototype was tested on Apple Silicon with macOS 27.0; other versions are not comprehensively tested. Building and offline tests do not unlock the Mac or change sleep settings.

```sh
bash macos/unlock/build.sh
bash tests/test_unlock.sh
python3 scripts/configure.py  # skip if .local/shortcuts.json already exists
python3 macos/unlock/install.py --config .local/shortcuts.json
```

安装器将公开版应用放在 `~/Applications/Mac Wake Unlock.app`，并添加当前用户的登录启动项。它不读取旧助手的密码、令牌或配置。安装后点击菜单栏的 `⌑` 图标打开设置。 / The installer places the public-project app in `~/Applications/Mac Wake Unlock.app` and registers a per-user login agent. It does not read an older helper’s password, token, or configuration. Open settings from the `⌑` menu-bar icon after installation.

1. 点击“授权辅助功能”，在系统设置中允许 **Mac Wake Unlock**。 / Click “授权辅助功能” (Authorize Accessibility), then allow **Mac Wake Unlock** in System Settings.
2. 点击“连接 iCloud 文件夹”，选择 iCloud Drive → Shortcuts → `MacSleepControl`。与手机使用同一个 Apple 账号，先按快捷指令教程创建该文件夹。 / Click “连接 iCloud 文件夹” (Connect iCloud folder), selecting iCloud Drive → Shortcuts → `MacSleepControl`. Use the same Apple account as the phone and create the folder as described in the Shortcuts guide.
3. 在两个密码框中填写本机登录密码，点击“保存密码并启用”。密码不要放入配置 JSON、终端、聊天或 GitHub。 / Enter the Mac login password twice and click “保存密码并启用” (Save password and enable). Never put the password in a configuration JSON, terminal, chat, or GitHub.
4. 如果系统询问钥匙串访问，请核对应用与记录，在 Mac 上完成授权。后续可用“启用已保存密码”。 / If macOS asks for Keychain access, verify the app and item locally. Later, use “启用已保存密码” (Enable saved password).
5. 保持 Caps Lock 关闭，首次测试使用 ABC / 美国英语输入法。先验证真正的密码锁屏界面，再测试系统睡眠。 / Keep Caps Lock off and use ABC / U.S. input for the first test. Verify a real password lock screen before testing system sleep.

“兼容新版系统密码界面”默认关闭，仅适用于被校验的 Apple Platform SSO 系统界面。普通 loginwindow 无需启用。若无法确定目标，助手停止，不会向任意前台应用输入密码。 / The newer-system-password-screen option is off by default and applies only to a verified Apple Platform SSO system target. Ordinary loginwindow does not require it. When the target cannot be verified, the helper stops instead of typing into an arbitrary foreground app.

## 检查与请求 / Checks and requests

- 当前用户必须是控制台已登录用户，并由系统锁屏标志确认处于锁屏；未知或冲突状态拒绝输入。 / The current user must be logged in at the console, with a confirmed system lock state. Unknown or conflicting state rejects input.
- 校验系统进程路径、标识和 Apple 签名，保存目标进程，再在每对按键之前重新检查；只向该进程定向输入。 / Verify the system process path, identifier, and Apple signature; capture and recheck the target before each key pair. Input is directed only to that process.
- 一次性请求格式为 `9-digit-ID|ISO8601-date|request-token`。有效期 90 秒、尝试间隔至少 60 秒，保留最近 256 个请求用于去重。 / Requests use `9-digit-ID|ISO8601-date|request-token`, expire after 90 seconds, have a 60-second attempt cooldown, and retain the latest 256 identifiers for deduplication.
- 输入阶段有 20 秒期限；取消、睡眠、Caps Lock 或权限变化会停止。一次失败不自动重新提交密码。 / Input has a 20-second deadline; cancellation, sleep, Caps Lock, or permission changes stop it. Failure does not automatically resubmit the password.
- 只有系统随后明确报告退出锁屏，才写入成功回执。 / Success is recorded only after the system explicitly reports an unlocked session.

钥匙串记录名为 `io.github.esp32macremote.unlock.password`；状态和请求令牌放在 `~/Library/Application Support/ESP32MacRemoteUnlock`。登录密码不会写入该目录。记录中的请求令牌和日志仍应保密。 / The Keychain service is `io.github.esp32macremote.unlock.password`. Status and the request token live in `~/Library/Application Support/ESP32MacRemoteUnlock`; the login password is never written there. Keep the token and local diagnostic logs private.

## 更新与停用 / Updates and disabling

默认构建使用本机临时签名。重新编译可能导致 macOS 要求重新授予辅助功能和钥匙串访问；在桌面完成授权后再测试。可用 `SIGN_IDENTITY` 环境变量指定自己的稳定签名身份；不要把证书或私钥上传。 / Builds use ad-hoc local signing by default. Rebuilding can require new Accessibility and Keychain authorization; finish that on the desktop before testing. Optionally set `SIGN_IDENTITY` to your own stable signing identity. Never upload signing certificates or private keys.

更新前退出旧公开版助手，保留原 `.local/shortcuts.json`，重新构建后使用安装器的 `--replace`。不要同时运行多个版本的自动解锁助手。 / Before updating, quit the previous public-project helper, preserve `.local/shortcuts.json`, rebuild, then use the installer’s `--replace` option. Do not run multiple automatic-unlock helpers together.

菜单中的“暂停并取消本次解锁”会停用后续请求；“删除密码并停用”还会移除本应用的钥匙串记录。 / “暂停并取消本次解锁” pauses future requests and cancels the current attempt. “删除密码并停用” also deletes this app’s Keychain item.
