import AppKit
import SwiftUI

/// 远程主机用户条目（/etc/passwd 中可登录的账号）。
struct RemoteUser: Identifiable, Hashable {
    let name: String
    let uid: Int

    var id: String { name }
}

/// 用户身份面板模型：拉取远程用户列表，处理身份切换与验证。
@MainActor
final class UserIdentityPanelModel: ObservableObject {
    @Published private(set) var users: [RemoteUser] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let connection: SSHConnection

    /// 切换是否正在进行（验证期间禁用列表点击）。
    @Published private(set) var isSwitching = false

    init(connection: SSHConnection) {
        self.connection = connection
    }

    var effectiveIdentity: SSHIdentityStore.Identity? {
        SSHIdentityStore.shared.identity(for: connection.identityKey)
    }

    /// 当前有效用户名（未切换时为登录用户）。
    var effectiveUsername: String {
        effectiveIdentity?.username ?? connection.username
    }

    // MARK: - 用户列表

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let output = try await SSHCommandExecutor.shared.execute(
                remoteCommand: "getent passwd 2>/dev/null || cat /etc/passwd",
                connection: connection
            )
            users = Self.parsePasswd(output)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 解析 /etc/passwd 格式，过滤不能登录的系统账号（nologin/false/sync/halt/shutdown），
    /// root 排最前，其余按 uid 升序。
    static func parsePasswd(_ text: String) -> [RemoteUser] {
        let excludedShells = ["nologin", "false", "sync", "halt", "shutdown"]
        return text.components(separatedBy: .newlines)
            .compactMap { line -> RemoteUser? in
                let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count >= 7 else { return nil }
                let shell = String(fields[6])
                guard !shell.isEmpty, !excludedShells.contains(where: { shell.contains($0) }) else { return nil }
                guard let uid = Int(fields[2]) else { return nil }
                return RemoteUser(name: String(fields[0]), uid: uid)
            }
            .sorted { lhs, rhs in
                if lhs.uid == 0 { return true }
                if rhs.uid == 0 { return false }
                return lhs.uid < rhs.uid
            }
    }

    // MARK: - 身份切换

    /// 切换到指定用户身份。
    /// - 目标是当前有效身份：无操作；
    /// - 目标是登录用户自身：直接恢复；若终端处于 su 状态则发送 `exit` 退出；
    /// - 其他用户：依次尝试已验证保存的 sudo 密码、连接保存的密码，都不可用时弹出输入框；
    ///   通过 `id -un`（以目标用户的登录 shell）验证生效后，在终端里发送 `sudo su - <user>` 并自动代输密码。
    /// - 任何失败：弹窗告知原因，且身份切回 SSH 登录时的用户。
    func switchTo(_ user: RemoteUser, terminalController: TerminalController?) async {
        guard !isSwitching, user.name != effectiveUsername else { return }
        errorMessage = nil

        // 切回登录用户：不需要 sudo；若终端处于 su 状态，退出 su shell。
        if user.name == connection.username {
            let wasSwitched = effectiveIdentity != nil
            SSHIdentityStore.shared.reset(for: connection.identityKey)
            if wasSwitched {
                sendToTerminal("exit", terminalController)
            }
            return
        }

        isSwitching = true
        defer { isSwitching = false }

        // 候选密码一：之前验证通过并保存的 sudo 密码，直接复用。
        if let saved = SSHIdentityStore.shared.savedSudoPassword(for: connection.id),
           await applyIdentity(user.name, password: saved, terminalController: terminalController) == nil {
            return
        }

        // 候选密码二：连接保存的密码通常即登录用户的 sudo 密码。
        if connection.authMode == .password, !connection.password.isEmpty,
           await applyIdentity(user.name, password: connection.password, terminalController: terminalController) == nil {
            return
        }

        // 候选密码都不可用（或密钥登录），弹出密码输入框；密码不对时同样回到这里再弹。
        guard let input = await promptSudoPassword() else { return }
        if let failureReason = await applyIdentity(user.name, password: input, terminalController: terminalController) {
            // 最终失败：弹窗告知原因（store 已在 applyIdentity 内切回登录用户）。
            showSwitchFailure(failureReason)
        }
    }

    /// 写入身份并验证；失败时切回登录用户并返回失败原因（nil 表示成功）。
    /// 验证通过后保存密码供下次复用，并在终端里完成身份切换（自动代输密码，且验证终端实际用户）。
    ///
    /// 验证命令以目标用户的登录 shell 执行（sudo -s -c），与 `su -` 语义一致，
    /// 可提前发现「该用户不可登录」（nologin 等）的情况。
    private func applyIdentity(_ username: String, password: String?, terminalController: TerminalController?) async -> String? {
        // 记录切换前的身份（nil = 登录用户），用于终端切换失败时保持 store 与终端一致。
        let previousIdentity = effectiveIdentity
        SSHIdentityStore.shared.setIdentity(
            .init(username: username, sudoPassword: password),
            for: connection.identityKey
        )
        var failureReason: String?
        do {
            let output = try await SSHCommandExecutor.shared.execute(
                remoteCommand: "id -un",
                connection: connection,
                useTargetShell: true
            )
            if output.trimmingCharacters(in: .whitespacesAndNewlines) != username {
                failureReason = "Authentication failed or sudo is unavailable".localized
            }
        } catch {
            // 区分「目标用户不可登录」（sudo: This account is currently not available 等）
            // 与其他认证/权限失败，便于用户定位原因。
            let text = error.localizedDescription.lowercased()
            if text.contains("not available") || text.contains("unknown user") {
                failureReason = "The target user is not allowed to log in".localized
            } else {
                failureReason = "Authentication failed or sudo is unavailable".localized
            }
        }
        if let failureReason {
            // 切回 SSH 登录时的用户。
            SSHIdentityStore.shared.reset(for: connection.identityKey)
            return failureReason
        }
        if let password, !password.isEmpty {
            SSHIdentityStore.shared.saveSudoPassword(password, for: connection.id)
        }
        await performTerminalSwitch(
            username: username,
            password: password,
            previousIdentity: previousIdentity,
            terminalController: terminalController
        )
        return nil
    }

    /// 在终端里完成身份切换：向终端发送一条短的切换命令，由后台预置的脚本自报告结果。
    ///
    /// 机制（替代终端探测命令，探测命令在 shell 启动期会被内核回显、擦除不干净且慢）：
    /// - 切换脚本预先经后台通道部署到远端（见 deploySwitchScript）：以 root 身份先用
    ///   非登录 shell 验证目标用户可切换并把 id -un 写入报告文件，成功才 exec 进入目标
    ///   用户的登录 shell；受限/nologin 用户在脚本内直接失败，终端停留在原 shell，不会嵌套；
    /// - 终端只发送 `sudo -k sh <脚本> <用户> <token>` 一条短命令并自动代输密码；
    /// - 后台轮询报告文件确认结果，成功后才更新 store（徽标与终端严格一致）；
    /// - 超时（受限 shell、密码被拒绝等）：发送 Ctrl-C 收回可能的 sudo 重试提示，
    ///   身份回退到 SSH 登录用户并弹提示。
    private func performTerminalSwitch(
        username: String,
        password: String?,
        previousIdentity: SSHIdentityStore.Identity?,
        terminalController: TerminalController?
    ) async {
        // 1. 部署切换脚本（幂等）。
        await deploySwitchScript()

        // 2. 处于他人身份：先 exit。无需探测验证——脚本失败时不会有任何切换动作，不会嵌套。
        if previousIdentity != nil {
            sendToTerminal("exit", terminalController)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        // 3. 发送切换命令（单行短命令，可读性可接受），需要密码时自动代输。
        let token = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        sendToTerminal("sudo -k sh \(Self.switchScriptPath) \(username) \(token)", terminalController)
        if let password, !password.isEmpty {
            try? await Task.sleep(nanoseconds: 600_000_000)
            sendToTerminal(password, terminalController)
        }

        // 4. 后台轮询报告文件。
        let reportPath = "/tmp/.gok_\(token)"
        for attempt in 0..<8 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 800_000_000)
            guard let output = try? await SSHCommandExecutor.shared.execute(
                remoteCommand: "cat \(reportPath) 2>/dev/null; rm -f \(reportPath) 2>/dev/null",
                connection: connection
            ) else { continue }
            let user = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else { continue }
            if user == username {
                // 终端已确认切换成功，更新 store。
                SSHIdentityStore.shared.setIdentity(
                    .init(username: username, sudoPassword: password),
                    for: connection.identityKey
                )
                return
            }
            // 报告了非目标用户（理论上不会发生）：按失败处理。
            break
        }

        // 5. 超时/失败：Ctrl-C 收回可能的 sudo 重试提示，身份回退到 SSH 登录用户。
        sendToTerminal("\u{3}", terminalController)
        SSHIdentityStore.shared.reset(for: connection.identityKey)
        showSwitchFailure(
            "Switch failed or the target user's shell is restricted. The identity has been switched back to the login user.".localized,
            title: "User Identity".localized,
            style: .informational
        )
    }

    /// 把切换脚本部署到远端 /tmp（内容固定、幂等，每次切换前确保存在）。
    private func deploySwitchScript() async {
        let script = """
        #!/bin/sh
        # $1 = 目标用户，$2 = 报告 token。
        # 以 root 运行（经 sudo 调用）：先用非登录 shell 验证目标用户可切换并写报告
        # （不加载 profile，报告足够快；受限/nologin 用户在此失败），成功才 exec 进入登录 shell。
        f=/tmp/.gok_$2
        rm -f "$f" 2>/dev/null
        su "$1" -c "id -un>'$f'; chmod 644 '$f'" 2>/dev/null && exec su - "$1"
        exit 1
        """
        let b64 = Data(script.utf8).base64EncodedString()
        _ = try? await SSHCommandExecutor.shared.execute(
            remoteCommand: "echo \(b64) | base64 -d > \(Self.switchScriptPath); chmod 755 \(Self.switchScriptPath)",
            connection: connection
        )
    }

    /// 远端切换脚本路径（内容无密钥，多连接共用无冲突）。
    private static let switchScriptPath = "/tmp/.ghostty_switch.sh"

    /// 切换结果弹窗（失败或需要用户确认时告知原因）。
    private func showSwitchFailure(_ message: String, title: String = "Identity switch failed".localized, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK".localized)
        if let win = NSApp.keyWindow {
            alert.beginSheetModal(for: win) { _ in }
        } else {
            alert.runModal()
        }
    }

    /// 弹出 sudo 密码输入框；用户取消返回 nil。
    private func promptSudoPassword() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let alert = NSAlert()
                alert.messageText = L("Enter the sudo password for %@", self.connection.username)
                alert.addButton(withTitle: "OK".localized)
                alert.addButton(withTitle: "Cancel".localized)
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                alert.accessoryView = field

                if let win = NSApp.keyWindow {
                    alert.beginSheetModal(for: win) { resp in
                        continuation.resume(returning: resp == .alertFirstButtonReturn ? field.stringValue : nil)
                    }
                    alert.window.initialFirstResponder = field
                } else {
                    let resp = alert.runModal()
                    continuation.resume(returning: resp == .alertFirstButtonReturn ? field.stringValue : nil)
                }
            }
        }
    }

    /// 向当前终端发送一行命令并回车。
    private func sendToTerminal(_ text: String, _ terminalController: TerminalController?) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }
        surface.sendText(text)
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press, text: "\r"))
    }
}

/// 右侧栏“用户身份”功能面板：显示远程主机用户列表，支持切换有效身份。
struct UserIdentityPanelView: View {
    let terminalController: TerminalController?

    @StateObject private var model: UserIdentityPanelModel
    @ObservedObject private var identityStore = SSHIdentityStore.shared

    init(connection: SSHConnection, terminalController: TerminalController?) {
        self.terminalController = terminalController
        _model = StateObject(wrappedValue: UserIdentityPanelModel(connection: connection))
    }

    private var effectiveIdentity: SSHIdentityStore.Identity? {
        identityStore.identity(for: model.connection.identityKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.users.isEmpty {
                emptyView
            } else {
                userList
            }
            if effectiveIdentity != nil {
                Divider()
                switchBackBar
            }
            if let error = model.errorMessage, !error.isEmpty {
                Divider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await model.refresh() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Users".localized)
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button(action: { Task { await model.refresh() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .disabled(model.isLoading)
            .help("Refresh".localized)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var userList: some View {
        List {
            ForEach(model.users) { user in
                userRow(user)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func userRow(_ user: RemoteUser) -> some View {
        let isLogin = user.name == model.connection.username
        let isCurrent = user.name == model.effectiveUsername
        return HStack(spacing: 12) {
            Image(systemName: "person.circle")
                .font(.system(size: 16))
                .foregroundColor(isCurrent ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.system(size: 14, weight: .medium))
                Text(verbatim: "UID \(user.uid)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isLogin {
                badge("Login User".localized, color: .secondary)
            }
            if isCurrent {
                badge("Current Identity".localized, color: .accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.switchTo(user, terminalController: terminalController) }
        }
        .opacity(model.isSwitching ? 0.5 : 1)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    private var switchBackBar: some View {
        Button(action: {
            if let loginUser = model.users.first(where: { $0.name == model.connection.username }) {
                Task { await model.switchTo(loginUser, terminalController: terminalController) }
            }
        }) {
            Text("Switch back to login user".localized)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .padding(.vertical, 10)
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text("No users found".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
