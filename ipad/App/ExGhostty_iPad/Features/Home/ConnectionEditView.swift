//
//  ConnectionEditView.swift
//  iOSTerminal
//
//  Add / edit form for an SSH connection.
//

import SwiftUI

struct ConnectionEditView: View {
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
    @State private var jumpHostID: UUID?
    @State private var group: String
    @State private var encoding: ConnectionEncoding
    @State private var notes: String
    @State private var identitySwitchEnabled: Bool
    @State private var identityUsername: String
    @State private var identityPassword: String

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
                Section("连接") {
                    TextField("名称（可选）", text: $name)
                    TextField("主机", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("分组（可选）", text: $group)
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
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("认证方式", selection: $authMode) {
                        ForEach(SSHAuthMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authMode {
                    case .password:
                        SecureField(
                            connection == nil ? "密码" : "密码（留空保持不变）",
                            text: $password
                        )
                    case .key:
                        if keyStore.keys.isEmpty {
                            NavigationLink {
                                SSHKeyManagementView()
                            } label: {
                                Label("还没有密钥，去导入", systemImage: "key")
                                    .foregroundStyle(.teal)
                            }
                        } else {
                            Picker("密钥", selection: $keyID) {
                                Text("未选择").tag(UUID?.none)
                                ForEach(keyStore.keys) { key in
                                    Text(key.name).tag(UUID?.some(key.id))
                                }
                            }
                            NavigationLink {
                                SSHKeyManagementView()
                            } label: {
                                Label("管理密钥", systemImage: "key")
                                    .foregroundStyle(.teal)
                            }
                        }
                        SecureField(
                            connection == nil ? "密码（可选，作为回退）" : "密码（可选，留空保持不变）",
                            text: $password
                        )
                    }
                } header: {
                    Text("认证")
                } footer: {
                    if authMode == .key {
                        Text("密钥认证失败时，可回退使用该密码登录。")
                    }
                }

                Section {
                    Toggle("登录后切换用户", isOn: $identitySwitchEnabled)
                    if identitySwitchEnabled {
                        TextField("目标用户名（如 root）", text: $identityUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(
                            hasStoredIdentityPassword
                                ? "sudo 密码（留空保持不变）"
                                : "sudo 密码（可选，NOPASSWD 可留空）",
                            text: $identityPassword
                        )
                    }
                } header: {
                    Text("User Identity")
                } footer: {
                    if identitySwitchEnabled {
                        Text("登录后自动执行 sudo su 切换到目标用户，终端及 SFTP、Docker、系统监控等远程操作均以该用户身份执行。")
                    }
                }

                Section("跳板机") {
                    Picker("跳板机", selection: $jumpHostID) {
                        Text("直连").tag(UUID?.none)
                        ForEach(jumpHostCandidates) { candidate in
                            Text(candidate.displayName).tag(UUID?.some(candidate.id))
                        }
                    }
                }

                Section("高级") {
                    Picker("编码", selection: $encoding) {
                        ForEach(ConnectionEncoding.allCases) { encoding in
                            Text(encoding.rawValue).tag(encoding)
                        }
                    }
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(connection == nil ? "新增连接" : "编辑连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
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
        }
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
            existing.jumpHostID = jumpHostID
            existing.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.encoding = encoding
            existing.notes = notes
            existing.identitySwitchEnabled = identitySwitchEnabled
            existing.identityUsername = identityUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            updateIdentityPassword(for: existing.id)
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
            config.jumpHostID = jumpHostID
            config.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
            config.identitySwitchEnabled = identitySwitchEnabled
            config.identityUsername = identityUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            updateIdentityPassword(for: config.id)
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
}
