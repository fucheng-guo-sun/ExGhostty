# ExGhostty iPad 版 — Agent 开发指南

本目录是 ExGhostty（Mac 版，位于仓库根 `/Users/rarnu/Code/github/ExGhostty`）的 **iPad 移植版**。
所有 iPad 版工作均以 Mac 版为参照进行移植；Mac 版的功能实现对齐基准在 `../macos/Sources/`。

> 注意：仓库根的 `AGENTS.md` 描述的是 Zig/Mac 工程（`zig build` 等），对本目录基本不适用。

## 项目构成

- `App/ExGhostty_iPad/` — iPad App 本体（约 42 个 Swift 文件），Xcode 工程在 `App/ExGhostty_iPad.xcodeproj`。
- `Sources/SwiftTerm/` — 内嵌的 [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 快照（终端引擎 + UIKit/AppKit 视图 + Metal 渲染），作为 SPM 本地库使用。**这是较旧的上游快照，基本无本地补丁；App 专属逻辑一律放 `App/`，不要污染库代码。**
- `Vendor/swift-nio-ssh/` — SSH 协议栈依赖。
- SPM 远程依赖：`swift-nio`、`swift-crypto`（NIOSSH 需要）、`SWCompression`（仅用于 SFTP 目录传输的 tar.gz 本地打包/解压，见 `Features/SFTP/TarGzArchive.swift`）。
- `Sources/CaptureOutput`、`Sources/Termcast`、`Sources/SwiftTermFuzz`、`Tests/SwiftTermTests` — 上游 SwiftTerm 自带的工具与测试，与 App 无关。
- `scripts/regen_unicode_width_data.py` — 重新生成 SwiftTerm 的 `UnicodeWidthData.swift`（`make regen-unicode-width`）。

## 构建与测试

- App：用 Xcode 打开 `App/ExGhostty_iPad.xcodeproj`（scheme: `ExGhostty_iPad`），依赖通过本地 SPM 解析。
- SwiftTerm 库：`swift build` / `swift test`（在本目录执行；只测 SwiftTerm，不构建 App）。
- 命令行构建 App 示例：`xcodebuild -project App/ExGhostty_iPad.xcodeproj -scheme ExGhostty_iPad -destination 'generic/platform=iOS Simulator' build`。
- Swift 格式化遵循仓库根规则：`swiftlint lint --strict --fix`。

## App 架构（`App/ExGhostty_iPad/`）

- **入口**：`ExGhosttyApp.swift`（SwiftUI 生命周期；`init()` 先启动 `ICloudSyncManager`）。根视图 `MainSplitView`（手写 HStack：左侧连接列表 `ConnectionListView`，右侧 `TerminalTabContainerView`），强制深色模式。
- **Tab/会话**：`Features/Session/TerminalTabStore.swift` — `TerminalTab` 持有 `SSHSession` + `TerminalBox`（弱引用终端控制器）。所有 tab 用 `ZStack + opacity` 常驻视图树保活，切换不销毁会话——新增面板/页面时必须保持这一模式。
- **SSH 层**（`SSH/`）：`SSHSession`（NIOSSH，`MultiThreadedEventLoopGroup(3)`，子 channel 承载 shell/exec/sftp）。认证 `FlexibleAuthDelegate`（私钥优先、回落密码；**不支持 keyboard-interactive、不支持加密私钥**）。跳板机 = `openNestedTransport`（跳板机 directTCPIP 上二次握手，经 `SSHDataCodec` 做字节转换）。`SFTPClient` 是手写 SFTP v3。**端口转发功能已从 iPad 版移除**（用户需求，Mac 版仍有）。
- **终端接入**：`SSH/SshTerminalView.swift` — `class SshTerminalView: TerminalView, TerminalViewDelegate`（用 UIKit 的 `TerminalView`，**不是** `SwiftUITerminalView`，后者仅 DEBUG 内部调试用）。数据流：下行 `channelRead` → 1KB 切片 → 主线程 `feed(byteArray:)`；上行 `TerminalViewDelegate.send` → `writeAndFlush`；resize → `WindowChangeRequest`。宿主 `TerminalHostViewController`（UIKit 容器 + `keyboardLayoutGuide`），经 `TerminalSessionView` 内 `UIViewControllerRepresentable` 桥接进 SwiftUI。
- **功能面板**（`Features/`，每个目录一个域）：`Session`（标签页）、`Home`（连接列表/编辑）、`Settings`、`Keys`（私钥管理，自研 OpenSSH/PEM 解析；`SSHKeyListContent` 是无导航壳的列表+导入/删除内容视图，设置页 Keys 分区直接内嵌它；`SSHKeyManagementView` 是其 push 整页包装，连接编辑页仍在用）、`SFTP`、`SessionReuse`（tmux/rmux/zellij）、`PortUsage`、`Docker`、`SystemMonitor`（远端 `xtop --all --json --stream` 流式采集，含 GPU/磁盘读写，对齐 Mac 版）、`AIAssistant`（OpenAI 兼容 SSE 流式）。所有面板注入同一个 `SSHSession`，通过 `session.exec()` / `execStream()` 跑远程命令；需要"往终端打字"的面板额外拿 `TerminalBox`。
- **设置页**（`Features/Settings/`）：Mac 风格左右分栏——左 200pt 分类 `List`（`SettingsCategory`：通用/主题/外观/AI/密钥），右侧 ScrollView detail；`settingsRow(label:controlWidth:)` 统一"120pt 标签 + 定宽控件列"的行式对齐（默认控件宽 240，AI 输入框 360，行内不要再给控件单独设 `.frame(width:)`）。经 `SettingsViewController`（全屏 push 转场 + 强制深色）从主界面推出。主题切换仅 UI 占位。

## 代码约定

- 命名：类型 PascalCase / 成员 camelCase，英文；面板成对出现 `XxxPanelView` + `XxxViewModel`；持久化单例 `XxxStore.shared` + `@Published`。
- **每个文件头部写 5 行左右的 block 注释**说明职责和坑——新文件必须照做。
- 注释语言现状混用：`SSH/`、`Models/` 为英文，`Features/` ViewModel 多为中文。改哪个层就跟随哪个层的语言。
- **UI 文案走应用内翻译**：所有用户可见字符串用 `L("中文原文")` 包裹（key 即简体中文原文；翻译表在 `Models/Translations*.swift`，按 area/语言分文件——`Translations.{home,session,Panels,ai}.swift` 并入 `Translations.en`，`Translations.zhHant.swift` / `Translations.ja.swift` 为整表）。支持语言：简体中文（原文）/ 繁體中文 / 日本語 / English。含 L() 的 View struct 必须加 `@StateObject private var l10n = LocalizationManager.shared` 以订阅语言切换。ViewModel 消息存中文原文，在 View 显示处包裹 L()。
- 持久化：配置 JSON → UserDefaults；秘密（密码/私钥/sudo 密码）→ Keychain（`KeychainHelper`，三个 service 前缀）；iCloud 同步走 `NSUbiquitousKeyValueStore` 只同步非秘密数据。
- 模型 Codable 用 `decodeIfPresent` + 默认值做旧存档兼容（参考 `SSHConnectionConfig`）。
- ViewModel 轮询统一 `Task { while !Task.isCancelled { ... } }`，`deinit` cancel。
- 终端字体：`App/ExGhostty_iPad/Fonts/` 内置 5 款字体（JetBrains Mono Nerd Font 与其 Mono 变体各四字重——后者来自 nerd-fonts 官方发布包；Fira Code / JuliaMono / Monaspace Neon 单字重，均 OFL），`Info.plist` 的 `UIAppFonts` 注册；`Models/TerminalFontCatalog.swift` 应用字体+字号到 TerminalView（PS 字体名以字体文件内嵌为准，如 `JetBrainsMonoNFM-Regular`）。主题切换只有设置页 UI 占位，未实现。
- 颜色无主题系统（黑底 + `Color.teal` 强调），UI 文本多用 `.monospaced`。

## 已知坑 / 技术债（改动前先读这里）

- `AcceptAllHostKeysDelegate` 无条件接受所有 host key（MITM 风险，无 TOFU/known_hosts）。
- `SettingsStore.terminalFontSize` / `terminalFontName` 已接线到终端（`TerminalHostViewController` 订阅变更并调用 `TerminalFontCatalog.apply`）。
- 命名已统一为 ExGhostty（`ExGhosttyApp`、文件头 `ExGhostty_iPad`、Keychain service `com.xjai.exghostty.ipad.*`、UserDefaults key `exghostty.ipad.*`）。旧的 `iosterminal.*` / `org.tirania.SwiftTerm.iosSampleApp1.*` 数据由 `Models/LegacyDataMigration.swift`（启动时）和 `KeychainHelper`（读取时懒迁移）负责迁移——新增持久化 key 时用 `exghostty.ipad.` 前缀。
- iCloud 同步单向生效：远端变更写入 UserDefaults 后各 Store 不监听更新，**下次启动才生效**；`ICloudSyncManager` 硬编码各 Store 的 UserDefaults key，改 key 会静默失配。
- `SshTerminalView.observeIdentityPrompt` 的 sudo 密码嗅探只匹配输出尾部 256 字节里的 "password"（英文 locale 限定，很脆）。
- 每连接一个 3 线程 event loop group，线程数随 tab 线性增长；`TerminalTab.connectIfNeeded` 的 `try?` 吞掉连接错误。
- `SSHShellChannelHandler` 每 1KB 一次主线程 dispatch，大输出下调度开销可观（但保序）。
- `Info.plist` 的 `UIRequiredDeviceCapabilities` 还写着 `armv7`（模板残留）。
- SwiftTerm 快照缺上游新增的 BiDi/Powerline/SemanticPrompt 等文件；`Sources/SwiftTerm/BufferSet.swift` 和 `File.swift` 是上游遗留的空文件。

## 移植参照（Mac 版 → iPad 版）

Mac 版功能在 `../macos/Sources/Features/`，iPad 版对应关系：

| Mac 版 | iPad 版 | 差异要点 |
|---|---|---|
| Ghostty surface + expect 脚本包装系统 ssh | SwiftTerm + swift-nio-ssh 内嵌 | **最大架构差异**：iOS 无 ssh/expect 二进制 |
| `Features/Sidebar/`（SSHStore 等） | `Features/Home/` + `SSH/` | UserDefaults+JSON 持久化模式一致 |
| `Features/SFTP/`（rsync 传输） | `Features/SFTP/`（手写 SFTP v3） | iOS 无 rsync |
| `Features/AIAssistant/`、`Docker/`、`SystemMonitor/`、`SessionReuse`、`PortUsage` | 同名 Feature 目录 | 面板 UI 与交互逻辑对标 Mac 版 |
| Mac 版端口转发（`SSHStore.PortForwardStore` + ssh mux） | **已移除，不移植** | iPad 版不需要该功能 |
| ghostty 配置文件 + `ConfigFileWriter` | 无（UserDefaults + `SettingsView`） | iPad 版无主题/字体/快捷键体系 |
| `Helpers/PasswordCipher`（AES 存密码） | Keychain | iPad 用 Keychain 替代 |

新增功能时：先在 `../macos/Sources/Features/` 找 Mac 版实现作为行为基准，再按本目录的 SSH/SwiftTerm 架构适配（远程命令一律走 `session.exec()`，不要引入新的连接通道）。

## Issue 与 PR 规则

遵循仓库根 `AGENTS.md`：永远不要创建 issue 或 PR。
