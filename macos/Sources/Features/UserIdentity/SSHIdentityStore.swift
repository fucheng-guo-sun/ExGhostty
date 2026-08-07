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

    /// key 为 connection.identityKey（终端会话标识，同一连接配置开的多个终端互不影响）；
    /// 没有条目表示以登录用户身份执行。只在主线程修改。
    @Published private(set) var identities: [UUID: Identity] = [:]

    /// identities 的加锁快照，供非主线程同步读取。
    private let lock = NSLock()
    private var snapshot: [UUID: Identity] = [:]

    /// 验证通过的 sudo 密码（仅内存，App 重启后失效）。只在主线程读写。
    /// 按 connection.id（连接配置）保存：sudo 密码属于登录用户，同配置的终端间共享，
    /// 避免每个新终端重复弹输入框。
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
    /// useTargetShell 为 true 时用目标用户的登录 shell 执行（sudo -s -c），与 `su -`
    /// 语义一致——可提前发现「该用户不可登录」（nologin 等）的情况，供切换前验证使用。
    static func wrap(remoteCommand: String, as identity: Identity, loginUsername: String, useTargetShell: Bool = false) -> String {
        guard identity.username != loginUsername else { return remoteCommand }
        let quotedCommand = shellQuote(remoteCommand)
        let quotedUser = shellQuote(identity.username)
        // useTargetShell：用目标用户的登录 shell 执行（sudo -s），与 `su -` 语义一致，
        // 可提前发现「该用户不可登录」（nologin 等）的情况，供切换前验证使用。
        // 注意两个坑：sudo 自己的 -c 选项是 --close-from，不能写 -s -c；
        // 且 sudo 会把含空格的单个参数整体加引号传给 shell -c（被当作一个命令名），
        // 因此 -s 路径的命令必须保持原样不加引号（该路径仅用于固定的 `id -un` 验证）。
        if useTargetShell {
            if let password = identity.sudoPassword, !password.isEmpty {
                return "echo \(shellQuote(password)) | sudo -S -p '' -u \(quotedUser) -s \(remoteCommand)"
            }
            return "sudo -n -u \(quotedUser) -s \(remoteCommand)"
        }
        if let password = identity.sudoPassword, !password.isEmpty {
            return "echo \(shellQuote(password)) | sudo -S -p '' -u \(quotedUser) sh -c \(quotedCommand)"
        }
        return "sudo -n -u \(quotedUser) sh -c \(quotedCommand)"
    }

    /// 远端 sudo askpass 助手路径（按连接配置区分）。
    static func sudoAskpassPath(connectionID: UUID) -> String {
        "/tmp/.ghostty_sudo_askpass_\(connectionID.uuidString)"
    }

    /// 把任意值包裹为 shell 单引号字符串，内部的单引号转义为 `'\''`。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
