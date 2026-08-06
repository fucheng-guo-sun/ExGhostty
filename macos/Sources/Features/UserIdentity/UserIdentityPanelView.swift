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
        SSHIdentityStore.shared.identity(for: connection.id)
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
    ///   通过 `id -un` 验证生效后，在终端里发送 `sudo su - <user>` 并自动代输密码。
    func switchTo(_ user: RemoteUser, terminalController: TerminalController?) async {
        guard !isSwitching, user.name != effectiveUsername else { return }
        errorMessage = nil

        // 切回登录用户：不需要 sudo；若终端处于 su 状态，退出 su shell。
        if user.name == connection.username {
            let wasSwitched = effectiveIdentity != nil
            SSHIdentityStore.shared.reset(for: connection.id)
            if wasSwitched {
                sendToTerminal("exit", terminalController)
            }
            return
        }

        isSwitching = true
        defer { isSwitching = false }

        // 候选密码一：之前验证通过并保存的 sudo 密码，直接复用。
        if let saved = SSHIdentityStore.shared.savedSudoPassword(for: connection.id),
           await applyIdentity(user.name, password: saved, terminalController: terminalController) {
            return
        }

        // 候选密码二：连接保存的密码通常即登录用户的 sudo 密码。
        if connection.authMode == .password, !connection.password.isEmpty,
           await applyIdentity(user.name, password: connection.password, terminalController: terminalController) {
            return
        }

        // 候选密码都不可用（或密钥登录），弹出密码输入框；密码不对时同样回到这里再弹。
        guard let input = await promptSudoPassword() else { return }
        if await applyIdentity(user.name, password: input, terminalController: terminalController) { return }
        errorMessage = "Authentication failed or sudo is unavailable".localized
    }

    /// 写入身份并验证；失败时回滚并返回 false。验证通过后保存密码供下次复用，
    /// 并在终端里完成身份切换（自动代输密码，且验证终端实际用户）。
    private func applyIdentity(_ username: String, password: String?, terminalController: TerminalController?) async -> Bool {
        // 记录切换前终端是否处于他人身份（su shell 中），决定终端切换时是否先 exit。
        let wasSwitched = effectiveIdentity != nil
        SSHIdentityStore.shared.setIdentity(
            .init(username: username, sudoPassword: password),
            for: connection.id
        )
        let verified: Bool
        do {
            let output = try await SSHCommandExecutor.shared.execute(remoteCommand: "id -un", connection: connection)
            verified = output.trimmingCharacters(in: .whitespacesAndNewlines) == username
        } catch {
            verified = false
        }
        guard verified else {
            SSHIdentityStore.shared.reset(for: connection.id)
            return false
        }
        if let password, !password.isEmpty {
            SSHIdentityStore.shared.saveSudoPassword(password, for: connection.id)
        }
        await performTerminalSwitch(username: username, password: password, wasSwitched: wasSwitched, terminalController: terminalController)
        return true
    }

    /// 在终端里执行 `sudo su - <user>` 完成交互 shell 的身份切换，并验证结果。
    ///
    /// 流程：处于他人身份时先发送 `exit` 并验证终端确实回到了登录用户（exit 失败则中止并弹窗）；
    /// 然后发送切换命令——sudo 需要密码时用 `sudo -k` 使缓存凭据失效，保证一定出现密码提示，
    /// 再延时发送密码（tty 输入有缓冲，早到的密码由 sudo 读取；sudo 密码提示不回显，密码不可见；
    /// NOPASSWD 主机不发送密码，避免被当作 shell 命令打出来）；
    /// 最后探测终端的实际用户，与目标不符时弹窗告知原因。
    private func performTerminalSwitch(username: String, password: String?, wasSwitched: Bool, terminalController: TerminalController?) async {
        // 1. 处于他人身份：先 exit，并验证确实回到了登录用户，不允许在 su shell 里直接嵌套切换。
        if wasSwitched {
            sendToTerminal("exit", terminalController)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let actual = await probeTerminalUser(tag: "exit", terminalController: terminalController)
            guard actual == connection.username else {
                showSwitchFailure(L(
                    "Failed to exit the current identity (current terminal user: %@).",
                    actual ?? "unknown".localized
                ))
                return
            }
        }

        // 2. 发送切换命令（与密码）。
        if let password, !password.isEmpty {
            sendToTerminal("sudo -k su - \(username)", terminalController)
            try? await Task.sleep(nanoseconds: 900_000_000)
            sendToTerminal(password, terminalController)
        } else {
            sendToTerminal("sudo su - \(username)", terminalController)
        }
        try? await Task.sleep(nanoseconds: 900_000_000)

        // 3. 验证终端的实际用户。
        let actual = await probeTerminalUser(tag: "switch", terminalController: terminalController)
        guard actual == username else {
            showSwitchFailure(L(
                "Failed to switch identity (current terminal user: %@). The sudo password may be incorrect or sudo is unavailable.",
                actual ?? "unknown".localized
            ))
            return
        }
    }

    /// 探测终端当前实际用户：在终端里把 whoami 写入临时文件，再经后台通道读回比对。
    private func probeTerminalUser(tag: String, terminalController: TerminalController?) async -> String? {
        let path = "/tmp/ghostty_whoami_\(connection.id.uuidString)_\(tag)"
        sendToTerminal("whoami > \(path) 2>/dev/null", terminalController)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let output = try? await SSHCommandExecutor.shared.execute(
            remoteCommand: "cat \(path) 2>/dev/null; rm -f \(path) 2>/dev/null",
            connection: connection
        )
        let user = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        return user?.isEmpty == false ? user : nil
    }

    /// 切换失败弹窗，告知用户原因。
    private func showSwitchFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Identity switch failed".localized
        alert.informativeText = message
        alert.alertStyle = .warning
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
        identityStore.identity(for: model.connection.id)
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
