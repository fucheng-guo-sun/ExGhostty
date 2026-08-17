//
//  DockerPanelView.swift
//  ExGhostty_iPad
//
//  Docker 管理面板：检测远程主机的 docker 可用性，按容器/镜像/卷/网络
//  四个分类展示资源，并支持容器启停/重启/删除、查看日志、删除镜像。
//

import SwiftUI
import UIKit

/// 面板整体状态。
private enum DockerPanelState {
    case checking
    case notInstalled
    case daemonDown
    case permissionDenied
    case ready
}

/// 面板内的列表分类。
private enum DockerTab: String, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "容器"
        case .images:     return "镜像"
        case .volumes:    return "卷"
        case .networks:   return "网络"
        }
    }
}

/// Docker 管理功能面板。
struct DockerPanelView: View {
    @StateObject private var viewModel: DockerViewModel
    @State private var state: DockerPanelState = .checking
    @State private var tab: DockerTab = .containers
    @State private var containerPendingRemoval: DockerContainer?
    @State private var imagePendingRemoval: DockerImage?
    @State private var logsContainer: DockerContainer?

    init(session: SSHSession) {
        _viewModel = StateObject(wrappedValue: DockerViewModel(session: session))
    }

    var body: some View {
        Group {
            switch state {
            case .checking:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在检测 Docker 环境…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .notInstalled:
                notInstalledView
            case .daemonDown:
                daemonDownView
            case .permissionDenied:
                permissionDeniedView
            case .ready:
                contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startService()
        }
        .onChange(of: tab) { _, newTab in
            guard state == .ready else { return }
            Task {
                await refreshTab(newTab)
            }
        }
        .sheet(item: $logsContainer) { container in
            DockerLogsView(session: viewModel.session, container: container)
        }
        .alert(
            "删除容器",
            isPresented: removalBinding(for: $containerPendingRemoval),
            presenting: containerPendingRemoval
        ) { container in
            Button("删除", role: .destructive) {
                Task {
                    await viewModel.performContainerAction(.remove, id: container.id)
                    await viewModel.refreshContainers()
                }
            }
            Button("取消", role: .cancel) {}
        } message: { container in
            Text("确定要删除容器 \"\(container.names)\" 吗？此操作不可恢复。")
        }
        .alert(
            "删除镜像",
            isPresented: removalBinding(for: $imagePendingRemoval),
            presenting: imagePendingRemoval
        ) { image in
            Button("删除", role: .destructive) {
                Task {
                    await viewModel.removeImage(reference: image.reference)
                    await viewModel.refreshImages()
                }
            }
            Button("取消", role: .cancel) {}
        } message: { image in
            Text("确定要删除镜像 \"\(image.repository):\(image.tag)\" 吗？")
        }
    }

    /// 把 Optional item 的 @State 转成 alert 需要的 Bool 绑定。
    private func removalBinding<Item>(for item: Binding<Item?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }

    // MARK: - 启动

    private func startService() {
        guard state == .checking else { return }
        Task {
            let access = await viewModel.checkDockerAccess()
            switch access {
            case .ok:
                state = .ready
                await viewModel.refreshAll()
            case .cliMissing:
                state = .notInstalled
            case .permissionDenied:
                state = .permissionDenied
            case .daemonDown:
                state = .daemonDown
            }
        }
    }

    // MARK: - 未安装提示

    private var notInstalledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("未安装 Docker")
                .font(.system(size: 14, weight: .medium))
            Text("Docker 管理需要远程主机已安装 docker CLI")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新检测") {
                state = .checking
                startService()
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - daemon 未运行提示

    private var daemonDownView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Docker 服务未运行")
                .font(.system(size: 14, weight: .medium))
            Text("无法连接 Docker daemon，请先在远程主机上启动服务：")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("sudo systemctl start docker")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(white: 0.13))
                .cornerRadius(6)
            Button("重试") {
                state = .checking
                startService()
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 权限不足引导

    /// 无权限访问 Docker daemon 时，引导用户把账号加入 docker 用户组（而非使用 sudo）。
    private var permissionDeniedView: some View {
        let username = viewModel.session.config.username
        let command = "sudo usermod -aG docker \(username)"
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Docker 权限不足")
                .font(.system(size: 14, weight: .medium))
            Text("当前用户无法访问 Docker daemon。建议把用户加入 docker 用户组（优于使用 sudo）：")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(white: 0.13))
                .cornerRadius(6)
            Text("执行后需重新登录（或重新连接）才能生效。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("复制") {
                    UIPasteboard.general.string = command
                }
                Button("重试") {
                    state = .checking
                    startService()
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 内容

    private var contentView: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if viewModel.issue != nil, currentListIsEmpty {
                issueView
            } else {
                listView
                // 操作类失败保留原始错误信息；加载类失败显示分类提示。
                if let actionError = viewModel.actionError {
                    Divider()
                    errorBanner(actionError, dismiss: { viewModel.dismissActionError() })
                } else if let issue = viewModel.issue {
                    Divider()
                    errorBanner(issueMessage(issue), dismiss: { viewModel.dismissIssue() })
                }
            }
        }
    }

    private var currentListIsEmpty: Bool {
        switch tab {
        case .containers: return viewModel.containers.isEmpty
        case .images:     return viewModel.images.isEmpty
        case .volumes:    return viewModel.volumes.isEmpty
        case .networks:   return viewModel.networks.isEmpty
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(DockerTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button(action: refreshCurrentTab) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.teal)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func refreshCurrentTab() {
        Task {
            await refreshTab(tab)
        }
    }

    private func refreshTab(_ tab: DockerTab) async {
        switch tab {
        case .containers: await viewModel.refreshContainers()
        case .images:     await viewModel.refreshImages()
        case .volumes:    await viewModel.refreshVolumes()
        case .networks:   await viewModel.refreshNetworks()
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listView: some View {
        if viewModel.isLoading, currentListIsEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("正在加载…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if currentListIsEmpty {
            VStack {
                Spacer()
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List {
                switch tab {
                case .containers:
                    ForEach(viewModel.containers) { container in
                        containerRow(container)
                    }
                case .images:
                    ForEach(viewModel.images) { image in
                        imageRow(image)
                    }
                case .volumes:
                    ForEach(viewModel.volumes) { volume in
                        volumeRow(volume)
                    }
                case .networks:
                    ForEach(viewModel.networks) { network in
                        networkRow(network)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await refreshTab(tab)
            }
        }
    }

    private var emptyText: String {
        switch tab {
        case .containers: return "没有容器"
        case .images:     return "没有镜像"
        case .volumes:    return "没有卷"
        case .networks:   return "没有网络"
        }
    }

    // MARK: - 问题展示

    /// 加载类问题的分类文案。
    private func issueMessage(_ issue: DockerIssue) -> String {
        switch issue.kind {
        case .daemonDown:       return "Docker 服务未运行，请启动后刷新"
        case .permissionDenied: return "当前用户无权访问 Docker daemon"
        case .containerRunning: return "容器仍在运行，请先停止"
        case .imageInUse:       return "镜像仍被容器引用，无法删除"
        case .commandFailed:    return "请安装或启动 Docker 服务"
        }
    }

    /// 列表为空时的整页问题视图（可重试）。
    private var issueView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if let issue = viewModel.issue {
                Text(issueMessage(issue))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("重试") {
                refreshCurrentTab()
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// 列表非空时的底部提示条（可关闭）。
    private func errorBanner(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 容器列表

    private func containerRow(_ container: DockerContainer) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(container.names)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(container.image)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !container.status.isEmpty {
                    Text(container.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !container.ports.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(container.ports, id: \.self) { port in
                            Text(port)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if container.isRunning {
                    actionButton(icon: "stop.fill") {
                        performContainerAction(.stop, container: container)
                    }
                    actionButton(icon: "arrow.counterclockwise") {
                        performContainerAction(.restart, container: container)
                    }
                } else {
                    actionButton(icon: "play.fill") {
                        performContainerAction(.start, container: container)
                    }
                }
                actionButton(icon: "doc.text.magnifyingglass") {
                    logsContainer = container
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu {
            Button {
                logsContainer = container
            } label: {
                Label("查看日志", systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            Button(role: .destructive) {
                containerPendingRemoval = container
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func performContainerAction(_ action: DockerViewModel.ContainerAction, container: DockerContainer) {
        Task {
            await viewModel.performContainerAction(action, id: container.id)
            await viewModel.refreshContainers()
        }
    }

    // MARK: - 镜像列表

    private func imageRow(_ image: DockerImage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(image.repository):\(image.tag)")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(image.imageID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(image.size)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu {
            Button(role: .destructive) {
                imagePendingRemoval = image
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 卷列表

    private func volumeRow(_ volume: DockerVolume) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(volume.driver)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(volume.scope)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - 网络列表

    private func networkRow(_ network: DockerNetwork) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(network.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(network.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(network.driver)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(network.scope)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - 行内操作按钮

    private func actionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.teal)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 容器日志

/// 容器日志 sheet：流式滚动显示 `docker logs --tail 200 -f` 的输出。
private struct DockerLogsView: View {
    let session: SSHSession
    let container: DockerContainer

    @StateObject private var model = DockerLogsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text.isEmpty ? "等待日志输出…" : model.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .onChange(of: model.text) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(white: 0.07))
            .navigationTitle("日志 - \(container.names)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            model.start(session: session, containerID: container.id)
        }
        .onDisappear {
            model.stop()
        }
    }
}
