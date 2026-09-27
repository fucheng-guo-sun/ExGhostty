# macOS → iPad 功能移植计划

> 基准：macOS 版 `macos/Sources/Features/`；iPad 版 `ipad/App/ExGhostty/`。
> 盘点日期：2026-09-26。本文档先列缺口清单，再给分期移植计划。

## 一、总体结论

iPad 版已完成的核心功能（无需移植）：SSH 连接管理（分组/跳板机/编码）、密码+私钥认证、
端口转发（-L/-R/-D + 重连）、SFTP 文件管理（含目录传输）、会话复用（tmux/rmux/zellij）、
端口占用、Docker、系统监控（xtop）、AI 助手（流式+环境采集+命令直达终端）、
User Identity（sudo 切换）、主题（574 套）与字体、内置浏览器 Tab。

主要缺口集中在四类：
1. **SSH 连接能力**：加密私钥 passphrase、sshdesk 桌面访问、Test Connection、Telnet。
2. **效率功能**：代码片段（CodeSnippet）、分屏（Splits）、剪贴板确认/粘贴保护、命令面板。
3. **设置项**：Mac 版 10 个分类 vs iPad 6 个，缺通知、窗口（scrollback）、安全剪贴板、Terminal（TERM）、快捷键。
4. **数据同步**：Mac 版有 iCloud Drive 同步（连接/转发/片段/配置），iPad 版无（旧 kv 同步已移除）。

明确**不移植**（macOS-only，无 iOS 对应形态）：AppleScript、系统 Services、全局快捷键、
QuickTerminal、Secure Input、自定义 Dock 图标、GitHub 更新检查（iOS 走 App Store）、
本地终端/本地子进程（iOS 不允许）、X11 转发（依赖 XQuartz）。

## 二、缺口明细

### A. SSH 连接能力

| # | 功能 | Mac 版实现 | iPad 现状 | 移植要点 |
|---|---|---|---|---|
| A1 | 加密私钥 passphrase | `SSHConnection.keyPassphrase`，SSH_ASKPASS 助手脚本解锁（2026-09 刚完成） | `SSHKeyParser` 直接拒绝加密私钥 | 无系统 ssh/askpass 可用，需在 `SSHKeyParser` 内实现 OpenSSH 加密私钥格式（openssh-key-v1，bcrypt KDF + AES-CTR）与 PEM 加密格式的解密，swift-crypto 已在依赖中；连接模型加 `keyPassphrase` 字段（Keychain 存储）；`FlexibleAuthDelegate` 用解密后密钥签名 |
| A2 | sshdesk 桌面访问 | `desktopAccess` 开关 → `ssh -t user@host desktop`；Test Connection 含桌面测试 | 无 | 连接配置加 `desktopAccess`；开启后 shell 请求的命令改为 `desktop`（`SshTerminalView` 开 shell 处）；编辑表单加复选框+官网链接（github.com/rarnu/sshdesk-go） |
| A3 | Test Connection | `SSHTestRunner` 分步测试+实时日志（检查/认证/连接/桌面） | 无 | 基于 `SSHSession` 实现分步探测：TCP 连通 → 认证（密钥/密码/跳板）→ exec 探测 →（可选）desktop 探测；独立 sheet 显示分步日志 |
| A4 | Telnet 协议 | `RemoteConnectionType` + expect 包装系统 telnet | 无 | NIO 起裸 TCP channel + 最小 Telnet 协商（IAC 序列），复用 SwiftTerm 显示；优先级低 |
| A5 | keyboard-interactive 认证 | 系统 ssh 原生支持 | `FlexibleAuthDelegate` 不支持，仅给出提示 | NIOSSH 支持 keyboard-interactive challenge；弹出密码输入框应答 |
| A6 | Host key 校验（TOFU/known_hosts） | 系统 ssh known_hosts | `AcceptAllHostKeysDelegate` 无条件接受（AGENTS.md 已知风险） | 自建 known_hosts 存储 + 首次确认弹窗 + 变更告警；属安全增强，Mac 版语义不同（系统 ssh），可选 |

### B. 效率功能

| # | 功能 | Mac 版实现 | iPad 现状 | 移植要点 |
|---|---|---|---|---|
| B1 | 代码片段 CodeSnippet | `Features/CodeSnippet/`：分类+名称+内容，一键注入终端；Python 走 heredoc | 无 | UserDefaults JSON 存储（字段对齐 Mac 版便于未来同步）；面板挂在会话页功能条；执行经 `TerminalBox` 打键 |
| B2 | 分屏 Splits | `Features/Splits/`：SplitTree 递归分屏、拖分隔条、zoom | 无 | SwiftUI 实现左右/上下二分即可（不必先做递归树）；每个 pane 持有独立 SSHSession；注意现有 ZStack 保活模式需扩展到 pane |
| B3 | 剪贴板确认/粘贴保护 | `Features/ClipboardConfirmation/`：多行/危险字符粘贴前确认，OSC52 读写授权 | 复制直接写 UIPasteboard，无确认 | SwiftTerm 有 OSC52 回调点；粘贴保护在文本输入路径拦截（多行/换行结尾确认弹窗）；设置页加 allow/deny/ask 策略 |
| B4 | 命令面板 | `Features/Command Palette/`（官方功能） | 无 | iPad 硬件键盘 Cmd+Shift+P 呼出；命令集 = tab 管理/面板切换/重连/复制粘贴；优先级低 |
| B5 | 命令完成通知 | AppDelegate UNUserNotificationCenter，notify-on-command-finish | 无 | 需 shell 集成或 OSC 133 语义提示（SwiftTerm 快照缺 SemanticPrompt，见已知坑）；可先做简化版：终端在后台时收到 BEL 发本地通知 |

### C. 设置项补齐

Mac 版设置 10 个分类（General/Theme/Appearance/Notification/Window/Directory/Secure/Terminal/Keybind/AI），
iPad 版 6 个（通用/主题/外观/AI/密钥/关于）。适用 iPad 的待补项：

| # | 设置项 | Mac 版分类 | 移植要点 |
|---|---|---|---|
| C1 | TERM 值 | Terminal | `SshTerminalView` 开 shell 时发送 TERM（当前 SwiftTerm 固定 xterm-256color 系）；SSH 场景对齐 Mac 版"SSH 会话也读取该设置"的语义 |
| C2 | Scrollback Limit | Window | SwiftTerm `TerminalOptions` 支持 buffer 行数上限 |
| C3 | 剪贴板读/写策略（allow/deny/ask）、粘贴保护开关 | Secure | 与 B3 配套 |
| C4 | 通知时机（never/unfocused/always）、通知动作（Bell/Notify） | Notification | 与 B5 配套，UNUserNotificationCenter 需申请权限 |
| C5 | 硬件键盘快捷键编辑 | Keybind | iPad 外接键盘场景；`UIKeyCommand` 自定义映射（tab 切换/关闭/复制粘贴/字体缩放）；工程量大，可后置 |
| C6 | 关闭前确认 | Window | 关 Tab 时有活跃会话弹确认 |

不适用项：Directory（工作目录继承，iPad 无本地 shell）、背景图片/模糊（SwiftTerm 渲染不支持）、
Async Backend（libghostty 概念）、Secure Input/AppleScript/Shortcuts 策略（macOS-only）。

### D. 数据同步

| # | 功能 | Mac 版实现 | iPad 现状 | 移植要点 |
|---|---|---|---|---|
| D1 | iCloud Drive 同步 | `Features/Sync/ICloudSyncManager`：iCloud Drive 目录双向同步连接/转发/片段/配置，30s 轮询+按 mtime 合并 | 无（旧 kv 同步已移除） | iOS 访问 iCloud Drive 需 ubiquity container / UIDocument；**价值点：与 Mac 版共享同一 iCloud Drive 目录可实现 Mac↔iPad 连接互通**；秘密字段格式需对齐（Mac 用 PasswordCipher 固定密钥密文，iPad 用 Keychain——同步格式须以 Mac 密文为准，导入时转存 Keychain） |

### E. 已有功能的对齐增强（非必须，列入 backlog）

- SFTP：目录随终端 OSC 7 当前路径联动（SwiftTerm 需确认 OSC7 回调）；传输任务列表窗口（当前只有底部进度条）。
- 端口转发：本地端口健康检查（"假通"强杀，Mac 版有）。
- AI 助手：与 Mac 版已基本对齐，无缺口。
- App Intents（Siri/快捷指令）：iOS 有同名框架，可后期做"打开连接"等 Intent。

## 三、分期移植计划

> 状态更新（2026-09-26）：**P0 已完成**。A1 加密私钥（BCryptPBKDF + OpenSSHKeyDecryptor 纯 Swift 解密，经 OpenBSD 官方测试向量与真实 ssh-keygen 密钥端到端验证）、A2 sshdesk 桌面访问、A3 Test Connection（分步探测 + sheet 日志）、C1 TERM 设置（新「终端」设置分类）均已实现，模拟器构建通过。

### P0 — SSH 核心能力补齐（最高优先级，用户刚需）✅ 已完成

| 任务 | 涉及文件 | 预估 |
|---|---|---|
| A1 加密私钥 passphrase（解析解密 + 模型字段 + 编辑表单 + 认证代理） | `SSH/SSHKeyParser.swift`、`SSH/FlexibleAuthDelegate.swift`、`Models/SSHConnectionConfig.swift`、`Features/Home/ConnectionEditView.swift`、`Models/KeychainHelper.swift` | 大（OpenSSH 加密格式解析是主要工作量） |
| A2 sshdesk 桌面访问 | `Models/SSHConnectionConfig.swift`、`Features/Home/ConnectionEditView.swift`、`SSH/SshTerminalView.swift` | 小 |
| A3 Test Connection | 新增 `Features/Home/TestConnectionView.swift` + `SSH/SSHSession` 探测方法 | 中 |
| C1 TERM 值设置 | `Models/SettingsStore.swift`、`Features/Settings/SettingsView.swift`、`SSH/SshTerminalView.swift` | 小 |

### P1 — 高频效率功能

| 任务 | 说明 | 预估 |
|---|---|---|
| B1 代码片段 | 新增 `Features/CodeSnippet/`（Store + 面板 + 编辑 sheet），挂会话页功能条 | 中 |
| B3 剪贴板确认/粘贴保护 + C3 设置 | SwiftTerm OSC52 回调 + 粘贴拦截 + 设置项 | 中 |
| C6 关闭 Tab 确认 | TerminalTabStore 关闭路径 | 小 |
| C2 Scrollback Limit | SettingsStore + TerminalView 配置 | 小 |

### P2 — 分屏与通知

| 任务 | 说明 | 预估 |
|---|---|---|
| B2 分屏（左右/上下二分） | 改造 `TerminalTab` 为 pane 容器；每个 pane 独立 SSHSession；分隔条拖动 | 大 |
| B5 命令完成通知（简化版：后台收到 BEL 发本地通知）+ C4 设置 | UNUserNotificationCenter + SettingsStore | 小 |

### P3 — 数据同步

| 任务 | 说明 | 预估 |
|---|---|---|
| D1 iCloud Drive 同步（连接/转发/片段，与 Mac 版格式互通） | ubiquity container；密文格式对齐 PasswordCipher；合并策略按 mtime | 大 |

### P4 — 可选/后置

- A4 Telnet、A5 keyboard-interactive、A6 Host key TOFU（安全增强）
- B4 命令面板、C5 硬件键盘快捷键编辑
- SFTP OSC7 联动、传输任务列表、端口转发健康检查
- App Intents（打开连接/发送文本）

### 不移植（结论性排除）

AppleScript、系统 Services、全局快捷键、QuickTerminal、Secure Input、自定义 Dock 图标、
GitHub 更新检查、本地终端/本地子进程（ProcessRunner/ProcessInspector）、X11 转发、
Directory 设置、背景图片/模糊、Async Backend。

## 四、跨阶段技术注意事项

1. **持久化兼容**：新增字段一律 `decodeIfPresent` + 默认值（参照 `SSHConnectionConfig` 现状）；
   秘密进 Keychain，新增 service 前缀用 `com.xjai.exghostty.ipad.*`。
2. **UI 文案**：全部走 `L("中文原文")`，四语言翻译表同步补（`Models/Translations*.swift`）。
3. **新文件头部 5 行 block 注释**（项目约定）。
4. **远程命令一律走 `session.exec()`/`execStream()`**，不引入新连接通道（项目约定）。
5. **ZStack+opacity 保活模式**：新增面板/分屏时保持视图常驻不销毁。
6. 每阶段完成后更新 `ipad/AGENTS.md` 的移植对照表与本文档状态。
