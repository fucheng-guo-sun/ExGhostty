//
//  TestConnectionView.swift
//  ExGhostty_iPad
//
//  「测试连接」sheet（对标 Mac 版 SSHTestDetailView）：上方分步列表
//  （SF Symbol 状态图标），下方等宽字体滚动日志，底部终态提示。运行中
//  右上角为「取消」（断开测试会话），结束后变为「关闭」。日志条目是
//  key + 参数，这里用 L() 翻译后格式化渲染。
//

import SwiftUI

struct TestConnectionView: View {
    @StateObject private var l10n = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: TestConnectionViewModel

    init(input: TestConnectionInput) {
        _viewModel = StateObject(wrappedValue: TestConnectionViewModel(input: input))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepList
                Divider()
                logArea
                Divider()
                footer
            }
            .background(Color.black)
            .navigationTitle(L("测试连接"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isRunning {
                        Button(L("取消")) { viewModel.cancel() }
                    } else {
                        Button(L("关闭")) { dismiss() }
                    }
                }
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - 步骤列表

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.steps) { step in
                HStack(spacing: 10) {
                    statusIcon(step.status)
                        .frame(width: 18, height: 18)
                    Text(L(step.titleKey))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(statusColor(step.status))
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(_ status: TestConnectionViewModel.StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func statusColor(_ status: TestConnectionViewModel.StepStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .primary
        case .success: return .green
        case .failure: return .red
        }
    }

    // MARK: - 日志区

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.logs) { line in
                        Text(render(line))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(white: 0.75))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .background(Color(white: 0.08))
            .onChange(of: viewModel.logs.count) {
                if let last = viewModel.logs.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部状态

    private var footer: some View {
        HStack(spacing: 8) {
            if let result = viewModel.finalResult {
                let succeeded = result == .success
                Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(succeeded ? .green : .red)
                Text(renderFinalMessage())
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(succeeded ? .green : .red)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text(L("测试中，请稍候…"))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - 渲染

    /// 日志条目：先翻译 key（中文原文），再代入参数。
    private func render(_ line: TestLogLine) -> String {
        Self.format(L(line.key), args: line.args)
    }

    private func renderFinalMessage() -> String {
        Self.format(L(viewModel.finalMessageKey), args: viewModel.finalMessageArgs)
    }

    private static func format(_ pattern: String, args: [String]) -> String {
        guard !args.isEmpty else { return pattern }
        return String(format: pattern, arguments: args)
    }
}
