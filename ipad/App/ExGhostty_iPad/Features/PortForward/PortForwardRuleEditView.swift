//
//  PortForwardRuleEditView.swift
//  iOSTerminal
//
//  Add / edit form for a port forwarding rule.
//

import SwiftUI

/// 端口转发规则编辑表单：名称、类型、监听/目标地址端口（动态类型无目标项）、启用开关。
struct PortForwardRuleEditView: View {
    @Environment(\.dismiss) private var dismiss

    let connectionID: UUID
    /// nil when creating a new rule.
    let rule: PortForwardRule?

    @State private var name: String
    @State private var type: PortForwardType
    @State private var listenHost: String
    @State private var listenPort: String
    @State private var targetHost: String
    @State private var targetPort: String
    @State private var isEnabled: Bool

    private let store = PortForwardStore.shared

    init(connectionID: UUID, rule: PortForwardRule? = nil) {
        self.connectionID = connectionID
        self.rule = rule
        _name = State(initialValue: rule?.name ?? "")
        _type = State(initialValue: rule?.type ?? .local)
        _listenHost = State(initialValue: rule?.listenHost ?? "127.0.0.1")
        _listenPort = State(initialValue: rule.map { String($0.listenPort) } ?? "8080")
        _targetHost = State(initialValue: rule?.targetHost ?? "127.0.0.1")
        _targetPort = State(initialValue: rule.map { String($0.targetPort) } ?? "80")
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
    }

    private var trimmedListenHost: String {
        listenHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTargetHost: String {
        targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isValidPort(_ text: String) -> Bool {
        guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return (1...65535).contains(port)
    }

    private var canSave: Bool {
        !trimmedListenHost.isEmpty
            && isValidPort(listenPort)
            && (type == .dynamic || (!trimmedTargetHost.isEmpty && isValidPort(targetPort)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("名称（可选）", text: $name)
                    Picker("类型", selection: $type) {
                        ForEach(PortForwardType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                Section(type == .remote ? "服务器监听" : "本机监听") {
                    TextField("监听地址", text: $listenHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("监听端口（1-65535）", text: $listenPort)
                        .keyboardType(.numberPad)
                }

                if type != .dynamic {
                    Section(type == .remote ? "转发目标（从本机可达）" : "转发目标（从服务器可达）") {
                        TextField("目标地址", text: $targetHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("目标端口（1-65535）", text: $targetPort)
                            .keyboardType(.numberPad)
                    }
                }

                Section {
                    Toggle("启用", isOn: $isEnabled)
                        .tint(.teal)
                }
            }
            .navigationTitle(rule == nil ? "新增规则" : "编辑规则")
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
        }
    }

    private func save() {
        let listenPortNumber = Int(listenPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let targetPortNumber = Int(targetPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        if var existing = rule {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.type = type
            existing.listenHost = trimmedListenHost
            existing.listenPort = listenPortNumber
            existing.targetHost = trimmedTargetHost
            existing.targetPort = targetPortNumber
            existing.isEnabled = isEnabled
            store.update(existing)
        } else {
            let newRule = PortForwardRule(
                connectionID: connectionID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                type: type,
                listenHost: trimmedListenHost,
                listenPort: listenPortNumber,
                targetHost: trimmedTargetHost,
                targetPort: targetPortNumber,
                isEnabled: isEnabled
            )
            store.add(newRule)
        }
        dismiss()
    }
}

#Preview {
    PortForwardRuleEditView(connectionID: UUID())
}
