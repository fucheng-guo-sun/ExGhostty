//
//  PortForwardRule.swift
//  iOSTerminal
//
//  Port forwarding rules bound to a connection, persisted as JSON in
//  UserDefaults. Secrets are not involved so no Keychain needed here.
//

import Foundation

enum PortForwardType: String, Codable, CaseIterable, Identifiable {
    /// ssh -L: listen locally on the device, forward to target via the server.
    case local
    /// ssh -R: listen on the server, forward to target reachable from the device.
    case remote
    /// ssh -D: local SOCKS5 proxy on the device, exits via the server.
    case dynamic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "本地 (-L)"
        case .remote: return "远程 (-R)"
        case .dynamic: return "动态 (-D)"
        }
    }

    /// The ssh CLI flag equivalent.
    var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }
}

struct PortForwardRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var connectionID: UUID = UUID()
    var name: String = ""
    var type: PortForwardType = .local
    /// Local: address on this device. Remote: listen address on the server.
    var listenHost: String = "127.0.0.1"
    var listenPort: Int = 8080
    /// Local: destination reachable from the server. Remote: destination reachable
    /// from this device. Unused for dynamic.
    var targetHost: String = "127.0.0.1"
    var targetPort: Int = 80
    var isEnabled: Bool = true

    var summary: String {
        switch type {
        case .local:
            return "\(listenHost):\(listenPort) → \(targetHost):\(targetPort)"
        case .remote:
            return "\(listenHost):\(listenPort) ⇢ \(targetHost):\(targetPort)"
        case .dynamic:
            return "SOCKS5 \(listenHost):\(listenPort)"
        }
    }
}

final class PortForwardStore: ObservableObject {
    static let shared = PortForwardStore()

    private let defaultsKey = "iosterminal.portForwardRules"

    @Published private(set) var rules: [PortForwardRule] = []

    init() {
        load()
    }

    func rules(for connectionID: UUID) -> [PortForwardRule] {
        rules.filter { $0.connectionID == connectionID }
    }

    func add(_ rule: PortForwardRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: PortForwardRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func delete(_ rule: PortForwardRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    func deleteAll(for connectionID: UUID) {
        rules.removeAll { $0.connectionID == connectionID }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([PortForwardRule].self, from: data) else {
            rules = []
            return
        }
        rules = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Replaces the whole rule set (used by iCloud sync).
    func replaceAll(_ newRules: [PortForwardRule]) {
        rules = newRules
        save()
    }
}
