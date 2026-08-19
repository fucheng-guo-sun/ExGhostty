//
//  SessionReusePanelView.swift
//  ExGhostty_iPad
//
//  Session reuse panel: lists remote tmux/rmux/zellij sessions and lets the
//  user create / attach / kill / detach them. All operations are sent to the
//  current terminal tab as keystrokes, so the user can watch them run.
//

import SwiftUI

struct SessionReusePanelView: View {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var viewModel: SessionReuseViewModel

    /// Switches the session page back to the terminal panel (attach/create/
    /// detach all change what the terminal shows, so let the user see it).
    private let onOpenInTerminal: () -> Void

    @State private var newSessionKind: MultiplexerKind?
    @State private var newSessionName = ""
    @State private var killConfirmation: SessionKillConfirmation?

    init(session: SSHSession, terminalBox: TerminalBox, onOpenInTerminal: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: SessionReuseViewModel(session: session, terminalBox: terminalBox))
        self.onOpenInTerminal = onOpenInTerminal
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { viewModel.startAutoRefresh() }
            .onDisappear { viewModel.stopAutoRefresh() }
            .sheet(item: $newSessionKind) { kind in
                newSessionSheet(kind: kind)
            }
            .alert(item: $killConfirmation) { item in
                Alert(
                    title: Text(L("删除 %@ 会话", item.kind.displayName)),
                    message: Text(L("确定要删除会话「%@」吗？该操作不可撤销。", item.name)),
                    primaryButton: .destructive(Text(L("删除"))) {
                        viewModel.killSession(kind: item.kind, name: item.name)
                    },
                    secondaryButton: .cancel(Text(L("取消")))
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoadedOnce && viewModel.isLoading {
            loadingView
        } else if let errorMessage = viewModel.errorMessage, !viewModel.hasLoadedOnce {
            errorView(message: errorMessage)
        } else if !viewModel.tmuxInstalled && !viewModel.rmuxInstalled && !viewModel.zellijInstalled {
            installGuideView
        } else {
            sessionListView
        }
    }

    // MARK: - 加载 / 错误

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(L("正在检测远端 tmux / rmux / zellij 环境…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L("检测远端环境失败"))
                .font(.headline)
            Text(L(message))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(L("重试")) {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            Spacer()
        }
    }

    // MARK: - 安装引导

    private var installGuideView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)

                Text(L("远端未安装 tmux / rmux / zellij"))
                    .font(.headline)

                Text(L("会话复用需要远端安装终端复用工具。可以将下面的安装命令一键发送到当前终端标签页执行。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                ForEach(MultiplexerKind.allCases) { kind in
                    installCard(kind: kind)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func installCard(kind: MultiplexerKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: installIcon(for: kind))
                    .foregroundStyle(.teal)
                Text(kind.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if SessionReuseViewModel.installCommand(for: kind) != nil {
                    Button {
                        viewModel.sendInstallCommand(kind: kind)
                    } label: {
                        Label(L("发送到终端"), systemImage: "paperplane")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                }
            }

            if let command = SessionReuseViewModel.installCommand(for: kind) {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(L("rmux 不在 apt 仓库中，请参照其项目文档手动安装。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if kind == .zellij {
                Text(L("较旧的 Ubuntu 可能没有 zellij 软件包，可改用 cargo install zellij。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(white: 0.13))
        .cornerRadius(10)
        .padding(.horizontal, 16)
    }

    private func installIcon(for kind: MultiplexerKind) -> String {
        switch kind {
        case .tmux: return "terminal"
        case .rmux: return "rectangle.split.2x1"
        case .zellij: return "square.grid.2x2"
        }
    }

    // MARK: - 会话列表

    private var sessionListView: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(L("操作会以命令形式发送到当前终端标签页执行"))
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if viewModel.tmuxInstalled {
                    sessionSection(
                        kind: .tmux,
                        icon: "terminal",
                        sessions: viewModel.tmuxSessions
                    )
                }

                if viewModel.rmuxInstalled {
                    sessionSection(
                        kind: .rmux,
                        icon: "rectangle.split.2x1",
                        sessions: viewModel.rmuxSessions
                    )
                }

                if viewModel.zellijInstalled {
                    sessionSection(
                        kind: .zellij,
                        icon: "square.grid.2x2",
                        sessions: viewModel.zellijSessions
                    )
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private func sessionSection(kind: MultiplexerKind, icon: String, sessions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 20)

                Text(kind.displayName.uppercased())
                    .font(.caption.weight(.bold).monospaced())

                Spacer()

                Button {
                    newSessionName = ""
                    newSessionKind = kind
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("新建 %@ 会话", kind.displayName))

                Button {
                    viewModel.detach(kind: kind)
                    onOpenInTerminal()
                } label: {
                    Image(systemName: "escape")
                        .font(.caption.weight(.medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("从当前 %@ 会话断开", kind.displayName))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            if sessions.isEmpty {
                HStack {
                    Text(L("暂无会话"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ForEach(sessions, id: \.self) { name in
                    sessionRow(kind: kind, name: name)
                    if name != sessions.last {
                        Divider().opacity(0.15)
                            .padding(.leading, 40)
                    }
                }
            }
        }
        .background(Color(white: 0.13))
        .cornerRadius(10)
        .padding(.horizontal, 16)
    }

    private func sessionRow(kind: MultiplexerKind, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(name)
                .font(.subheadline.monospaced())
                .lineLimit(1)

            Spacer()

            Button(role: .destructive) {
                killConfirmation = SessionKillConfirmation(kind: kind, name: name)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("删除会话 %@", name))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.attachSession(kind: kind, name: name)
            onOpenInTerminal()
        }
    }

    // MARK: - 新建会话

    private func newSessionSheet(kind: MultiplexerKind) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("会话名称（仅限英文和数字）"), text: $newSessionName)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: newSessionName) { _, value in
                            // tmux/zellij 会话名仅允许英文和数字。
                            let filtered = value.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                            if filtered != value {
                                newSessionName = filtered
                            }
                        }
                } footer: {
                    Text(L("将在当前终端标签页中执行 %@ 命令。", kind.displayName))
                }
            }
            .navigationTitle(L("新建 %@ 会话", kind.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { newSessionKind = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("创建")) {
                        let name = newSessionName
                        newSessionKind = nil
                        viewModel.createSession(kind: kind, name: name)
                        onOpenInTerminal()
                    }
                    .disabled(newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(.teal)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
