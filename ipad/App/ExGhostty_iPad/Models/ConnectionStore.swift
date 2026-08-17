//
//  ConnectionStore.swift
//  iOSTerminal
//
//  Persists SSH connection configs as JSON in UserDefaults.
//  Passwords live in Keychain (see KeychainHelper), never in this store.
//

import Foundation

final class ConnectionStore: ObservableObject {
    static let shared = ConnectionStore()

    private let defaultsKey = "iosterminal.connections"

    @Published private(set) var connections: [SSHConnectionConfig] = []

    init() {
        load()
    }

    func add(_ config: SSHConnectionConfig, password: String?) {
        connections.append(config)
        if let password { KeychainHelper.savePassword(password, for: config.id) }
        save()
    }

    func update(_ config: SSHConnectionConfig, password: String?) {
        guard let index = connections.firstIndex(where: { $0.id == config.id }) else { return }
        connections[index] = config
        // nil = keep existing password; empty string = clear
        if let password {
            if password.isEmpty {
                KeychainHelper.deletePassword(for: config.id)
            } else {
                KeychainHelper.savePassword(password, for: config.id)
            }
        }
        save()
    }

    func delete(_ config: SSHConnectionConfig) {
        connections.removeAll { $0.id == config.id }
        KeychainHelper.deletePassword(for: config.id)
        KeychainHelper.deleteIdentityPassword(for: config.id)
        save()
    }

    func password(for config: SSHConnectionConfig) -> String {
        KeychainHelper.password(for: config.id) ?? ""
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SSHConnectionConfig].self, from: data) else {
            connections = []
            return
        }
        connections = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
