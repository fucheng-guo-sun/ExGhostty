//
//  TerminalTabStore.swift
//  iOSTerminal
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
    let forwardManager: PortForwardManager
    let terminalBox = TerminalBox()

    var title: String { config.displayName }

    private var cancellable: AnyCancellable?

    @MainActor
    init(config: SSHConnectionConfig) {
        self.config = config
        let session = SessionFactory.makeSession(for: config)
        let forwardManager = PortForwardManager(session: session)
        // Listeners must be torn down before the session's event loop group
        // shuts down, whether we disconnect or the server drops us.
        session.preShutdown = { await forwardManager.stopAll() }
        self.session = session
        self.forwardManager = forwardManager
        // Views observing the tab still refresh when the session publishes.
        cancellable = session.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Connects on first use, then starts the saved port-forward rules.
    @MainActor
    func connectIfNeeded() async {
        guard session.state == .idle else { return }
        try? await session.connect()
        if session.isConnected {
            await forwardManager.startAll(
                rules: PortForwardStore.shared.rules(for: config.id)
            )
        }
    }

    func disconnect() {
        // stopAll runs inside disconnect() via preShutdown.
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
