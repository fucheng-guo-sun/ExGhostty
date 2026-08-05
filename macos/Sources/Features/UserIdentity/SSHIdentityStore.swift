import Foundation

/// SSH 连接的运行时用户身份（不持久化，App 重启后回到登录用户）。
///
/// 「用户身份」面板切换身份后写入本 store；`SSHCommandExecutor` 在执行任何远程命令前
/// 都会查询本 store，并按有效身份把命令包装为 `sudo -u <user> sh -c '...'`，
/// 从而让右侧全部功能（SFTP、Port Usage、Docker、System Monitor、Session Reuse 查询等）
/// 自动以切换后的用户身份执行。
///
/// 写入只在主线程进行（驱动 SwiftUI 刷新）；读取通过加锁的快照进行，
/// 允许任意线程/actor 上下文同步调用。标记 `@unchecked Sendable` 即基于此约定。
final class SSHIdentityStore: ObservableObject, @unchecked Sendable {
    static let shared = SSHIdentityStore()

    /// 一条有效身份记录：目标用户名 + sudo 密码（登录用户的密码，可为空表示 NOPASSWD 或未提供）。
    struct Identity: Hashable {
        let username: String
        let sudoPassword: String?
    }

    /// key 为 connection.id；没有条目表示以登录用户身份执行。只在主线程修改。
    @Published private(set) var identities: [UUID: Identity] = [:]

    /// identities 的加锁快照，供非主线程同步读取。
    private let lock = NSLock()
    private var snapshot: [UUID: Identity] = [:]

    /// 验证通过的 sudo 密码（仅内存，按连接保存，App 重启后失效）。只在主线程读写。
    private var savedSudoPasswords: [UUID: String] = [:]

    private init() {}

    /// 查询连接当前的有效身份；nil 表示登录用户。线程安全，可在任意上下文调用。
    func identity(for connectionID: UUID) -> Identity? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot[connectionID]
    }

    /// 设置连接的有效身份。必须在主线程调用。
    @MainActor
    func setIdentity(_ identity: Identity, for connectionID: UUID) {
        identities[connectionID] = identity
        lock.lock()
        snapshot = identities
        lock.unlock()
    }

    /// 恢复为登录用户身份。必须在主线程调用。
    @MainActor
    func reset(for connectionID: UUID) {
        identities.removeValue(forKey: connectionID)
        lock.lock()
        snapshot = identities
        lock.unlock()
    }

    /// 读取已保存的 sudo 密码。必须在主线程调用。
    @MainActor
    func savedSudoPassword(for connectionID: UUID) -> String? {
        savedSudoPasswords[connectionID]
    }

    /// 保存验证通过的 sudo 密码，供后续切换直接复用。必须在主线程调用。
    @MainActor
    func saveSudoPassword(_ password: String, for connectionID: UUID) {
        savedSudoPasswords[connectionID] = password
    }

    // MARK: - 命令包装

    /// 按有效身份包装远程命令；身份为登录用户时原样返回。
    ///
    /// 有密码时通过 `sudo -S` 从 stdin 读密码；无密码时用 `sudo -n`（依赖 NOPASSWD，
    /// 否则会失败并把错误透传给调用方）。
    static func wrap(remoteCommand: String, as identity: Identity, loginUsername: String) -> String {
        guard identity.username != loginUsername else { return remoteCommand }
        let quotedCommand = shellQuote(remoteCommand)
        let quotedUser = shellQuote(identity.username)
        if let password = identity.sudoPassword, !password.isEmpty {
            return "echo \(shellQuote(password)) | sudo -S -p '' -u \(quotedUser) sh -c \(quotedCommand)"
        }
        return "sudo -n -u \(quotedUser) sh -c \(quotedCommand)"
    }

    /// 把任意值包裹为 shell 单引号字符串，内部的单引号转义为 `'\''`。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
