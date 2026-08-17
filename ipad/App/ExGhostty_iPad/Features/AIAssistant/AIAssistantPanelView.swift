//
//  AIAssistantPanelView.swift
//  ExGhostty_iPad
//
//  AI assistant panel: chat bubbles over an SSH session. AI replies are
//  streamed in; ```command code blocks can be sent straight to the
//  terminal. Conversation history is persisted locally.
//

import SwiftUI

struct AIAssistantPanelView: View {

    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var viewModel: AIAssistantViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var historyStore = AIAssistantHistoryStore.shared

    init(session: SSHSession, terminalBox: TerminalBox) {
        _viewModel = StateObject(
            wrappedValue: AIAssistantViewModel(session: session, terminalBox: terminalBox)
        )
    }

    var body: some View {
        Group {
            if AIAssistantService.isConfigured {
                mainContent
            } else {
                setupGuideView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07))
        .onDisappear {
            viewModel.stop()
        }
    }

    // MARK: - 未配置引导

    private var setupGuideView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.teal)

            Text(L("AI 助手未配置"))
                .font(.headline)

            Text(L("请先在设置页填写 AI 接口地址、API Key 和模型名称，\n然后回到此面板开始对话。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主体

    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()
                .overlay(Color(white: 0.25))

            if viewModel.showHistory {
                historyList
            } else {
                chatContent
                inputArea
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.newConversation()
            } label: {
                Label(L("新对话"), systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.teal)

            Button {
                viewModel.showHistory.toggle()
            } label: {
                Label(L("历史"), systemImage: "clock")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(viewModel.showHistory ? Color.teal : Color.secondary)

            Spacer()

            Text(settings.aiModel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color(white: 0.11))
    }

    // MARK: - 聊天内容

    private var chatContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.conversation.messages.isEmpty {
                        emptyHint
                    }

                    ForEach(viewModel.conversation.messages) { message in
                        AIMessageBubbleView(
                            message: message,
                            onSendToTerminal: { viewModel.sendToTerminal($0) },
                            onCopy: { viewModel.copyToClipboard($0) }
                        )
                        .id(message.id)
                    }

                    if let status = viewModel.statusText {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L(status))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    if let error = viewModel.errorMessage {
                        errorCard(error)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.conversation.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.conversation.messages.last?.content) {
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L("向 AI 提问关于这台服务器的问题\n回答中的命令可以直接发送到终端执行"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(L("请求失败"))
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(L(message))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                viewModel.retry()
            } label: {
                Label(L("重试"), systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.teal.opacity(0.2))
                    .foregroundStyle(Color.teal)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - 输入区

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color(white: 0.25))

            HStack(alignment: .bottom, spacing: 10) {
                TextField(L("输入你的问题…"), text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(white: 0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit {
                        viewModel.send()
                    }

                if viewModel.isSending {
                    Button {
                        viewModel.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        viewModel.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? Color.teal : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.09))
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 历史列表

    private var historyList: some View {
        Group {
            if historyStore.conversations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(L("暂无历史对话"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(historyStore.conversations) { conversation in
                        Button {
                            viewModel.selectConversation(conversation)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(Color.teal)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L(conversation.displayTitle))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(relativeDate(conversation.updatedAt))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(L("%d 条", conversation.messages.count))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteConversation(id: conversation.id)
                            } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                        }
                        .listRowBackground(Color(white: 0.11))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 消息气泡

private struct AIMessageBubbleView: View {
    @StateObject private var l10n = LocalizationManager.shared

    let message: AIMessage
    var onSendToTerminal: (String) -> Void
    var onCopy: (String) -> Void

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    Text("AI")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.teal)
                        .padding(.leading, 4)
                }

                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.role == .user
                            ? Color.teal.opacity(0.85)
                            : Color(white: 0.13)
                    )
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if message.role != .user {
                Spacer(minLength: 48)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .assistant {
            let segments = parseAISegments(message.content)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        markdownText(text)
                    case .code(let language, let code):
                        AICodeBlockView(
                            language: language,
                            code: code,
                            onSendToTerminal: { onSendToTerminal(code) },
                            onCopy: { onCopy(code) }
                        )
                    }
                }
            }
        } else {
            Text(message.content)
                .font(.system(size: 14))
                .textSelection(.enabled)
        }
    }

    private func markdownText(_ text: String) -> some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 14))
        .textSelection(.enabled)
    }
}

// MARK: - 代码块

private struct AICodeBlockView: View {
    @StateObject private var l10n = LocalizationManager.shared

    let language: String
    let code: String
    var onSendToTerminal: () -> Void
    var onCopy: () -> Void

    @State private var copied = false

    private var isCommand: Bool {
        ["command", "shell", "bash", "sh"].contains(language.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? L("代码") : language.capitalized)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            HStack(spacing: 10) {
                if isCommand {
                    Button {
                        onSendToTerminal()
                    } label: {
                        Label(L("发送到终端"), systemImage: "terminal")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.teal.opacity(0.2))
                            .foregroundStyle(Color.teal)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? L("已复制") : L("复制"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(white: 0.17))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(Color(white: 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 消息内容解析

private enum AIMessageSegment {
    case text(String)
    case code(language: String, content: String)
}

/// 把 AI 消息按 ``` 围栏代码块拆成文本 / 代码段。
private func parseAISegments(_ content: String) -> [AIMessageSegment] {
    var segments: [AIMessageSegment] = []
    var plainTextLines: [String] = []
    var inCodeBlock = false
    var codeLanguage = ""
    var codeLines: [String] = []

    func flushText() {
        if !plainTextLines.isEmpty {
            segments.append(.text(plainTextLines.joined(separator: "\n")))
            plainTextLines.removeAll()
        }
    }

    for line in content.components(separatedBy: .newlines) {
        if inCodeBlock {
            if line.hasPrefix("```") {
                flushText()
                segments.append(.code(language: codeLanguage,
                                      content: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                codeLanguage = ""
                inCodeBlock = false
            } else {
                codeLines.append(line)
            }
        } else {
            if line.hasPrefix("```") {
                flushText()
                codeLanguage = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                inCodeBlock = true
            } else {
                plainTextLines.append(line)
            }
        }
    }

    if inCodeBlock {
        // 流式输出中未闭合的代码块，作为普通文本拼回。
        plainTextLines.append("```" + codeLanguage
            + (codeLines.isEmpty ? "" : "\n" + codeLines.joined(separator: "\n")))
    }
    flushText()

    return segments
}
