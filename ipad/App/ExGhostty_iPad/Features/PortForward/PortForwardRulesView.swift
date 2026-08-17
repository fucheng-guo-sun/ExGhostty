//
//  PortForwardRulesView.swift
//  iOSTerminal
//
//  Port forwarding rules bound to a connection: list with enable toggle,
//  add / edit via PortForwardRuleEditView, and swipe-to-delete.
//

import SwiftUI

/// 端口转发规则列表：展示某个连接下的所有转发规则，可启停、增删改。
struct PortForwardRulesView: View {
    let connectionID: UUID

    @StateObject private var store = PortForwardStore.shared
    @State private var isAdding = false
    @State private var editingRule: PortForwardRule?

    private var rules: [PortForwardRule] {
        store.rules(for: connectionID)
    }

    init(connectionID: UUID) {
        self.connectionID = connectionID
    }

    var body: some View {
        Group {
            if rules.isEmpty {
                emptyState
            } else {
                ruleList
            }
        }
        .navigationTitle("端口转发")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            PortForwardRuleEditView(connectionID: connectionID)
        }
        .sheet(item: $editingRule) { rule in
            PortForwardRuleEditView(connectionID: connectionID, rule: rule)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有转发规则", systemImage: "arrow.left.arrow.right")
        } description: {
            Text("点击右上角 + 新增一条端口转发规则")
        }
    }

    private var ruleList: some View {
        List {
            ForEach(rules) { rule in
                ruleRow(rule)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingRule = rule
                    }
            }
            .onDelete { offsets in
                for index in offsets {
                    store.delete(rules[index])
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func ruleRow(_ rule: PortForwardRule) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? rule.type.displayName : rule.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(rule.type.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(rule.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: enabledBinding(for: rule))
                .labelsHidden()
                .tint(.teal)
        }
        .padding(.vertical, 4)
    }

    private func enabledBinding(for rule: PortForwardRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { newValue in
                var updated = rule
                updated.isEnabled = newValue
                store.update(updated)
            }
        )
    }
}

#Preview {
    NavigationStack {
        PortForwardRulesView(connectionID: UUID())
    }
}
