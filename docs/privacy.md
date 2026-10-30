# 隐私与凭据 / Privacy and credentials

## 密码留在 Mac 本机 / The login password stays on the Mac

**中文：** Mac 登录密码由你在本机助手的密码框中填写，持久保存于 macOS 钥匙串。助手执行解锁时会在本机内存中读取并输入它。此项目不把登录密码写入 ESP32、转发服务、快捷指令、iCloud 请求文件或运行日志。诊断功能检查权限、锁屏和系统输入目标，不读取密码框的内容；发布审计也不会查询钥匙串密码。

**English:** Enter your Mac login password locally in the helper's secure fields. Its persistent storage is the macOS Keychain; the helper reads and types it in local memory when unlocking. This project does not put the login password on the ESP32, relay, Shortcuts, iCloud request files, or runtime logs. Diagnostics inspect permissions, lock state, and the system input target without reading password-field contents. The publication audit never queries Keychain passwords.

**中文：** 自动解锁属于可选功能。启用它意味着：持有有效控制凭据的人可请求已启用的本机助手解锁。请像保护密码一样保护这些凭据。仅唤醒和睡眠控制不要求在助手中保存登录密码。需要停止自动解锁时，在助手中暂停，或使用“删除密码并停用”。

**English:** Automatic unlock is optional. Enabling it lets someone with valid control credentials ask an enabled local helper to unlock the Mac. Protect those credentials as you would a password. Wake-only and sleep control do not require storing a login password in the helper. Pause the helper or use “Delete password and disable” to stop automatic unlock.

## 哪些内容仍是秘密 / Other data that is also secret

| 内容 / Item | 存放和用途 / Storage and purpose |
| --- | --- |
| Mac 登录密码 / Mac login password | 本机钥匙串；只在本机执行输入。 / Local Keychain; entered only on the Mac. |
| 解锁请求令牌 / Unlock request token | 本机私有配置、生成的快捷指令及其 iCloud 请求；用于授权请求，与登录密码完全独立。 / Private local configuration, generated Shortcut, and its iCloud request; authorizes requests and is separate from the login password. |
| 手机端和设备端转发令牌 / Relay client and device tokens | 手机快捷指令、设备配置及自行部署的转发服务；不要公开。 / Phone Shortcut, device configuration, and your deployed relay; keep them private. |
| Wi-Fi 名称和密码 / Wi-Fi name and password | 由设备所有者在本地配置；可能保存在设备的 NVS/闪存中。 / Configured locally by the owner; may remain in device NVS/flash. |
| 私有地址和设备标识 / Private endpoints and device identifiers | 只保存在自己的配置中；公开示例使用占位符。 / Keep in your own configuration; public examples use placeholders. |

**中文：** iCloud 用于同步控制请求和结果，因此本项目并非完全离线。转发服务会处理唤醒/状态请求和相应凭据；ESP32 通过蓝牙发送唤醒按键。登录密码不经过这些通道。该流程使用已有网络连接，不要求切换 Mac 的 Wi-Fi。

**English:** iCloud synchronizes control requests and results, so the project is not entirely offline. The relay handles wake/status requests and their credentials; the ESP32 sends a wake key over Bluetooth. The login password does not travel through those channels. The workflow uses existing network connections and does not require switching the Mac's Wi-Fi.

**中文：** 不要分享已经生成或导出的个人快捷指令：即使其中没有登录密码，它们仍可能含有可用的控制令牌。仅分享仓库中的生成器和占位示例，让使用者自行生成配置。不要把 Wi-Fi 名称、任何密码、令牌或原始配置粘贴到 GitHub issue、截图或聊天记录中。

**English:** Do not share your generated or exported personal Shortcuts: they can contain working control tokens even though they contain no login password. Share the repository's generator and placeholder examples so others can create their own configuration. Do not paste Wi-Fi names, passwords, tokens, or raw configurations into GitHub issues, screenshots, or chats.

## 解锁前的检查 / Checks before password entry

**中文：** 本机助手要求已授予辅助功能/输入控制权限，且已明确启用自动解锁。请求必须带有效令牌并处于 90 秒有效期内；已处理请求不会再次执行，两次尝试间至少间隔 60 秒。助手必须确认当前用户确实锁屏，并验证 Apple 系统登录进程及其输入目标。输入过程持续检查目标、取消状态和时限；状态不明时停止，不向普通前台应用输入密码。

**English:** The local helper requires Accessibility/input-control permission and explicit enablement of automatic unlock. A request must carry a valid token and be within its 90-second lifetime; processed requests are not repeated, and attempts are at least 60 seconds apart. The helper must confirm that the current user is locked and verify the Apple system login process and input target. It rechecks the target, cancellation state, and deadline during entry, stopping on uncertainty instead of typing into an ordinary foreground app.

**中文：** 一次请求只执行一次密码提交；提交后只有明确观察到解除锁屏才报告成功。失败或超时不会自动反复输入。首次安装、改密码、重新编译或系统更新后，都应在电脑旁测试。此功能不替代 FileVault 的开机认证，也不承诺从完全关机状态启动电脑。

**English:** Each request permits one password submission. Success is reported only after observing an explicitly unlocked state; failure or timeout does not trigger repeated entry. Test beside the Mac after installation, a password change, rebuilding, or an OS update. This feature does not replace FileVault's boot authentication or promise to start a fully powered-off computer.

## 公开仓库只保留源文件 / Publish source files only

**中文：** 本仓库发布可读源码、安装/生成脚本和占位配置。不要提交固件镜像、原始闪存/NVS 备份、已安装的应用、个人快捷指令、私有配置、运行日志、截图或设备状态导出。构建产物也可能嵌入凭据、私人路径或设备信息，不能因扩展名看似无害就直接上传。`.gitignore` 是辅助措施；发布前仍需检查实际提交内容。

**English:** This repository publishes readable source, installation/generation scripts, and placeholder configurations. Do not commit firmware images, raw flash/NVS backups, installed apps, personal Shortcuts, private configuration, runtime logs, screenshots, or device-state exports. Build artifacts may embed credentials, personal paths, or device information. `.gitignore` helps, but review the actual files being committed before publication.

在干净的发布目录运行 / Run in a clean publication directory:

```sh
python3 tests/audit_publication.py --self-test
python3 tests/audit_publication.py
```

**中文：** 检查器只报告文件位置、行号和规则名，不打印命中的内容。它检查禁止的产物、常见凭据格式、个人主目录、设备地址和可疑明文赋值。默认扫描工作目录中的文件，跳过 `.git` 对象历史；本地构建目录会被保守报告为不可发布产物。

**English:** The scanner reports file locations, line numbers, and rule names, never matched content. It checks forbidden artifacts, common credential formats, personal home paths, device addresses, and suspicious literal assignments. The default scan covers working-tree files and excludes Git object history; local build directories are conservatively reported as non-publishable artifacts.

**中文：** 如果工作目录中已生成私人配置或构建产物，先明确选择源码文件加入 Git 暂存区，再用 `--staged` 检查实际暂存内容。该模式读取每个文件的暂存版本，忽略未暂存的本机构建；请核对暂存文件清单，不要因为该模式忽略工作目录就把私人产物加入提交。

**English:** If your working tree contains private configuration or build products, explicitly stage the source files and use `--staged` to inspect the actual index. This reads each file's staged version and excludes unstaged local builds. Review the staged file list; this mode does not make private artifacts safe to commit.

```sh
git diff --cached --name-only
python3 tests/audit_publication.py --staged
```

**中文：** 可选的 `--private-values` 接收仓库外的本地 JSON 字符串数组，用于匹配你已知的私有值，包括 Wi-Fi 名称。该文件及其内容必须留在本机；不要在命令行直接传入秘密，也不要为审计导出登录密码。扫描器拒绝从发布目录内部读取此列表，输出不包含列表值。自动规则无法证明所有秘密均不存在，仍需检查生成文件和实际提交历史。已经包含秘密的旧历史不能直接作为公共仓库历史发布。

**English:** Optional `--private-values` accepts a local JSON array of strings outside the repository to match known private values, including Wi-Fi names. Keep that file and its contents local; do not pass secrets directly on the command line or export a login password for auditing. The scanner rejects a corpus inside the publication tree and does not print its values. Automated rules cannot prove that every secret is absent: review generated files and the actual commit history too. Do not publish old history that contains secrets.

```sh
python3 tests/audit_publication.py --private-values /private/path/to/audit-values.json --json
```

**中文：** 如果个人快捷指令、令牌或备份曾意外公开，应立即停用或轮换相关控制凭据，并清理公开副本和历史；仅删除最新版本中的文件不能撤销已经泄露的凭据。

**English:** If a personal Shortcut, token, or backup is accidentally published, disable or rotate the affected control credentials and remove public copies and history. Deleting a file from the latest version does not revoke an exposed credential.
