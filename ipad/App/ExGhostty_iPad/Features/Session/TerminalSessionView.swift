//
//  TerminalSessionView.swift
//  iOSTerminal
//
//  SSH session page: a top function bar switches between the terminal and
//  the feature panels (SFTP, session reuse, port usage, Docker, system
//  monitor, AI assistant). All panels share one SSHSession.
//

import SwiftUI

enum SessionFunction: String, CaseIterable, Identifiable {
    case terminal
    case sftp
    case sessionReuse
    case portUsage
    case portForward
    case docker
    case systemMonitor
    case aiAssistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "终端"
        case .sftp: return "SFTP"
        case .sessionReuse: return "Session"
        case .portUsage: return "端口"
        case .portForward: return "转发"
        case .docker: return "Docker"
        case .systemMonitor: return "监控"
        case .aiAssistant: return "AI"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .sftp: return "folder"
        case .sessionReuse: return "rectangle.split.3x1"
        case .portUsage: return "network"
        case .portForward: return "arrow.triangle.branch"
        case .docker: return "shippingbox"
        case .systemMonitor: return "gauge"
        case .aiAssistant: return "sparkles"
        }
    }
}

/// Holds the live terminal controller so panels (session reuse, AI) can
/// "type" commands into the terminal even while another panel is visible.
final class TerminalBox: ObservableObject {
    weak var controller: TerminalHostViewController?

    var terminalView: SshTerminalView? {
        controller?.hostedTerminalView
    }
}

struct TerminalSessionView: View {
    @ObservedObject var tab: TerminalTab

    private var config: SSHConnectionConfig { tab.config }
    private var session: SSHSession { tab.session }
    private var forwardManager: PortForwardManager { tab.forwardManager }
    private var terminalBox: TerminalBox { tab.terminalBox }

    @State private var selectedFunction: SessionFunction = .terminal

    var body: some View {
        VStack(spacing: 0) {
            functionBar
            Divider()
            content
        }
        .background(Color.black)
        .task {
            await tab.connectIfNeeded()
        }
    }

    // MARK: Function bar

    private var functionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SessionFunction.allCases) { function in
                    FunctionButton(
                        function: function,
                        isSelected: selectedFunction == function
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedFunction = function
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.11))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle, .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在连接 \(config.host):\(config.port)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("连接失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }

        case .connected, .closed:
            ZStack {
                // The terminal stays alive in the background so the shell
                // session is not torn down when switching panels.
                TerminalRepresentable(session: session, box: terminalBox)
                    .opacity(selectedFunction == .terminal ? 1 : 0)
                    .allowsHitTesting(selectedFunction == .terminal)

                if selectedFunction != .terminal {
                    panel(for: selectedFunction)
                        .background(Color(white: 0.07))
                }
            }
        }
    }

    @ViewBuilder
    private func panel(for function: SessionFunction) -> some View {
        switch function {
        case .terminal:
            EmptyView()
        case .sftp:
            SFTPPanelView(session: session)
        case .sessionReuse:
            SessionReusePanelView(session: session, terminalBox: terminalBox)
        case .portUsage:
            PortUsagePanelView(session: session)
        case .portForward:
            PortForwardPanelView(session: session, manager: forwardManager)
        case .docker:
            DockerPanelView(session: session)
        case .systemMonitor:
            SystemMonitorPanelView(session: session)
        case .aiAssistant:
            AIAssistantPanelView(session: session, terminalBox: terminalBox)
        }
    }
}

private struct FunctionButton: View {
    let function: SessionFunction
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: function.icon)
                    .font(.system(size: 16, weight: .medium))
                Text(function.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(width: 56, height: 44)
            .foregroundStyle(isSelected ? Color.teal : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.teal.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalRepresentable: UIViewControllerRepresentable {
    let session: SSHSession
    let box: TerminalBox

    func makeUIViewController(context: Context) -> TerminalHostViewController {
        let controller = TerminalHostViewController()
        controller.configure(session: session)
        box.controller = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: TerminalHostViewController, context: Context) {
        uiViewController.configure(session: session)
    }
}
