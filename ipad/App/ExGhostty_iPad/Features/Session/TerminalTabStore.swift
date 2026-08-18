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
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    let config: SSHConnectionConfig
    let session: SSHSession
    let terminalBox = TerminalBox()

    var title: String { config.displayName }

    private var cancellable: AnyCancellable?

    @MainActor
    init(config: SSHConnectionConfig) {
        self.config = config
        let session = SessionFactory.makeSession(for: config)
        self.session = session
        // Views observing the tab still refresh when the session publishes.
        cancellable = session.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Connects on first use.
    @MainActor
    func connectIfNeeded() async {
        guard session.state == .idle else { return }
        try? await session.connect()
    }

    /// 回到前台时被调用：失败/断开的会话重连（成功后 SwiftUI 会从
    /// 错误页切回终端，新的宿主控制器自动重开 shell）。
    @MainActor
    func reconnectIfNeeded() async {
        switch session.state {
        case .failed, .closed:
            try? await session.ensureConnected()
        default:
            break
        }
    }

    func disconnect() {
        session.disconnect()
    }
}

@MainActor
final class TerminalTabStore: ObservableObject {
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID?

    /// Opens a connection in a tab; focuses the existing tab if this
    /// connection already has one.
    func open(_ config: SSHConnectionConfig) {
        if let existing = tabs.first(where: { $0.config.id == config.id }) {
            activeTabID = existing.id
            return
        }
        let tab = TerminalTab(config: config)
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
        for tab in tabs where tab.config.id == configID {
            close(tab)
        }
    }

    func activate(_ tab: TerminalTab) {
        activeTabID = tab.id
    }
}
