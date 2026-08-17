//
//  ConnectionListView.swift
//  iOSTerminal
//
//  Left sidebar of the split view: saved SSH connections grouped by `group`
//  (ungrouped last), with add / edit / delete, port forwarding entry, and a
//  bottom bar with a Settings button. Tapping a row opens the connection in
//  a terminal tab on the right side.
//

import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject private var tabStore: TerminalTabStore
    @StateObject private var store = ConnectionStore.shared
    @Binding var isCollapsed: Bool
    @State private var editingConnection: SSHConnectionConfig?
    @State private var isAdding = false
    @State private var showSettings = false
    @State private var portForwardConnection: SSHConnectionConfig?
    @State private var connectionToDelete: SSHConnectionConfig?

    /// Non-empty groups sorted by name, then the ungrouped bucket ("未分组") last.
    private var groupedConnections: [(name: String, items: [SSHConnectionConfig])] {
        var buckets: [String: [SSHConnectionConfig]] = [:]
        var ungrouped: [SSHConnectionConfig] = []
        for config in store.connections {
            let key = config.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                ungrouped.append(config)
            } else {
                buckets[key, default: []].append(config)
            }
        }
        var result = buckets.keys
            .sorted { $0.localizedCompare($1) == .orderedAscending }
            .map { (name: $0, items: buckets[$0] ?? []) }
        if !ungrouped.isEmpty {
            result.append((name: "未分组", items: ungrouped))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                collapsedStrip
            } else {
                header
                Divider()
                Group {
                    if store.connections.isEmpty {
                        emptyState
                    } else {
                        connectionList
                    }
                }
                Divider()
                bottomBar
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.11))
        .sheet(isPresented: $isAdding) {
            ConnectionEditView(connection: nil)
        }
        .sheet(item: $editingConnection) { config in
            ConnectionEditView(connection: config)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $portForwardConnection) { config in
            NavigationStack {
                PortForwardRulesView(connectionID: config.id)
            }
        }
        .alert("删除连接", isPresented: deleteAlertBinding, presenting: connectionToDelete) { config in
            Button("删除", role: .destructive) {
                tabStore.closeTabs(for: config.id)
                store.delete(config)
            }
            Button("取消", role: .cancel) {}
        } message: { config in
            Text("确定要删除「\(config.displayName)」吗？")
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { connectionToDelete != nil },
            set: { if !$0 { connectionToDelete = nil } }
        )
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = true }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("SSH 连接")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                isAdding = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Collapsed icon strip (mirrors ExGhostty): expand, add, settings.
    private var collapsedStrip: some View {
        VStack(spacing: 20) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 15, weight: .medium))
            }
            Button {
                isAdding = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("没有 SSH 连接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("点击右上角 + 新增")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionList: some View {
        List {
            ForEach(groupedConnections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.items) { config in
                        connectionRow(for: config)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func connectionRow(for config: SSHConnectionConfig) -> some View {
        Button {
            tabStore.open(config)
        } label: {
            ConnectionRow(config: config)
        }
        .listRowBackground(Color(white: 0.15))
        .contextMenu {
            Button {
                portForwardConnection = config
            } label: {
                Label("端口转发", systemImage: "arrow.left.arrow.right")
            }
            Button {
                editingConnection = config
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                connectionToDelete = config
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                connectionToDelete = config
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editingConnection = config
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button {
                showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 15, weight: .medium))
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
    }
}

private struct ConnectionRow: View {
    let config: SSHConnectionConfig

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 20))
                .foregroundStyle(.teal)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(config.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(config.username)@\(config.host):\(config.port)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    ConnectionListView(isCollapsed: .constant(false))
        .environmentObject(TerminalTabStore())
        .preferredColorScheme(.dark)
}
