//
//  SessionReuseViewModel.swift
//  iOSTerminal
//
//  View model for the session reuse panel: detects tmux/zellij on the remote
//  host over SSH (one-shot exec), lists sessions, and builds the shell
//  commands that get "typed" into the live terminal.
//

import Foundation
import SwiftUI

/// Multiplexer kinds supported by the session reuse panel.
enum MultiplexerKind: String, CaseIterable, Identifiable {
    case tmux
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
    @Published var zellijInstalled = false
    @Published var tmuxSessions: [String] = []
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
            async let tmuxCheck = checkInstalled("tmux")
            async let zellijCheck = checkInstalled("zellij")
            let tmux = try await tmuxCheck
            let zellij = try await zellijCheck

            async let tmuxList = tmux ? listTmuxSessions() : []
            async let zellijList = zellij ? listZellijSessions() : []

            tmuxInstalled = tmux
            zellijInstalled = zellij
            tmuxSessions = await tmuxList
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

    private func checkInstalled(_ command: String) async throws -> Bool {
        let result = try await session.exec("command -v \(command)")
        if let status = result.exitStatus {
            return status == 0
        }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func listTmuxSessions() async -> [String] {
        do {
            let result = try await session.exec("tmux list-sessions -F '#S'")
            // 远端 tmux 服务未运行时返回非零退出码，按无会话处理。
            guard (result.exitStatus ?? 0) == 0 else { return [] }
            return result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        } catch {
            return []
        }
    }

    private func listZellijSessions() async -> [String] {
        do {
            let result = try await session.exec("zellij list-sessions")
            guard (result.exitStatus ?? 0) == 0 else { return [] }
            return result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    // zellij 输出带 ANSI 颜色/状态后缀，剥离后取每行第一个词作为会话名。
                    let cleaned = String(line).strippingANSISequences()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return nil }
                    let first = cleaned.split(separator: " ", omittingEmptySubsequences: true).first
                    return first.map(String.init)
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
        case .zellij: return "zellij attach --create \(escaped)"
        }
    }

    private func attachCommand(kind: MultiplexerKind, name: String) -> String {
        let escaped = shellQuote(name)
        switch kind {
        case .tmux:
            // 已在 tmux 内（$TMUX 非空）时用 switch-client 切换，避免嵌套 attach。
            return "if [ -n \"$TMUX\" ]; then tmux switch-client -t \(escaped); else tmux attach-session -t \(escaped); fi"
        case .zellij:
            return "zellij attach \(escaped)"
        }
    }

    private func killCommand(kind: MultiplexerKind, name: String) -> String {
        let escaped = shellQuote(name)
        switch kind {
        case .tmux: return "tmux kill-session -t \(escaped)"
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
        case .tmux:
            // tmux 前缀 Ctrl-b（0x02）+ d。
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
        sendToTerminal(Self.installCommand(for: kind))
        schedulePostCommandRefresh()
    }

    /// Ubuntu 上的一键安装命令。
    static func installCommand(for kind: MultiplexerKind) -> String {
        switch kind {
        case .tmux:
            return "sudo apt-get update && sudo apt-get install -y tmux"
        case .zellij:
            return "sudo apt-get update && sudo apt-get install -y zellij"
        }
    }
}

// MARK: - ANSI 转义剥离

private extension String {
    /// 移除 ANSI CSI/OSC 转义序列（zellij list-sessions 的着色输出）。
    func strippingANSISequences() -> String {
        var result = self
        let patterns = [
            "\\u{001B}\\[[0-9;?]*[ -/]*[@-~]", // CSI 序列（颜色、光标等）
            "\\u{001B}\\][^\\u{0007}]*\\u{0007}", // OSC 序列（以 BEL 结尾）
            "\\u{001B}[()][0-9A-B]", // 字符集切换
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
