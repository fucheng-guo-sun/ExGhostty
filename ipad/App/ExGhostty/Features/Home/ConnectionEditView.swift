//
//  ConnectionEditView.swift
//  ExGhostty_iPad
//
//  Add / edit form for an SSH connection.
//

import SwiftUI

struct ConnectionEditView: View {
    @StateObject private var l10n = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    /// nil when creating a new connection.
    let connection: SSHConnectionConfig?

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var authMode: SSHAuthMode
    @State private var keyID: UUID?
    @State private var keyPassphrase: String
    @State private var desktopAccess: Bool
    @State private var jumpHostID: UUID?
    @State private var group: String
    @State private var encoding: ConnectionEncoding
    @State private var notes: String
    @State private var identitySwitchEnabled: Bool
    @State private var identityUsername: String
    @State private var identityPassword: String
    /// 非 nil 时弹出「测试连接」sheet，内容即点击按钮那一刻的表单快照。
    @State private var testInput: TestConnectionInput?

    @StateObject private var store = ConnectionStore.shared
    @StateObject private var keyStore = SSHKeyStore.shared

    init(connection: SSHConnectionConfig?) {
        self.connection = connection
        _name = State(initialValue: connection?.name ?? "")
        _host = State(initialValue: connection?.host ?? "")
        _port = State(initialValue: connection.map { String($0.port) } ?? "22")
        _username = State(initialValue: connection?.username ?? "")
        // Editing: empty password field means "keep the stored one".
        _password = State(initialValue: "")
        _authMode = State(initialValue: connection?.authMode ?? .password)
        _keyID = State(initialValue: connection?.keyID)
        // Editing: empty passphrase field means "keep the stored one".
        _keyPassphrase = State(initialValue: "")
        _desktopAccess = State(initialValue: connection?.desktopAccess ?? false)
        _jumpHostID = State(initialValue: connection?.jumpHostID)
        _group = State(initialValue: connection?.group ?? "")
        _encoding = State(initialValue: connection?.encoding ?? .utf8)
        _notes = State(initialValue: connection?.notes ?? "")
        _identitySwitchEnabled = State(initialValue: connection?.identitySwitchEnabled ?? false)
        _identityUsername = State(initialValue: connection?.identityUsername ?? "")
        // Editing: empty sudo password field means "keep the stored one".
        _identityPassword = State(initialValue: "")
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a sudo password is already stored for this connection.
    private var hasStoredIdentityPassword: Bool {
        guard let id = connection?.id else { return false }
        return KeychainHelper.identityPassword(for: id) != nil
    }

    /// Whether a private-key passphrase is already stored for this connection.
    private var hasStoredKeyPassphrase: Bool {
        guard let id = connection?.id else { return false }
        return KeychainHelper.keyPassphrase(for: id) != nil
    }

    private var canSave: Bool {
        guard !trimmedHost.isEmpty,
              Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if identitySwitchEnabled,
           identityUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        switch authMode {
        case .password:
            return connection != nil || !password.isEmpty
        case .key:
            guard let keyID else { return false }
            return keyStore.keys.contains { $0.id == keyID }
        }
    }

    /// Groups already used by other connections, offered as quick-pick chips.
    private var groupSuggestions: [String] {
        let current = group.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        return store.connections
            .map { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != current }
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    /// Saved connections eligible as a jump host: everything except self and
    /// connections whose jump chain already leads back to this one.
    private var jumpHostCandidates: [SSHConnectionConfig] {
        store.connections.filter { candidate in
            candidate.id != connection?.id && !wouldCreateCycle(via: candidate)
        }
    }

    /// Picking `candidate` as jump host creates a loop when following its
    /// jump chain eventually comes back to this connection.
    private func wouldCreateCycle(via candidate: SSHConnectionConfig) -> Bool {
        guard let selfID = connection?.id else { return false }
        var visited: Set<UUID> = [selfID]
        var next = candidate.jumpHostID
        while let id = next {
            if id == selfID { return true }
            guard visited.insert(id).inserted else { return false }
            next = store.connections.first { $0.id == id }?.jumpHostID
        }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("连接")) {
                    TextField(L("名称（可选）"), text: $name)
                    TextField(L("主机"), text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("端口"), text: $port)
                        .keyboardType(.numberPad)
                    TextField(L("分组（可选）"), text: $group)
                    if !groupSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(groupSuggestions, id: \.self) { suggestion in
                                    Button {
                                        group = suggestion
                                    } label: {
                                        Text(suggestion)
                                            .font(.system(size: 13))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color(white: 0.17), in: Capsule())
                                            .foregroundStyle(.teal)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField(L("用户名"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker(L("认证方式"), selection: $authMode) {
                        ForEach(SSHAuthMode.allCases) { mode in
                            Text(L(mode.displayName)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authMode {
                    case .password:
                        SecureField(
                            connection == nil ? L("密码") : L("密码（留空保持不变）"),
                            text: $password
                        )
                    case .key:
                        if keyStore.keys.isEmpty {
                            NavigationLink {
                                SSHKeyManagementView()
                            } label: {
                                Label(L("还没有密钥，去导入"), systemImage: "key")
                                    .foregroundStyle(.teal)
                            }
                        } else {
                            Picker(L("密钥"), selection: $keyID) {
                                Text(L("未选择")).tag(UUID?.none)
                                ForEach(keyStore.keys) { key in
                                    Text(key.name).tag(UUID?.some(key.id))
                                }
                            }
                            NavigationLink {
                                SSHKeyManagementView()
                            } label: {
                                Label(L("管理密钥"), systemImage: "key")
                                    .foregroundStyle(.teal)
                            }
                        }
                        SecureField(
                            hasStoredKeyPassphrase
                                ? L("私钥密码（留空保持不变）")
                                : L("私钥密码（可选，如密钥未加密可留空）"),
                            text: $keyPassphrase
                        )
                        SecureField(
                            connection == nil ? L("密码（可选，作为回退）") : L("密码（可选，留空保持不变）"),
                            text: $password
                        )
                    }
                } header: {
                    Text(L("认证"))
                } footer: {
                    if authMode == .key {
                        Text(L("密钥认证失败时，可回退使用该密码登录。"))
                    }
                }

                Section {
                    Toggle(L("作为桌面访问"), isOn: $desktopAccess)
                } footer: {
                    if desktopAccess {
                        HStack(spacing: 0) {
                            Text(L("需要目标主机安装sshdesk服务，"))
                            Link(destination: URL(string: "https://github.com/rarnu/sshdesk-go")!) {
                                Text(L("点击查看详情")).underline()
                            }
                        }
                    }
                }

                Section {
                    Toggle(L("登录后切换用户"), isOn: $identitySwitchEnabled)
                    if identitySwitchEnabled {
                        TextField(L("目标用户名（如 root）"), text: $identityUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(
                            hasStoredIdentityPassword
                                ? L("sudo 密码（留空保持不变）")
                                : L("sudo 密码（可选，NOPASSWD 可留空）"),
                            text: $identityPassword
                        )
                    }
                } header: {
                    Text("User Identity")
                } footer: {
                    if identitySwitchEnabled {
                        Text(L("登录后自动执行 sudo su 切换到目标用户，终端及 SFTP、Docker、系统监控等远程操作均以该用户身份执行。"))
                    }
                }

                Section(L("跳板机")) {
                    Picker(L("跳板机"), selection: $jumpHostID) {
                        Text(L("直连")).tag(UUID?.none)
                        ForEach(jumpHostCandidates) { candidate in
                            Text(candidate.displayName).tag(UUID?.some(candidate.id))
                        }
                    }
                }

                Section(L("高级")) {
                    Picker(L("编码"), selection: $encoding) {
                        ForEach(ConnectionEncoding.allCases) { encoding in
                            Text(encoding.rawValue).tag(encoding)
                        }
                    }
                    TextField(L("备注"), text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                // 测试当前表单值（不必先保存）；校验失败也会在 sheet 里逐步
                // 展示原因，所以这里不随 canSave 禁用。
                Section {
                    Button {
                        testInput = makeTestInput()
                    } label: {
                        Label(L("测试连接"), systemImage: "bolt.horizontal.circle")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(.teal)
                    }
                }
            }
            .navigationTitle(connection == nil ? L("新增连接") : L("编辑连接"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("保存")) { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                // Drop a jump host selection that is no longer eligible.
                if let jumpHostID,
                   !jumpHostCandidates.contains(where: { $0.id == jumpHostID }) {
                    self.jumpHostID = nil
                }
                // Drop a key selection that no longer exists.
                if let keyID,
                   !keyStore.keys.contains(where: { $0.id == keyID }) {
                    self.keyID = nil
                }
            }
            .sheet(item: $testInput) { input in
                TestConnectionView(input: input)
            }
        }
    }

    /// 把当前表单值打成「测试连接」的输入快照；密码/私钥密码原样传递
    /// （空串 = 留空），由 ViewModel 按"留空保持已存"语义回落 Keychain。
    private func makeTestInput() -> TestConnectionInput {
        TestConnectionInput(
            existingID: connection?.id,
            host: host,
            portText: port,
            username: username,
            authMode: authMode,
            keyID: authMode == .key ? keyID : nil,
            formPassword: password,
            formKeyPassphrase: keyPassphrase,
            desktopAccess: desktopAccess,
            jumpHostID: jumpHostID
        )
    }

    private func save() {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let portNumber = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        // Store semantics: nil = keep existing password, empty string = clear.
        // The form keeps the current behaviour: an empty field passes nil.
        let passwordUpdate: String? = password.isEmpty ? nil : password

        if var existing = connection {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.host = trimmedHost
            existing.port = portNumber
            existing.username = trimmedUser
            existing.authMode = authMode
            existing.keyID = authMode == .key ? keyID : nil
            existing.desktopAccess = desktopAccess
            existing.jumpHostID = jumpHostID
            existing.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.encoding = encoding
            existing.notes = notes
            existing.identitySwitchEnabled = identitySwitchEnabled
            existing.identityUsername = identityUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            updateIdentityPassword(for: existing.id)
            updateKeyPassphrase(for: existing.id)
            store.update(existing, password: passwordUpdate)
        } else {
            var config = SSHConnectionConfig(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: trimmedHost,
                port: portNumber,
                username: trimmedUser,
                encoding: encoding,
                notes: notes
            )
            config.authMode = authMode
            config.keyID = authMode == .key ? keyID : nil
            config.desktopAccess = desktopAccess
            config.jumpHostID = jumpHostID
            config.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
            config.identitySwitchEnabled = identitySwitchEnabled
            config.identityUsername = identityUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            updateIdentityPassword(for: config.id)
            updateKeyPassphrase(for: config.id)
            store.add(config, password: passwordUpdate)
        }
        dismiss()
    }

    /// Sudo password semantics mirror the login password: non-empty field =
    /// overwrite, empty = keep; disabling the switch clears it.
    private func updateIdentityPassword(for id: UUID) {
        if !identitySwitchEnabled {
            KeychainHelper.deleteIdentityPassword(for: id)
        } else if !identityPassword.isEmpty {
            KeychainHelper.saveIdentityPassword(identityPassword, for: id)
        }
    }

    /// Key passphrase semantics mirror the sudo password: non-empty field =
    /// overwrite, empty = keep; switching to password auth clears it.
    private func updateKeyPassphrase(for id: UUID) {
        if authMode != .key {
            KeychainHelper.deleteKeyPassphrase(for: id)
        } else if !keyPassphrase.isEmpty {
            KeychainHelper.saveKeyPassphrase(keyPassphrase, for: id)
        }
    }
}
