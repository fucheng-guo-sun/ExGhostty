//
//  SessionReuseViewModel.swift
//  ExGhostty_iPad
//
//  View model for the session reuse panel: detects tmux/rmux/zellij on the
//  remote host over SSH (one-shot exec), lists sessions, and builds the
//  shell commands that get "typed" into the live terminal. Command shapes
//  follow the Mac version (macos/.../SessionReusePanelView.swift): rmux
//  shares tmux's CLI, and exec probes well-known install paths because a
//  non-login shell's PATH often misses Homebrew/cargo directories.
//

import Foundation
import SwiftUI

/// Multiplexer kinds supported by the session reuse panel.
/// rmux uses the same CLI as tmux, only the executable name differs.
enum MultiplexerKind: String, CaseIterable, Identifiable {
    case tmux
    case rmux
    case zellij

    var id: String { rawValue }

    var displayName: String { rawValue }
}

/// Pending kill confirmation for a remote session.
struct SessionKillConfirmation: Identifiable {
    let id = UUID()
    let kind: MultiplexerKind
    let name: String
}

final class SessionReuseViewModel: ObservableObject {
    let session: SSHSession
    let terminalBox: TerminalBox

    @Published var tmuxInstalled = false
    @Published var rmuxInstalled = false
    @Published var zellijInstalled = false
    @Published var tmuxSessions: [String] = []
    @Published var rmuxSessions: [String] = []
    @Published var zellijSessions: [String] = []
    @Published var isLoading = false
    @Published var hasLoadedOnce = false
    @Published var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var postCommandTask: Task<Void, Never>?

    init(session: SSHSession, terminalBox: TerminalBox) {
        self.session = session
        self.terminalBox = terminalBox
    }

    deinit {
        refreshTask?.cancel()
        postCommandTask?.cancel()
    }

    // MARK: - 定时刷新

    /// 启动 3 秒定时刷新循环（Task + sleep），面板消失时调用 stopAutoRefresh 取消。
    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - 刷新

    @MainActor
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            async let tmuxPath = resolveExecutable("tmux")
            async let rmuxPath = resolveExecutable("rmux")
            async let zellijPath = resolveExecutable("zellij")
            let tmux = try await tmuxPath
            let rmux = try await rmuxPath
            let zellij = try await zellijPath

            async let tmuxList = listTmuxLikeSessions(executable: tmux)
            async let rmuxList = listTmuxLikeSessions(executable: rmux)
            async let zellijList = listZellijSessions(executable: zellij)

            tmuxInstalled = tmux != nil
            rmuxInstalled = rmux != nil
            zellijInstalled = zellij != nil
            tmuxSessions = await tmuxList
            rmuxSessions = await rmuxList
            zellijSessions = await zellijList
            hasLoadedOnce = true
            errorMessage = nil
        } catch {
            // 定时刷新失败时保留上次成功的数据，仅首次加载失败才进入错误视图。
            if !hasLoadedOnce {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    // MARK: - 工具检测与会话列表

    /// 解析远端可执行文件路径（对齐 Mac 版）：先探常见安装路径——exec 的
    /// 非登录 shell 的 PATH 经常缺 Homebrew / cargo 目录；找不到再用登录
    /// shell 的 `command -v` 兜底。未安装返回 nil；SSH 层错误会抛出。
    private func resolveExecutable(_ command: String) async throws -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/opt/local/bin/\(command)",
            "~/.cargo/bin/\(command)",
        ]
        let probe = candidates
            .map { "test -x \($0) && echo \($0)" }
            .joined(separator: " || ")
        let probeResult = try await session.exec(probe)
        if let path = probeResult.stdout
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces),
           !path.isEmpty {
            return path
        }
        let fallback = "if [ -n \"$SHELL\" ]; then \"$SHELL\" -l -c \"command -v \(command)\"; else command -v \(command); fi"
        let fallbackResult = try await session.exec(fallback)
        guard (fallbackResult.exitStatus ?? 1) == 0 else { return nil }
        // command -v 对别名/函数会输出非路径文本，多行输出取第一行。
        let firstLine = fallbackResult.stdout
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? nil : firstLine
    }

    /// tmux / rmux 共用一套 CLI，仅可执行文件名不同（对齐 Mac 版）。
    /// executable 为 nil（未安装）时直接返回空列表。
    private func listTmuxLikeSessions(executable: String?) async -> [String] {
        guard let executable else { return [] }
        do {
            let result = try await session.exec("\(shellQuote(executable)) list-sessions -F '#S'")
            // 远端 tmux/rmux 服务未运行时返回非零退出码，按无会话处理。
            guard (result.exitStatus ?? 0) == 0 else { return [] }
            return result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        } catch {
            return []
        }
    }

    private func listZellijSessions(executable: String?) async -> [String] {
        guard let executable else { return [] }
        let zellij = shellQuote(executable)
        do {
            // zellij 0.39+ 支持 --short：每行一个纯会话名，无着色、无状态
            // 后缀，带空格的会话名也不会被截断。
            let short = try await session.exec("\(zellij) list-sessions --short")
            if (short.exitStatus ?? 1) == 0 {
                return short.stdout
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            // 老版本 zellij 的普通输出：剥离 ANSI 颜色后，按状态后缀
            // （" (Created …)" / " [Created …]" / " EXITED …"）截断取会话名。
            let result = try await session.exec("\(zellij) list-sessions")
            guard (result.exitStatus ?? 0) == 0 else { return [] }
            return result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    let cleaned = String(line).strippingANSISequences()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return nil }
                    var cut = cleaned.endIndex
                    for marker in [" (", " [", " EXITED"] {
                        if let range = cleaned.range(of: marker), range.lowerBound < cut {
                            cut = range.lowerBound
                        }
                    }
                    let name = cleaned[..<cut].trimmingCharacters(in: .whitespaces)
                    return name.isEmpty ? nil : name
                }
        } catch {
            return []
        }
    }

    // MARK: - 命令拼接

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func newSessionCommand(kind: MultiplexerKind, name: String) -> String {
        let escaped = shellQuote(name)
        switch kind {
        case .tmux: return "tmux new -s \(escaped)"
        case .rmux: return "rmux new -s \(escaped)"
        case .zellij: return "zellij attach --create \(escaped)"
        }
    }

    private func attachCommand(kind: MultiplexerKind, name: String) -> String {
        let escaped = shellQuote(name)
        switch kind {
        case .tmux:
            // 已在 tmux 内（$TMUX 非空）时用 switch-client 切换，避免嵌套 attach。
            return "if [ -n \"$TMUX\" ]; then tmux switch-client -t \(escaped); else tmux attach-session -t \(escaped); fi"
        case .rmux:
            // rmux 与 tmux 参数一致；$TMUX$RMUX 任一非空都说明已在会话内。
            return "if [ -n \"$TMUX$RMUX\" ]; then rmux switch-client -t \(escaped); else rmux attach-session -t \(escaped); fi"
        case .zellij:
            // zellij 的会话名不加引号（用户需求；zellij 对带引号的名字
            // 匹配不到已有会话）。
            return "zellij attach \(name)"
        }
    }

    private func killCommand(kind: MultiplexerKind, name: String) -> String {
        let escaped = shellQuote(name)
        switch kind {
        case .tmux: return "tmux kill-session -t \(escaped)"
        case .rmux: return "rmux kill-session -t \(escaped)"
        case .zellij: return "zellij kill-session \(escaped)"
        }
    }

    // MARK: - 发送到终端

    /// 把命令"敲"进当前终端标签页执行：先发命令文本，再发回车。
    @MainActor
    private func sendToTerminal(_ command: String) {
        terminalBox.terminalView?.sendText(command)
        terminalBox.terminalView?.sendText("\r")
    }

    /// 会话操作执行后 0.5 秒刷新一次列表。
    private func schedulePostCommandRefresh() {
        postCommandTask?.cancel()
        postCommandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - 操作入口

    @MainActor
    func createSession(kind: MultiplexerKind, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendToTerminal(newSessionCommand(kind: kind, name: trimmed))
        schedulePostCommandRefresh()
    }

    @MainActor
    func attachSession(kind: MultiplexerKind, name: String) {
        sendToTerminal(attachCommand(kind: kind, name: name))
        schedulePostCommandRefresh()
    }

    @MainActor
    func killSession(kind: MultiplexerKind, name: String) {
        sendToTerminal(killCommand(kind: kind, name: name))
        schedulePostCommandRefresh()
    }

    /// 从当前会话 detach：发送 multiplexer 前缀 + d。
    @MainActor
    func detach(kind: MultiplexerKind) {
        switch kind {
        case .tmux, .rmux:
            // tmux/rmux 前缀 Ctrl-b（0x02）+ d（两者一致，对齐 Mac 版）。
            terminalBox.terminalView?.sendText("\u{02}")
            terminalBox.terminalView?.sendText("d")
        case .zellij:
            // zellij 前缀 Ctrl-o（0x0F）+ d。
            terminalBox.terminalView?.sendText("\u{0F}")
            terminalBox.terminalView?.sendText("d")
        }
        schedulePostCommandRefresh()
    }

    /// 把安装命令发送到终端执行。
    @MainActor
    func sendInstallCommand(kind: MultiplexerKind) {
        guard let command = Self.installCommand(for: kind) else { return }
        sendToTerminal(command)
        schedulePostCommandRefresh()
    }

    /// Ubuntu 上的一键安装命令。rmux 不在 apt 仓库中，返回 nil，
    /// 面板只显示提示、不提供发送按钮。
    static func installCommand(for kind: MultiplexerKind) -> String? {
        switch kind {
        case .tmux:
            return "sudo apt-get update && sudo apt-get install -y tmux"
        case .zellij:
            return "sudo apt-get update && sudo apt-get install -y zellij"
        case .rmux:
            return nil
        }
    }
}

// MARK: - ANSI 转义剥离

private extension String {
    /// 移除 ANSI CSI/OSC 转义序列（zellij list-sessions 的着色输出）。
    /// 注意：NSRegularExpression 走 ICU 语法，不认 `\u{...}` 写法（那样
    /// 编译直接失败、strip 静默失效），所以 pattern 里直接嵌入字面
    /// ESC / BEL 字符。
    func strippingANSISequences() -> String {
        var result = self
        let patterns = [
            "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", // CSI 序列（颜色、光标等）
            "\u{001B}\\][^\u{0007}]*\u{0007}", // OSC 序列（以 BEL 结尾）
            "\u{001B}\\][^\u{001B}]*\u{001B}\\", // OSC 序列（以 ST 结尾）
            "\u{001B}[()][0-9A-B]", // 字符集切换
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result
    }
}
