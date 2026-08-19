//
//  SshTerminalView.swift
//  ExGhostty_iPad
//
//  SwiftTerm TerminalView bound to a shell child channel of an SSHSession.
//  Also hides the on-screen accessory bar (esc/ctrl …) while a hardware
//  keyboard is attached (GCKeyboard), restoring it on disconnect.
//

import Foundation
import UIKit
import GameController
import SwiftTerm
import NIOCore
import NIOSSH

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private weak var terminalView: SshTerminalView?
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)

    init(
        terminalView: SshTerminalView?,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.terminalView = terminalView
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: initialWindowSize.cols,
            terminalRowHeight: initialWindowSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        for (name, value) in environment {
            let env = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
            context.triggerUserOutboundEvent(env, promise: nil)
        }

        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = payload.data else { return }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }

        let chunkSize = 1024
        var next = 0
        while next < bytes.count {
            let end = min(next + chunkSize, bytes.count)
            let chunk = bytes[next..<end]
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.feed(byteArray: chunk)
                terminalView?.observeIdentityPrompt(chunk)
            }
            next = end
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        DispatchQueue.main.async { [weak terminalView] in
            terminalView?.shellDidClose()
        }
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            DispatchQueue.main.async { [weak terminalView] in
                // 远端正常退出（如用户输入 exit）——标记后不按意外死亡自动
                // 重连，但终端里按任意键可手动重连（见 send(source:data:)）。
                terminalView?.remoteExitReceived = true
                terminalView?.feed(text: "\r\n[SSH] Session exited with status \(status.exitStatus)\r\n[SSH] \(L("按任意键重新连接…"))\r\n")
            }
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.remoteExitReceived = true
                terminalView?.feed(text: "\r\n[SSH] Session closed: \(signal.signalName)\r\n[SSH] \(L("按任意键重新连接…"))\r\n")
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        DispatchQueue.main.async { [weak terminalView] in
            // NIOSSHError 的 localizedDescription 形如 "error 1"，对用户无意义。
            let message = error is NIOSSHError ? L("连接已中断") : error.localizedDescription
            terminalView?.feed(text: "\r\n[ERROR] \(message)\r\n")
        }
        context.close(promise: nil)
    }
}

public class SshTerminalView: TerminalView, TerminalViewDelegate {
    private var shellChannel: Channel?
    private weak var session: SSHSession?
    /// Latched synchronously in start(): channel creation is async, so the
    /// shellChannel == nil check alone lets rapid repeat calls (viewDidLoad +
    /// updateUIViewController) each spawn their own shell channel.
    private var didStart = false

    /// Called on the main thread when the remote shell closes.
    var onShellClosed: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        observeHardwareKeyboard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        identityWatchItem?.cancel()
        shellChannel?.close(promise: nil)
    }

    /// Opens a shell channel on the session. Safe to call once per session.
    func start(with session: SSHSession) {
        guard !didStart else { return }
        didStart = true
        remoteExitReceived = false
        self.session = session

        let terminal = getTerminal()
        let cols = terminal.cols > 0 ? terminal.cols : 80
        let rows = terminal.rows > 0 ? terminal.rows : 24
        let term = "xterm-256color"
        let environment = ["LANG": session.config.encoding.langEnvironment]

        session.createChildChannel { [weak self] channel in
            channel.eventLoop.makeCompletedFuture {
                guard let self else { return }
                try channel.pipeline.syncOperations.addHandler(
                    SSHShellChannelHandler(
                        terminalView: self,
                        term: term,
                        environment: environment,
                        initialWindowSize: (cols: cols, rows: rows)
                    )
                )
            }
        }.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.didStart = false // allow a later retry
                DispatchQueue.main.async {
                    self.feed(text: "\r\n[ERROR] \(error.localizedDescription)\r\n")
                }
            case .success(let channel):
                self.shellChannel = channel
                DispatchQueue.main.async {
                    let terminal = self.getTerminal()
                    self.resizeRemote(cols: terminal.cols, rows: terminal.rows)
                    self.becomeFirstResponder()
                    self.scheduleIdentitySwitchIfNeeded()
                }
            }
        }
    }

    /// Sends text to the remote shell (used by feature panels to "type" commands).
    func sendText(_ text: String) {
        send(Data(text.utf8))
    }

    func send(_ data: Data) {
        guard let shellChannel, shellChannel.isActive else { return }
        shellChannel.eventLoop.execute {
            var buffer = shellChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            shellChannel.writeAndFlush(payload, promise: nil)
        }
    }

    func resizeRemote(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let shellChannel, shellChannel.isActive else { return }
        shellChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            shellChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    fileprivate func shellDidClose() {
        shellChannel = nil
        cancelIdentityWatch()
        onShellClosed?()
        // 意外死亡（锁屏/后台被系统断开、服务器掉线等）立即尝试重连；
        // 用户主动 exit（remoteExitReceived）则保持现状。
        attemptReconnect()
    }

    // MARK: Auto reconnect

    /// 收到远端 exit-status / exit-signal 时置位：此后不自动重连（start 时复位）。
    fileprivate var remoteExitReceived = false
    private var reconnectTask: Task<Void, Never>?

    /// 在 shell 死亡且非用户主动退出时重连传输层并重开 shell。
    /// iOS 锁屏/后台会挂起进程、杀死 TCP 连接，回到前台时（由
    /// TerminalHostViewController 的 didBecomeActive 观察触发）靠它恢复。
    /// shell 活着或正在重连时是幂等 no-op。
    func attemptReconnect() {
        guard shellChannel == nil, !remoteExitReceived, reconnectTask == nil, let session else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }
            if !session.isConnected {
                self.feed(text: "\r\n[SSH] \(L("连接已断开，正在重连…"))\r\n")
                do {
                    try await session.ensureConnected()
                    self.feed(text: "[SSH] \(L("已重新连接"))\r\n")
                } catch {
                    self.feed(text: "[SSH] \(L("重连失败")): \(error.localizedDescription)\r\n")
                    return
                }
            }
            if self.shellChannel == nil, !self.remoteExitReceived, session.isConnected {
                self.didStart = false
                self.start(with: session)
            }
        }
    }

    // MARK: User Identity switch

    /// sudo password waiting for a "[sudo] password ..." prompt; nil = not armed.
    private var pendingIdentityPassword: String?
    /// Rolling window of recent output scanned for the sudo password prompt.
    private var identityPromptTail = ""
    private var identityWatchItem: DispatchWorkItem?

    /// After the shell is up, `exec sudo -k su - <user>` replaces the login
    /// shell, so everything afterwards runs as the target user (and exiting
    /// ends the SSH session instead of falling back to the login shell).
    private func scheduleIdentitySwitchIfNeeded() {
        guard let session, let identity = session.config.effectiveIdentity else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.shellChannel != nil else { return }
            self.sendText(SSHIdentity.shellSwitchCommand(as: identity) + "\n")
            guard let password = identity.sudoPassword else { return }
            self.pendingIdentityPassword = password
            let item = DispatchWorkItem { [weak self] in
                self?.cancelIdentityWatch()
            }
            self.identityWatchItem = item
            // Disarm eventually so a late "password" in scrollback can't
            // trigger a spurious send.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
        }
    }

    /// Watches shell output for the sudo password prompt while an identity
    /// switch is pending, and answers it with the configured sudo password.
    /// sudo disables echo while reading, so the password never appears.
    fileprivate func observeIdentityPrompt(_ bytes: ArraySlice<UInt8>) {
        guard let password = pendingIdentityPassword else { return }
        identityPromptTail.append(String(decoding: bytes, as: UTF8.self))
        if identityPromptTail.count > 256 {
            identityPromptTail = String(identityPromptTail.suffix(256))
        }
        guard identityPromptTail.range(of: "password", options: .caseInsensitive) != nil else { return }
        let watchItem = identityWatchItem
        cancelIdentityWatch()
        watchItem?.cancel()
        sendText(password + "\n")
    }

    private func cancelIdentityWatch() {
        pendingIdentityPassword = nil
        identityPromptTail = ""
        identityWatchItem?.cancel()
        identityWatchItem = nil
    }

    // MARK: Hardware keyboard

    /// The accessory bar (esc/ctrl …) stashed while a hardware keyboard is
    /// attached — physical keyboards make it redundant, so it is hidden.
    private var stashedAccessory: UIView?

    private func observeHardwareKeyboard() {
        applyHardwareKeyboardState()
        NotificationCenter.default.addObserver(
            self, selector: #selector(hardwareKeyboardDidChange),
            name: .GCKeyboardDidConnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(hardwareKeyboardDidChange),
            name: .GCKeyboardDidDisconnect, object: nil
        )
    }

    /// 成为第一响应者时把自己登记为当前文本输入，供功能条显示输入法。
    public override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            InputModeMonitor.shared.activeResponder = self
            InputModeMonitor.shared.refresh()
        }
        return didBecome
    }

    @objc private func hardwareKeyboardDidChange() {
        DispatchQueue.main.async {
            self.applyHardwareKeyboardState()
        }
    }

    private func applyHardwareKeyboardState() {
        if GCKeyboard.coalesced != nil {
            if inputAccessoryView != nil {
                stashedAccessory = inputAccessoryView
                inputAccessoryView = nil
                reloadInputViews()
            }
        } else if inputAccessoryView == nil, let stashedAccessory {
            self.stashedAccessory = nil
            inputAccessoryView = stashedAccessory
            reloadInputViews()
        }
    }

    // MARK: TerminalViewDelegate

    public func scrolled(source: TerminalView, position: Double) {}

    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resizeRemote(cols: newCols, rows: newRows)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // shell 已退出（用户 exit 过）时，任何按键都当作重连指令，
        // 而不是把字节丢进死 channel。
        if shellChannel == nil {
            reconnectOnUserInput()
            return
        }
        send(Data(data))
    }

    /// exit 后的手动重连：清除"主动退出"标记再走标准重连流程——
    /// 传输层还活着时直接重开 shell，死了则先 ensureConnected。
    private func reconnectOnUserInput() {
        guard shellChannel == nil, remoteExitReceived, reconnectTask == nil else { return }
        remoteExitReceived = false
        attemptReconnect()
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
