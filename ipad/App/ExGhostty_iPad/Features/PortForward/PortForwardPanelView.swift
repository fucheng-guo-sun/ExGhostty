//
//  PortForwardPanelView.swift
//  iOSTerminal
//
//  Port forwarding panel inside an active SSH session: shows the rules of
//  the current connection with their runtime state, and allows manually
//  starting / stopping each rule.
//

import SwiftUI

/// 端口转发面板：展示当前连接的转发规则及运行状态，可手动启动/停止。
struct PortForwardPanelView: View {
    private let session: SSHSession
    @ObservedObject private var manager: PortForwardManager
    @StateObject private var store = PortForwardStore.shared

    init(session: SSHSession, manager: PortForwardManager) {
        self.session = session
        self._manager = ObservedObject(wrappedValue: manager)
    }

    private var rules: [PortForwardRule] {
        store.rules(for: session.config.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            descriptionCard
                .padding(.horizontal, 12)
                .padding(.top, 10)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("端口转发")
                .font(.system(size: 16, weight: .semibold))

            Text("共 \(rules.count) 条规则")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var descriptionCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.teal)
                .padding(.top, 1)
            Text("本地转发（-L）启动后可直接访问 127.0.0.1:监听端口；远程转发（-R）在服务器上监听；动态转发（-D）在本机提供 SOCKS5 代理。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if rules.isEmpty {
            emptyView
        } else {
            listView
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("暂无转发规则")
                .font(.system(size: 15, weight: .semibold))
            Text("请在连接列表中长按连接，选择「端口转发」添加规则。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func ruleRow(_ rule: PortForwardRule) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? rule.type.displayName : rule.name)
                        .font(.system(size: 14, weight: .semibold))
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
                    .lineLimit(1)
                stateView(for: rule)
            }

            Spacer()

            actionButton(for: rule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 状态与操作

    private func state(of rule: PortForwardRule) -> PortForwardManager.ForwardState {
        manager.states[rule.id] ?? .stopped
    }

    @ViewBuilder
    private func stateView(for rule: PortForwardRule) -> some View {
        switch state(of: rule) {
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("启动中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .active:
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("运行中")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .stopped:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 8, height: 8)
                Text("已停止")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for rule: PortForwardRule) -> some View {
        let currentState = state(of: rule)
        if case .starting = currentState {
            ProgressView()
                .controlSize(.small)
        } else if case .active = currentState {
            Button {
                Task { await manager.stop(rule: rule) }
            } label: {
                Text("停止")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await manager.start(rule: rule) }
            } label: {
                Text("启动")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(.black)
                    .background(Color.teal)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }
}
