import Foundation

/// SSH 连接的「用户身份」：登录后自动 sudo su 到配置的目标用户，
/// 后续所有远程命令（SFTP、Docker、System Monitor 等）都以该用户身份执行。
///
/// 身份来自连接配置（`SSHConnection.effectiveIdentity`），在 SSH 配置中按连接设置，
/// 不再支持运行时切换。`SSHCommandExecutor` 在执行任何远程命令前都会查询有效身份，
/// 并按有效身份把命令包装为 `sudo -u <user> sh -c '...'`。
enum SSHIdentity {
    /// 一条有效身份记录：目标用户名 + sudo 密码（回答 sudo 提示用，可为空表示 NOPASSWD 或未提供）。
    struct Identity: Hashable {
        let username: String
        let sudoPassword: String?
    }

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

    /// 远端 sudo askpass 助手路径（按连接配置区分）。
    static func sudoAskpassPath(connectionID: UUID) -> String {
        "/tmp/.ghostty_sudo_askpass_\(connectionID.uuidString)"
    }

    /// 把任意值包裹为 shell 单引号字符串，内部的单引号转义为 `'\''`。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
