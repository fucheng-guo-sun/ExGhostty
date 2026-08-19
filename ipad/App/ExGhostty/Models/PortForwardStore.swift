//
//  PortForwardStore.swift
//  ExGhostty_iPad
//
//  Port forwarding rules: model, persistence (UserDefaults JSON, same
//  pattern as ConnectionStore) and the app-level runtime registry.
//  Modeled on the Mac version's PortForwardRule/PortForwardStore
//  (macos/Sources/Features/Sidebar), minus the ssh-process machinery —
//  the iPad engine runs on NIO (see SSH/PortForwardRuntime.swift).
//  The store owns all runtimes, so closing the port-forward window does
//  not tear anything down; background survival uses a UIApplication
//  background task (short grace) plus re-establish on foregrounding.
//

import Foundation
import UIKit
import Combine

enum PortForwardType: String, Codable, CaseIterable, Identifiable {
    case local, remote, dynamic

    var id: String { rawValue }

    /// 分段控件上的短标题（含 ssh 参数对照，与 Mac 版一致）。
    var title: String {
        switch self {
        case .local: return "本地 (-L)"
        case .remote: return "远程 (-R)"
        case .dynamic: return "动态 (-D)"
        }
    }

    var descriptionText: String {
        switch self {
        case .local: return "把本机端口通过 SSH 转发到远端可达的某个主机端口"
        case .remote: return "把本机服务端口暴露到远端主机的监听端口上"
        case .dynamic: return "在本机起一个 SOCKS5 代理，流量经 SSH 出站"
        }
    }
}

struct PortForwardRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var type: PortForwardType = .local
    var sshConnectionID: UUID?

    /// local/dynamic：本机监听地址与端口。
    var localListenHost = "127.0.0.1"
    var localListenPort = 0
    /// local：目标主机与端口（远端视角）。
    var remoteHost = "localhost"
    var remotePort = 0
    /// remote：远端监听端口；本机被暴露的服务端口。
    var localServicePort = 0

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, sshConnectionID != nil else { return false }
        switch type {
        case .local: return (1...65535).contains(localListenPort) && (1...65535).contains(remotePort)
        case .remote: return (1...65535).contains(localServicePort) && (1...65535).contains(remotePort)
        case .dynamic: return (1...65535).contains(localListenPort)
        }
    }

    /// 列表摘要行（对齐 Mac 版 summaryText）。
    var summaryText: String {
        switch type {
        case .local: return "\(localListenHost):\(localListenPort) → \(remoteHost):\(remotePort)"
        case .remote: return "remote:\(remotePort) → localhost:\(localServicePort)"
        case .dynamic: return "SOCKS5 \(localListenHost):\(localListenPort)"
        }
    }
}

/// 运行状态（不持久化；重启 App 后一律视为已停止，需手动开启——与 Mac 版一致）。
enum PortForwardStatus: Equatable {
    case stopped
    case connecting
    case running
    case failed(String)
}

@MainActor
final class PortForwardStore: ObservableObject {
    static let shared = PortForwardStore()

    private let defaultsKey = "exghostty.ipad.portForwardRules"

    @Published private(set) var rules: [PortForwardRule] = []
    @Published private(set) var status: [UUID: PortForwardStatus] = [:]

    private var runtimes: [UUID: PortForwardRuntime] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        load()
        // 回到前台：所有"应当运行"的规则检查活性并就地恢复。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // 进后台：申请短宽限期让转发尽量多活一会儿（iOS 不允许无限后台运行，
        // 真正的恢复靠回前台时的 resume）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    // MARK: CRUD

    func upsert(_ rule: PortForwardRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            let wasRunning = status[rule.id] == .running || status[rule.id] == .connecting
            rules[index] = rule
            // 运行中的规则被编辑：按新配置重启。
            if wasRunning {
                stop(rule)
                start(rule)
            }
        } else {
            rules.append(rule)
        }
        save()
    }

    func delete(_ rule: PortForwardRule) {
        stop(rule)
        rules.removeAll { $0.id == rule.id }
        save()
    }

    // MARK: Start / Stop

    func toggle(_ rule: PortForwardRule) {
        switch status[rule.id] ?? .stopped {
        case .stopped, .failed: start(rule)
        case .connecting, .running: stop(rule)
        }
    }

    func start(_ rule: PortForwardRule) {
        guard ConnectionStore.shared.connections.contains(where: { $0.id == rule.sshConnectionID }) else {
            status[rule.id] = .failed(L("规则绑定的 SSH 连接已不存在"))
            return
        }
        let runtime = runtimes[rule.id] ?? PortForwardRuntime(rule: rule) { [weak self] id, newStatus in
            self?.status[id] = newStatus
        }
        runtime.rule = rule
        runtimes[rule.id] = runtime
        runtime.start()
    }

    func stop(_ rule: PortForwardRule) {
        runtimes[rule.id]?.stop()
        runtimes.removeValue(forKey: rule.id)
        status[rule.id] = .stopped
    }

    // MARK: 后台保活

    @objc private func appWillResignActive() {
        guard runtimes.values.contains(where: { !$0.isIntentionallyStopped }) else { return }
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PortForward") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    @objc private func appDidBecomeActive() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        for runtime in runtimes.values {
            runtime.resumeAfterForeground()
        }
    }

    // MARK: Persistence

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
}
