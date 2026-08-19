//
//  SystemMonitorPanelView.swift
//  ExGhostty_iPad
//
//  System monitor panel: card-style dashboard fed by xtop JSON streams
//  (see SystemMonitorViewModel/XTopModels), aligned with the Mac version:
//  CPU, three-segment memory (used/cached/free), per-mount disk usage with
//  read/write speeds, network throughput, GPU cards and top processes.
//

import SwiftUI

struct SystemMonitorPanelView: View {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var viewModel: SystemMonitorViewModel

    init(session: SSHSession) {
        _viewModel = StateObject(wrappedValue: SystemMonitorViewModel(session: session))
    }

    var body: some View {
        Group {
            if viewModel.isUnsupported {
                unsupportedView
            } else if let errorMessage = viewModel.errorMessage, viewModel.latest == nil {
                errorView(errorMessage)
            } else if viewModel.isLoading, viewModel.latest == nil {
                loadingView
            } else if let latest = viewModel.latest {
                dashboard(latest)
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - 状态视图

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L("正在采集系统数据…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(L("未检测到 xtop"))
                .font(.headline)
            Text(L("系统监控需要在远端主机安装 xtop。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link(L("打开 xtop 项目主页"), destination: URL(string: "https://github.com/rarnu/xtop")!)
                .font(.subheadline)
                .tint(.teal)
            Button(L("重试")) { viewModel.retry() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(L("采集失败"))
                .font(.headline)
            Text(L(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("重试")) { viewModel.retry() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .padding()
    }

    // MARK: - 仪表盘

    private func dashboard(_ output: XTopOutput) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                cpuCard(output)
                memoryCard(output)
                if let mounts = output.disk?.Mounts, !mounts.isEmpty {
                    diskCard(mounts)
                }
                if let net = output.net {
                    networkCard(net)
                }
                gpuCard(output)
                if let proc = output.proc {
                    processCard(proc)
                }
            }
            .padding(12)
        }
    }

    // MARK: - CPU

    private func cpuCard(_ output: XTopOutput) -> some View {
        MonitorCard(title: "CPU", systemImage: "cpu") {
            if let cpu = output.cpu {
                HStack(alignment: .center, spacing: 16) {
                    ProgressRing(value: cpu.Overall / 100.0,
                                 color: Self.usageColor(cpu.Overall)) {
                        Text(cpu.Overall.formattedPercent())
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 84, height: 84)

                    if !cpu.PerCore.isEmpty {
                        // 一行 8 个核。
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                                  alignment: .leading,
                                  spacing: 4) {
                            ForEach(Array(cpu.PerCore.enumerated()), id: \.offset) { index, usage in
                                HStack(spacing: 6) {
                                    Text("\(index)")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 18, alignment: .trailing)
                                    UsageBar(value: usage / 100.0, color: Self.usageColor(usage), height: 5)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - 内存

    private func memoryCard(_ output: XTopOutput) -> some View {
        MonitorCard(title: L("内存"), systemImage: "memorychip") {
            if let mem = output.mem {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Text("\(mem.Used.formattedBytes()) / \(mem.Total.formattedBytes())")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    // 三段式：已用 / 已缓存 / 空余（对齐 Mac 版）。
                    GeometryReader { geometry in
                        let total = mem.Total > 0 ? Double(mem.Total) : 1
                        let usedWidth = geometry.size.width * CGFloat(Double(mem.Used) / total)
                        let cachedWidth = geometry.size.width * CGFloat(Double(mem.Cached) / total)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(white: 0.25))
                            Capsule()
                                .fill(Color.orange)
                                .frame(width: usedWidth)
                            Capsule()
                                .fill(Color.green)
                                .frame(width: cachedWidth)
                                .offset(x: usedWidth)
                        }
                    }
                    .frame(height: 10)

                    HStack(spacing: 16) {
                        MemoryLegendItem(color: .orange, label: L("已用"), value: mem.Used.formattedBytes())
                        MemoryLegendItem(color: .green, label: L("缓存"), value: mem.Cached.formattedBytes())
                        MemoryLegendItem(color: Color(white: 0.35), label: L("空闲"), value: mem.Free.formattedBytes())
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - 磁盘

    private func diskCard(_ mounts: [XTopDiskMount]) -> some View {
        MonitorCard(title: L("磁盘"), systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(mounts) { mount in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(mount.Mountpoint)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(mount.Used.formattedBytes()) / \(mount.Total.formattedBytes()) (\(mount.UsedPercent.formattedPercent()))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        UsageBar(value: mount.UsedPercent / 100.0,
                                 color: Self.usageColor(mount.UsedPercent))
                        HStack(spacing: 12) {
                            Label(mount.ReadPerSec.formattedBytesPerSecond(), systemImage: "arrow.down.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Label(mount.WritePerSec.formattedBytesPerSecond(), systemImage: "arrow.up.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 网络

    private func networkCard(_ net: XTopNet) -> some View {
        MonitorCard(title: L("网络"), systemImage: "network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 24) {
                    Label {
                        Text(net.UploadPerSec.formattedBytesPerSecond())
                            .font(.subheadline)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.up")
                            .foregroundStyle(.teal)
                    }
                    Label {
                        Text(net.DownloadPerSec.formattedBytesPerSecond())
                            .font(.subheadline)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.down")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }

                if let topProcs = net.TopProcs, !topProcs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(topProcs.prefix(5)) { proc in
                            HStack {
                                Text(proc.Command)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                Spacer()
                                Text("↑ \(proc.UploadPerSec.formattedBytesPerSecond())  ↓ \(proc.DownloadPerSec.formattedBytesPerSecond())")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - GPU

    private func gpuCard(_ output: XTopOutput) -> some View {
        MonitorCard(title: "GPU", systemImage: "rectangle.fill.on.rectangle.fill") {
            if let gpu = output.gpu {
                if gpu.Available, let cards = gpu.Cards, !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(cards.count > 1 ? "[#\(index + 1)] \(card.Name)" : card.Name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(L("GPU 负载"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(card.LoadPct.formattedPercent())
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    UsageBar(value: card.LoadPct / 100.0, color: .purple)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(L("显存"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(gpuMemText(for: card))
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    if card.MemTotal > 0 {
                                        UsageBar(
                                            value: Double(card.MemUsed) / Double(card.MemTotal),
                                            color: .blue
                                        )
                                    }
                                }

                                HStack(spacing: 12) {
                                    Text(card.TempC.formattedCelsius())
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(card.PowerW.formattedWatts())
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        }
                    }
                } else {
                    Text(L(gpu.Message ?? "GPU 不可用"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    private func gpuMemText(for card: XTopGPUCard) -> String {
        guard card.MemTotal > 0 else {
            return card.MemUsed > 0 ? card.MemUsed.formattedBytes() : "N/A"
        }
        let percent = Double(card.MemUsed) / Double(card.MemTotal) * 100
        return "\(card.MemUsed.formattedBytes()) / \(card.MemTotal.formattedBytes()) (\(String(format: "%.1f", percent))%)"
    }

    // MARK: - 进程

    private func processCard(_ proc: XTopProc) -> some View {
        MonitorCard(title: L("进程（共 %d 个）", proc.Total), systemImage: "list.number") {
            VStack(alignment: .leading, spacing: 10) {
                if let topCPU = proc.TopCPU, !topCPU.isEmpty {
                    ProcessSection(title: "Top CPU", procs: topCPU) { $0.CPU.formattedPercent() }
                }
                if let topMem = proc.TopMem, !topMem.isEmpty {
                    ProcessSection(title: L("Top 内存"), procs: topMem) { $0.MemRSS.formattedBytes() }
                }
                if let topDisk = proc.TopDisk, !topDisk.isEmpty {
                    ProcessSection(title: L("Top 磁盘"), procs: topDisk) { $0.CPU.formattedPercent() }
                }
            }
        }
    }

    // MARK: - 格式化

    static func usageColor(_ percent: Double) -> Color {
        if percent < 50 { return .teal }
        if percent < 80 { return .yellow }
        return .red
    }
}

// MARK: - 通用组件

/// 卡片容器：标题 + 图标 + 内容。
private struct MonitorCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 简易进度条。
private struct UsageBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.25))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// 进度环。
private struct ProgressRing<Content: View>: View {
    let value: Double
    let color: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 0.25), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: value)
            content()
        }
    }
}

/// 数据尚未到达时的占位提示。
private struct EmptyDataHint: View {
    @StateObject private var l10n = LocalizationManager.shared

    var body: some View {
        Text(L("等待数据…"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }
}

/// 内存图例项：色点 + 名称 + 数值。
private struct MemoryLegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .monospacedDigit()
        }
    }
}

/// 进程分组（Top CPU / Top 内存 / Top 磁盘）。
private struct ProcessSection: View {
    let title: String
    let procs: [XTopProcInfo]
    let valueFormatter: (XTopProcInfo) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(procs.prefix(5)) { proc in
                HStack(spacing: 8) {
                    Text(verbatim: "\(proc.PID)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 48, alignment: .trailing)
                    Text(proc.Command)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Text(valueFormatter(proc))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
