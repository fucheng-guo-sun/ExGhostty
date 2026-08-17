//
//  PortUsagePanelView.swift
//  iOSTerminal
//
//  Port usage panel: lists listening ports on the remote host,
//  with search filtering, UDP toggle and process kill support.
//

import SwiftUI

/// 端口使用面板：展示远程主机的监听端口，支持搜索过滤与结束进程。
struct PortUsagePanelView: View {
    @StateObject private var viewModel: PortUsageViewModel
    @State private var searchText = ""
    @State private var killTarget: PortUsageEntry?
    @State private var showKillConfirm = false
    @State private var killFailedMessage: String?

    init(session: SSHSession) {
        _viewModel = StateObject(wrappedValue: PortUsageViewModel(session: session))
    }

    private var filteredEntries: [PortUsageEntry] {
        if searchText.isEmpty { return viewModel.entries }
        return viewModel.entries.filter {
            String($0.port).contains(searchText) ||
            $0.processName.localizedCaseInsensitiveContains(searchText) ||
            $0.address.localizedCaseInsensitiveContains(searchText) ||
            $0.commandLine.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
        .alert("结束进程", isPresented: $showKillConfirm, presenting: killTarget) { entry in
            Button("结束", role: .destructive) {
                Task { await kill(entry) }
            }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text("确定要强制结束「\(entry.processName)」(PID \(entry.pid)) 吗？该操作不可撤销。")
        }
        .alert("无法结束进程", isPresented: killFailedBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(killFailedMessage ?? "")
        }
    }

    private var killFailedBinding: Binding<Bool> {
        Binding(
            get: { killFailedMessage != nil },
            set: { if !$0 { killFailedMessage = nil } }
        )
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("端口使用")
                .font(.system(size: 16, weight: .semibold))

            Text("共 \(viewModel.entries.count) 个监听端口")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            searchField

            udpToggle

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.teal)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("按端口 / 进程搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var udpToggle: some View {
        Button {
            viewModel.includeUDP.toggle()
        } label: {
            Text("UDP")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(viewModel.includeUDP ? Color.black : Color.secondary)
                .background(viewModel.includeUDP ? Color.teal : Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if !viewModel.hasLoaded && viewModel.loadError == nil {
            loadingView
        } else if let error = viewModel.loadError, !viewModel.hasLoaded {
            errorView(error)
        } else if filteredEntries.isEmpty {
            emptyView
        } else {
            listView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("正在扫描监听端口…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("扫描失败")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("重试")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.teal)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            if viewModel.isScanning {
                ProgressView()
            } else {
                Text(searchText.isEmpty ? "未发现监听端口" : "没有匹配的端口")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredEntries) { entry in
                    entryRow(entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func entryRow(_ entry: PortUsageEntry) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: ":\(entry.port)")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.teal)
                .frame(minWidth: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .font(.system(size: 14, weight: .medium))
                    if entry.pid > 0 {
                        Text(verbatim: "PID \(entry.pid)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: entry.address)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !entry.commandLine.isEmpty {
                    Text(entry.commandLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            if entry.pid > 0 {
                Button {
                    killTarget = entry
                    showKillConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 结束进程

    private func kill(_ entry: PortUsageEntry) async {
        let ok = await viewModel.kill(pid: entry.pid)
        if !ok {
            killFailedMessage = "结束 \(entry.processName) (PID \(entry.pid)) 失败，可能没有权限或进程已退出。"
        }
    }
}
