//
//  SshTerminalView.swift
//  ExGhostty_iPad
//
//  SwiftTerm TerminalView bound to a shell child channel of an SSHSession.
//

import Foundation
import UIKit
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
                terminalView?.feed(text: "\n[SSH] Session exited with status \(status.exitStatus)\n")
            }
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.feed(text: "\n[SSH] Session closed: \(signal.signalName)\n")
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        DispatchQueue.main.async { [weak terminalView] in
            terminalView?.feed(text: "[ERROR] \(error.localizedDescription)\n")
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
                    self.feed(text: "[ERROR] \(error.localizedDescription)\n")
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

    // MARK: TerminalViewDelegate

    public func scrolled(source: TerminalView, position: Double) {}

    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resizeRemote(cols: newCols, rows: newRows)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        send(Data(data))
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
