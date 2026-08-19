<!-- LOGO -->
<h1>
<p align="center">
  <img src="images/newicon/icon_1024.png" alt="ExGhostty" width="160">
  <br>ExGhostty
</h1>
<p align="center">
  <b>一款基于 Ghostty 的全新 SSH 工具</b>
</p>
<p align="center">
   <a href="README.md">English</a> · <b>简体中文</b>
</p>

---

## 为什么会有 ExGhostty？

开发这个项目，主要是出于对 [Ghostty](https://ghostty.org) 的喜爱——
它是一个快速、原生、漂亮的终端模拟器。但再怎么喜欢，也必须承认，
Ghostty 并不适合作为一个传统的 **SSH 工具** 来使用：

- **Ghostty 不符合 SSH 工具的使用场景。** 管理大量远程主机、跳板登录、
  文件传输、端口转发保活……这些是一个单纯的终端模拟器帮不了你的。
- **Ghostty 的配置门槛太高。** 一切配置都要手写配置文件，这对只想
  连上服务器干活的新人来说，是非常劝退的。
- **传统终端已经跟不上 AI 的节奏。** 在 AI 大模型快速发展的今天，
  一个只会回显文字的传统终端，已经很难满足人们真正的工作方式。

ExGhostty **并不是** 一个追求大而全的工具。它只希望在 **SSH 这件事上
做得更好**，配合一些常用的能力，并与 **AI 大模型** 保持实用的结合。

它 **免费且开源** —— 不会加入订阅，也不会加入广告。它的主旨只是提供
另一种选择，让喜欢 Ghostty 的用户，可以有更多适合自己工作方式的选择。

---

## 主要功能

### 核心：把 SSH 变简单
- **SSH 连接管理** —— 按分组管理主机，支持密码 / 密钥认证、跳板机、
  每台主机独立的编码、超时与心跳保活设置。
- **一键连接** —— 双击主机即可建立会话；密码 **AES 加密存储**，绝不明文保存。
- **连接测试** —— 保存前验证连通性与认证是否可用。
- **本地终端** —— 完整的 Ghostty 终端，一键即达。

### SFTP 文件管理
- 与终端联动浏览远程目录（跟随 shell 中的 `cd`）。
- 使用 **rsync** 上传 / 下载文件与文件夹，网络不稳定时支持 **断点续传**。
- 任务窗口显示每个任务的进度，支持暂停 / 恢复 / 取消，错误信息可直接复制。

### 端口转发
- 创建 **本地 (-L)**、**远程 (-R)**、**动态 (-D)** 三种转发。
- 一键启动 / 停止，自动保活与断线重启。
- 端口冲突检测，可选择结束占用进程。

### 会话复用
- 连接现有的 **tmux** / **zellij** 会话，新建会话或分离会话，本地与远程均支持。

### 代码片段
- 按分类保存常用 Shell / Python 片段。
- 双击即可在当前终端中执行。

### 系统监控
- 基于 [xtop](https://github.com/rarnu/xtop)，实时展示本地或远程主机的
  CPU / 内存 / 磁盘 / 网络 / GPU 卡片。

### Docker 管理
- 浏览远程主机上的容器、镜像、卷与网络。
- 支持容器启动 / 停止 / 重启 / 删除、查看日志、删除镜像。

### 端口占用
- 查看本机或远程主机上哪个进程在监听哪个端口。

### AI 助手
- 与 LLM（兼容 OpenAI 接口）对话，自动携带 **当前终端上下文**
  （目录、SSH 主机、标题）。
- 应答中的命令与脚本以可运行块展示，一键复制到终端。

### 更多
- **快捷终端（Quick Terminal）** —— 通过全局快捷键呼出的下拉式终端。
- **命令面板** 与 **分屏**，满足日常终端使用。
- **设置窗口** —— 全部通过原生 GUI 配置（无需手写配置文件），
  含主题预览与快捷键设置。
- **iCloud 同步** —— 通过 iCloud Drive 在多台 Mac 间同步配置、
  SSH 主机、端口转发规则与代码片段。
- 基于快速、原生的 **Ghostty** 终端引擎构建。

---

## iPad 版 ExGhostty

ExGhostty 同样可以在 iPad 上运行。由于 iOS 没有系统自带的 `ssh`
命令，iPad 版将 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
终端引擎与 [swift-nio-ssh](https://github.com/apple/swift-nio-ssh)
SSH 协议栈直接内嵌在 App 中：

- **SSH 连接管理** —— 支持密码 / 私钥认证与跳板机；iPad 锁屏或应用
  回到后台后自动重连。
- **多标签页** —— 多个会话并存，还包含内置浏览器标签页，可直接打开
  端口转发规则暴露的页面。
- **与 Mac 版一致的工具面板** —— SFTP 文件管理、端口转发
  （-L / -R / -D）、tmux / zellij 会话复用、Docker 管理、系统监控、
  端口占用与 AI 助手。
- 内置 **574 套 Ghostty / iTerm2 主题** 与 5 款等宽字体。
- 密码与私钥保存在 **iOS 钥匙串（Keychain）** 中。

### 物理键盘支持

iPad 版针对物理键盘（妙控键盘、蓝牙或 USB-C 键盘）做了专门优化：

- 连接物理键盘后，屏幕上的 Esc / Ctrl 辅助输入条会 **自动隐藏**，
  让终端占满整块屏幕；键盘断开后自动恢复。
- **完整的输入法支持** —— 中 / 日 / 韩输入法的候选窗口会锚定在终端
  光标位置，体验与桌面终端一致。
- 工具条上的 **输入法状态徽标** 实时显示当前输入法
  （中 / 繁 / EN / あ / 한 …）。

### 使用 iLoader 侧载安装

iPad 版不上架 App Store，
[Releases](https://github.com/rarnu/ExGhostty/releases) 页面提供了
预编译的 IPA，通过
[iLoader](https://github.com/nab138/iloader)（免费开源，支持
Windows / macOS / Linux）侧载安装即可：

1. 在电脑上下载
   [Releases](https://github.com/rarnu/ExGhostty/releases) 页面中的
   `ExGhostty.ipa`。
2. 用 USB 数据线将 iPad 连接到电脑，打开 **iLoader**。
3. 在 iLoader 中登录你的 Apple ID，然后选择下载好的
   `ExGhostty.ipa` —— iLoader 会用你的账号签名并安装到设备上。
4. 在 iPad 上进入 **设置 → 通用 → VPN 与设备管理**，信任你的开发者
   证书；如有提示请开启 **开发者模式**。

免费 Apple ID 的签名有效期为 **7 天**，到期后用 iLoader 重新签名即可
（也可以通过 iLoader 安装 SideStore，在设备上直接续签）。付费开发者
账号的签名有效期为一年。

---

## 环境要求

### macOS 应用
- macOS
- [Zig](https://ziglang.org) **0.15.2**
- Xcode（用于构建 macOS 应用）

### iPad 应用
- 运行 **iPadOS 26** 或更高版本的 iPad
- Xcode（用于构建 iPad 应用）—— 工程位于
  `ipad/App/ExGhostty_iPad.xcodeproj`，scheme 为 `ExGhostty_iPad`；
  依赖通过本地 Swift 包解析，无需额外配置

## 编译

```bash
./release.sh
```

编译产物位于 `zig-out/ExGhostty.app`。

iPad 版可直接从
[Releases](https://github.com/rarnu/ExGhostty/releases) 下载预编译 IPA，
安装方法见 [使用 iLoader 侧载安装](#使用-iloader-侧载安装)。如需从源码
编译，请用 Xcode 打开 `ipad/App/ExGhostty_iPad.xcodeproj` 并构建
`ExGhostty_iPad` scheme。

## 使用方法

1. 启动 **ExGhostty**。
2. 使用 **左侧栏** 创建和管理 SSH 连接与本地终端。
3. 使用 **右侧栏** 打开各项工具：SFTP、端口转发、会话复用、系统监控、
   代码片段与 AI 助手。
4. 打开 **设置** 调整外观、主题、快捷键、同步与语言 —— 无需编辑配置文件。

---

## 许可证

ExGhostty 免费且开源，许可证详情请见仓库。