//
//  SystemMonitorPanelView.swift
//  ExGhostty_iPad
//
//  System monitor panel: card-style dashboard showing CPU, memory,
//  disks, network throughput and top CPU processes of the remote host.
//

import SwiftUI

struct SystemMonitorPanelView: View {
    @StateObject private var viewModel: SystemMonitorViewModel

    init(session: SSHSession) {
        _viewModel = StateObject(wrappedValue: SystemMonitorViewModel(session: session))
    }

    var body: some View {
        Group {
            if viewModel.isUnsupported {
                unsupportedView
            } else if let errorMessage = viewModel.errorMessage, viewModel.sample == nil {
                errorView(errorMessage)
            } else if viewModel.isLoading, viewModel.sample == nil {
                loadingView
            } else if let sample = viewModel.sample {
                dashboard(sample)
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
            Text("正在采集系统数据…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("不支持的主机")
                .font(.headline)
            Text("系统监控依赖 Linux 的 /proc 文件系统，\n当前主机无法提供监控数据。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { viewModel.retry() }
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
            Text("采集失败")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { viewModel.retry() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .padding()
    }

    // MARK: - 仪表盘

    private func dashboard(_ sample: SystemMonitorSample) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                cpuCard(sample)
                memoryCard(sample)
                if !sample.disks.isEmpty {
                    diskCard(sample)
                }
                networkCard(sample)
                if !sample.topProcesses.isEmpty {
                    processCard(sample)
                }
            }
            .padding(12)
        }
    }

    // MARK: - CPU

    private func cpuCard(_ sample: SystemMonitorSample) -> some View {
        MonitorCard(title: "CPU", systemImage: "cpu") {
            HStack(alignment: .center, spacing: 16) {
                ProgressRing(value: sample.cpuOverall / 100.0,
                             color: Self.usageColor(sample.cpuOverall)) {
                    Text(Self.percentText(sample.cpuOverall))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(width: 84, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    Text("负载 \(Self.loadText(sample.load1)) / \(Self.loadText(sample.load5)) / \(Self.loadText(sample.load15))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if !sample.cpuPerCore.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                  alignment: .leading,
                                  spacing: 4) {
                            ForEach(Array(sample.cpuPerCore.enumerated()), id: \.offset) { index, usage in
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 内存

    private func memoryCard(_ sample: SystemMonitorSample) -> some View {
        MonitorCard(title: "内存", systemImage: "memorychip") {
            VStack(alignment: .leading, spacing: 10) {
                let memPercent = sample.memTotal > 0
                    ? Double(sample.memUsed) * 100.0 / Double(sample.memTotal)
                    : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("内存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(sample.memUsed.formattedBytes()) / \(sample.memTotal.formattedBytes())")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(value: memPercent / 100.0, color: Self.usageColor(memPercent))
                }

                if sample.swapTotal > 0 {
                    let swapPercent = Double(sample.swapUsed) * 100.0 / Double(sample.swapTotal)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Swap")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(sample.swapUsed.formattedBytes()) / \(sample.swapTotal.formattedBytes())")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        UsageBar(value: swapPercent / 100.0, color: Self.usageColor(swapPercent))
                    }
                }
            }
        }
    }

    // MARK: - 磁盘

    private func diskCard(_ sample: SystemMonitorSample) -> some View {
        MonitorCard(title: "磁盘", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sample.disks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(disk.mountPoint)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(disk.used.formattedBytes()) / \(disk.total.formattedBytes()) (\(Self.percentText(disk.usedPercent)))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        UsageBar(value: disk.usedPercent / 100.0,
                                 color: Self.usageColor(disk.usedPercent))
                    }
                }
            }
        }
    }

    // MARK: - 网络

    private func networkCard(_ sample: SystemMonitorSample) -> some View {
        MonitorCard(title: "网络", systemImage: "network") {
            HStack(spacing: 24) {
                Label {
                    Text(sample.netTxPerSec.formattedBytesPerSecond())
                        .font(.subheadline)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.up")
                        .foregroundStyle(.teal)
                }
                Label {
                    Text(sample.netRxPerSec.formattedBytesPerSecond())
                        .font(.subheadline)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
    }

    // MARK: - 进程

    private func processCard(_ sample: SystemMonitorSample) -> some View {
        MonitorCard(title: "Top 进程（CPU）", systemImage: "list.number") {
            VStack(spacing: 6) {
                ForEach(sample.topProcesses) { process in
                    HStack(spacing: 8) {
                        Text("\(process.pid)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 56, alignment: .trailing)
                        Text(process.command)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(Self.percentText(process.cpuPercent))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Self.usageColor(process.cpuPercent))
                            .frame(width: 56, alignment: .trailing)
                        Text(Self.percentText(process.memPercent))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
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

    private static func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private static func loadText(_ value: Double) -> String {
        String(format: "%.2f", value)
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
