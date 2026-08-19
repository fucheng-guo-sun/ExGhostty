//
//  PortForwardListView.swift
//  ExGhostty_iPad
//
//  Port forwarding rule list (start/stop toggle, edit, delete) plus the
//  add/edit sheet. Mirrors the Mac version's PortForwardListView /
//  PortForwardEditView; statuses come from PortForwardStore and keep
//  updating while this window is closed.
//

import SwiftUI

struct PortForwardListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var store = PortForwardStore.shared

    @State private var editingRule: PortForwardRule?
    @State private var ruleToDelete: PortForwardRule?

    var body: some View {
        NavigationStack {
            Group {
                if store.rules.isEmpty {
                    ContentUnavailableView {
                        Label(L("没有转发规则"), systemImage: "fibrechannel")
                    } description: {
                        Text(L("点击右上角 + 新增"))
                    }
                } else {
                    ruleList
                }
            }
            .background(Color.black)
            .navigationTitle(L("端口转发"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label(L("返回"), systemImage: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingRule = PortForwardRule()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            PortForwardEditView(rule: rule) { saved in
                store.upsert(saved)
            }
        }
        .alert(L("删除转发规则"), isPresented: deleteAlertBinding, presenting: ruleToDelete) { rule in
            Button(L("删除"), role: .destructive) {
                store.delete(rule)
            }
            Button(L("取消"), role: .cancel) {}
        } message: { rule in
            Text(rule.name)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { ruleToDelete != nil },
            set: { if !$0 { ruleToDelete = nil } }
        )
    }

    private var ruleList: some View {
        List {
            ForEach(store.rules) { rule in
                ruleRow(rule)
                    .listRowBackground(Color(white: 0.15))
                    .contextMenu {
                        Button {
                            editingRule = rule
                        } label: {
                            Label(L("编辑"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            ruleToDelete = rule
                        } label: {
                            Label(L("删除"), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            ruleToDelete = rule
                        } label: {
                            Label(L("删除"), systemImage: "trash")
                        }
                        Button {
                            editingRule = rule
                        } label: {
                            Label(L("编辑"), systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func ruleRow(_ rule: PortForwardRule) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(rule.name)
                        .font(.system(size: 16, weight: .semibold))
                    statusBadge(rule)
                }
                Text(rule.summaryText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                if case .failed(let message) = store.status[rule.id] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            // 仅本地转发（-L）运行中可访问：URL 即 http://127.0.0.1:监听端口。
            // -R 方向相反、-D 是 SOCKS 代理，都没有可直接访问的页面。
            if rule.type == .local, case .running = store.status[rule.id] {
                Button {
                    guard let url = URL(string: "http://127.0.0.1:\(rule.localListenPort)/") else { return }
                    TerminalTabStore.shared.openBrowser(url: url, title: rule.name)
                    dismiss()
                } label: {
                    Label(L("访问页面"), systemImage: "safari")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.teal.opacity(0.15), in: Capsule())
                        .foregroundStyle(.teal)
                }
                .buttonStyle(.plain)
            }
            Button {
                store.toggle(rule)
            } label: {
                Image(systemName: isActive(rule) ? "stop.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isActive(rule) ? .orange : .teal)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func isActive(_ rule: PortForwardRule) -> Bool {
        switch store.status[rule.id] ?? .stopped {
        case .connecting, .running: return true
        case .stopped, .failed: return false
        }
    }

    @ViewBuilder
    private func statusBadge(_ rule: PortForwardRule) -> some View {
        switch store.status[rule.id] ?? .stopped {
        case .running:
            Label(L("运行中"), systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        case .connecting:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .stopped:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 新增 / 编辑

struct PortForwardEditView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var l10n = LocalizationManager.shared

    let onSave: (PortForwardRule) -> Void

    @State private var rule: PortForwardRule
    @State private var localListenPortText: String
    @State private var remotePortText: String
    @State private var localServicePortText: String

    private let connections = ConnectionStore.shared.connections

    init(rule: PortForwardRule, onSave: @escaping (PortForwardRule) -> Void) {
        self.onSave = onSave
        _rule = State(initialValue: rule)
        _localListenPortText = State(initialValue: rule.localListenPort > 0 ? String(rule.localListenPort) : "")
        _remotePortText = State(initialValue: rule.remotePort > 0 ? String(rule.remotePort) : "")
        _localServicePortText = State(initialValue: rule.localServicePort > 0 ? String(rule.localServicePort) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("类型"), selection: $rule.type) {
                        ForEach(PortForwardType.allCases) { type in
                            Text(L(type.title)).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(L(rule.type.descriptionText))
                }

                Section {
                    TextField(L("规则名称"), text: $rule.name)
                    Picker(L("SSH 连接"), selection: $rule.sshConnectionID) {
                        Text(L("未选择")).tag(UUID?.none)
                        ForEach(connections) { connection in
                            Text(connection.displayName).tag(UUID?.some(connection.id))
                        }
                    }
                }

                Section {
                    switch rule.type {
                    case .local:
                        portField(L("本地监听端口"), text: $localListenPortText)
                        TextField(L("目标主机"), text: $rule.remoteHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        portField(L("目标端口"), text: $remotePortText)
                    case .remote:
                        portField(L("远程监听端口"), text: $remotePortText)
                        portField(L("本地服务端口"), text: $localServicePortText)
                    case .dynamic:
                        portField(L("本地代理端口"), text: $localListenPortText)
                    }
                } header: {
                    Text(L(rule.type.title))
                }
            }
            .navigationTitle(L("转发规则"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("保存")) { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func portField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .keyboardType(.numberPad)
    }

    private var candidate: PortForwardRule {
        var updated = rule
        updated.localListenPort = Int(localListenPortText) ?? 0
        updated.remotePort = Int(remotePortText) ?? 0
        updated.localServicePort = Int(localServicePortText) ?? 0
        return updated
    }

    private var isValid: Bool {
        candidate.isValid
    }

    private func save() {
        onSave(candidate)
        dismiss()
    }
}

#Preview {
    PortForwardListView()
}
