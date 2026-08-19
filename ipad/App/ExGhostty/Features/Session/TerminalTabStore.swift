//
//  TerminalTabStore.swift
//  ExGhostty_iPad
//
//  Owns the open terminal tabs shown on the right side of the split view.
//  Each tab holds its own SSHSession, so backgrounded tabs keep running;
//  closing a tab disconnects the session.
//

import Foundation
import Combine

/// One open terminal tab: a connection plus its live session state.
/// kind == .browser 时是内置浏览器 tab（无 SSH 会话，config/session 为 nil，
/// 由端口转发规则的「访问页面」打开）。
final class TerminalTab: Identifiable, ObservableObject {
    enum Kind {
        case terminal
        case browser
    }

    let id = UUID()
    let kind: Kind
    /// 仅 .terminal 有值（IUO：浏览器 tab 不会触碰它们）。
    let config: SSHConnectionConfig!
    let session: SSHSession!
    /// 仅 .browser 有值。
    let browserURL: URL?
    let browserTitle: String?
    let terminalBox = TerminalBox()

    var title: String {
        switch kind {
        case .terminal: return config.displayName
        case .browser: return browserTitle ?? "Browser"
        }
    }

    private var cancellable: AnyCancellable?

    @MainActor
    init(config: SSHConnectionConfig) {
        self.kind = .terminal
        self.config = config
        self.browserURL = nil
        self.browserTitle = nil
        let session = SessionFactory.makeSession(for: config)
        self.session = session
        // Views observing the tab still refresh when the session publishes.
        cancellable = session.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    @MainActor
    init(browserURL: URL, title: String) {
        self.kind = .browser
        self.config = nil
        self.session = nil
        self.browserURL = browserURL
        self.browserTitle = title
    }

    /// Connects on first use.
    @MainActor
    func connectIfNeeded() async {
        guard kind == .terminal, session.state == .idle else { return }
        try? await session.connect()
    }

    /// 回到前台时被调用：失败/断开的会话重连（成功后 SwiftUI 会从
    /// 错误页切回终端，新的宿主控制器自动重开 shell）。
    @MainActor
    func reconnectIfNeeded() async {
        guard kind == .terminal else { return }
        switch session.state {
        case .failed, .closed:
            try? await session.ensureConnected()
        default:
            break
        }
    }

    func disconnect() {
        session?.disconnect()
    }
}

@MainActor
final class TerminalTabStore: ObservableObject {
    /// 单例：端口转发窗口（独立 hosting controller，拿不到 environmentObject）
    /// 也要能开浏览器 tab。
    static let shared = TerminalTabStore()

    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID?

    /// Opens a connection in a tab; focuses the existing tab if this
    /// connection already has one.
    func open(_ config: SSHConnectionConfig) {
        if let existing = tabs.first(where: { $0.config?.id == config.id }) {
            activeTabID = existing.id
            return
        }
        let tab = TerminalTab(config: config)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// 打开一个内置浏览器 tab（同 URL 复用已有 tab）。
    func openBrowser(url: URL, title: String) {
        if let existing = tabs.first(where: { $0.kind == .browser && $0.browserURL == url }) {
            activeTabID = existing.id
            return
        }
        let tab = TerminalTab(browserURL: url, title: title)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.disconnect()
        tabs.remove(at: index)
        if activeTabID == tab.id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Closes any tabs belonging to a deleted connection.
    func closeTabs(for configID: UUID) {
        for tab in tabs where tab.config?.id == configID {
            close(tab)
        }
    }

    func activate(_ tab: TerminalTab) {
        activeTabID = tab.id
    }
}
