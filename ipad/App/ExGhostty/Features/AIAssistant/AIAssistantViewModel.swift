//
//  AIAssistantViewModel.swift
//  ExGhostty_iPad
//
//  View model for the AI assistant panel: manages the current
//  conversation, streams replies through AIAssistantService, collects
//  the remote server environment (cached 5 minutes) as system prompt,
//  and forwards AI-generated commands to the terminal.
//

import Foundation
import Combine
import UIKit

@MainActor
final class AIAssistantViewModel: ObservableObject {

    @Published var conversation: AIConversation
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var statusText: String?
    @Published var errorMessage: String?
    @Published var showHistory: Bool = false

    private let session: SSHSession
    private weak var terminalBox: TerminalBox?

    private var streamTask: Task<Void, Never>?

    // MARK: - 环境信息缓存（5 分钟 TTL，按会话缓存）

    private struct ContextCacheEntry {
        let text: String
        let timestamp: Date
    }

    private static var contextCache: [ObjectIdentifier: ContextCacheEntry] = [:]
    private static let contextTTL: TimeInterval = 300

    init(session: SSHSession, terminalBox: TerminalBox) {
        self.session = session
        self.terminalBox = terminalBox
        self.conversation = AIConversation()
    }

    /// 面板消失时停止流式任务并落盘历史。
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        statusText = nil
        AIAssistantHistoryStore.shared.flush()
    }

    // MARK: - 发送消息

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputText = ""
        errorMessage = nil

        conversation.messages.append(AIMessage(role: .user, content: text))
        if conversation.title == "新对话" {
            conversation.title = String(text.prefix(20))
        }
        conversation.updatedAt = Date()
        persist()

        startStream()
    }

    /// 发送失败后重试（基于现有消息重新请求一次）。
    func retry() {
        guard !isSending,
              conversation.messages.contains(where: { $0.role == .user }) else { return }
        errorMessage = nil
        startStream()
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        statusText = nil
        isSending = false
    }

    private func startStream() {
        isSending = true
        statusText = "正在采集服务器环境信息…"

        let assistantMessage = AIMessage(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        let assistantID = assistantMessage.id

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }

            let context = await self.environmentContext()
            guard !Task.isCancelled else { return }

            if self.assistantContent(id: assistantID).isEmpty {
                self.statusText = "正在等待 AI 回复…"
            }

            let history = self.conversation.messages.filter { $0.id != assistantID }

            do {
                let result = try await AIAssistantService.streamReply(
                    messages: history,
                    systemContext: context
                ) { [weak self] partial in
                    guard let self else { return }
                    self.updateAssistant(id: assistantID, content: partial)
                    if !partial.isEmpty {
                        self.statusText = nil
                    }
                }

                self.updateAssistant(id: assistantID, content: result)
                self.conversation.updatedAt = Date()
                self.persist()
            } catch is CancellationError {
                // 用户取消，不报错；保留已接收的部分内容。
                self.persist()
            } catch {
                self.errorMessage = error.localizedDescription
                // 移除未完成的助手占位消息。
                if let index = self.conversation.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.conversation.messages.remove(at: index)
                }
                self.persist()
            }

            self.statusText = nil
            self.isSending = false
        }
    }

    private func assistantContent(id: UUID) -> String {
        conversation.messages.first(where: { $0.id == id })?.content ?? ""
    }

    private func updateAssistant(id: UUID, content: String) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        conversation.messages[index].content = content
    }

    // MARK: - 远程环境采集

    /// 通过 SSH exec 在远端执行环境采集脚本，结果缓存 5 分钟。
    private func environmentContext() async -> String {
        let key = ObjectIdentifier(session)
        if let entry = Self.contextCache[key],
           Date().timeIntervalSince(entry.timestamp) < Self.contextTTL {
            return entry.text
        }

        do {
            let result = try await session.exec(Self.probeScript)
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = text.isEmpty ? "（环境信息采集无输出）" : text
            Self.contextCache[key] = ContextCacheEntry(text: context, timestamp: Date())
            return context
        } catch {
            // 采集失败不缓存，下次发送时重试。
            return "（环境信息采集失败：\(error.localizedDescription)）"
        }
    }

    /// 环境探测脚本（POSIX 兼容），整体保证以退出码 0 结束。
    private static let probeScript = """
    (
    echo "== System =="
    uname -a
    [ -f /etc/os-release ] && . /etc/os-release 2>/dev/null
    [ -n "$PRETTY_NAME" ] && echo "Distro: $PRETTY_NAME"
    echo "Shell: ${SHELL:-unknown}"
    echo "Hostname: $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
    echo "CPU cores: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
    free -h 2>/dev/null | awk '/^Mem:/{print "Memory: total " $2 ", used " $3 ", free " $4}'
    echo "== Disk =="
    df -h 2>/dev/null | awk '/^\\/dev\\//{print $NF ": " $3 "/" $2 " (" $5 " used)"}' | head -5
    echo "== Load =="
    cat /proc/loadavg 2>/dev/null | awk '{print "Load average: " $1 " " $2 " " $3}'
    uptime 2>/dev/null | sed 's/^ *//'
    ) 2>/dev/null || true
    exit 0
    """

    // MARK: - 终端 / 剪贴板

    /// 把 AI 生成的命令发送到当前终端并回车执行。
    func sendToTerminal(_ command: String) {
        guard let terminalView = terminalBox?.terminalView else { return }
        terminalView.sendText(command)
        terminalView.sendText("\r")
    }

    /// 复制文本到剪贴板。
    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: - 会话管理

    /// 新建对话。当前对话有内容时先存入历史。
    func newConversation() {
        cancel()
        errorMessage = nil
        showHistory = false

        if !conversation.messages.isEmpty {
            AIAssistantHistoryStore.shared.save(conversation)
        }
        conversation = AIConversation()
    }

    /// 切换到历史中的一条对话。当前对话有内容时先保存。
    func selectConversation(_ target: AIConversation) {
        cancel()
        errorMessage = nil
        showHistory = false

        if !conversation.messages.isEmpty {
            AIAssistantHistoryStore.shared.save(conversation)
        }

        if let fresh = AIAssistantHistoryStore.shared.conversation(id: target.id) {
            conversation = fresh
        } else {
            conversation = target
        }
    }

    /// 删除一条历史对话；若删除的是当前对话则新建一条空对话。
    func deleteConversation(id: UUID) {
        AIAssistantHistoryStore.shared.delete(id: id)
        if conversation.id == id {
            cancel()
            errorMessage = nil
            conversation = AIConversation()
        }
    }

    private func persist() {
        guard !conversation.messages.isEmpty else { return }
        AIAssistantHistoryStore.shared.save(conversation)
    }
}
