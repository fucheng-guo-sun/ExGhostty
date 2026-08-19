//
//  PortForwardRuntime.swift
//  ExGhostty_iPad
//
//  NIO engine for one running port-forward rule. Local (-L) and dynamic
//  (-D) run a ServerBootstrap listener; each accepted connection opens a
//  directTCPIP child channel on the rule's dedicated SSHSession and the
//  two channels are glued. Remote (-R) issues a tcpip-forward global
//  request and glues each inbound forwardedTCPIP channel to the local
//  service. The glue does backpressure: autoRead is off on both sides,
//  and each side only issues the next read() when its write to the peer
//  completes (at most one chunk in flight per direction). Reconnect
//  semantics mirror the Mac version: fixed 3s delay, give up after 5
//  consecutive failures, manual stop never reconnects.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Combine

// MARK: - 双向粘接（含关闭传播与背压）

/// 背压模型：两侧 channel 都关 autoRead，handler 持有自己的 context；
/// 每收到一份数据写给对端，**写完（write 完成）才向本侧要下一份**
/// （context.read()），任意时刻每个方向最多一份在途数据。attach 时
/// 发出首次 read 启动流水线。

/// SSH 侧：读 SSHChannelData 写给对端 TCP。
private final class SSHSideRelayHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var peer: Channel?
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        peer = nil
    }

    func attach(peer: Channel) {
        self.peer = peer
        context?.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = payload.data, buffer.readableBytes > 0 else {
            context.read()
            return
        }
        peer?.writeAndFlush(buffer).whenComplete { [weak self] _ in
            // 写完成回调运行在对端（写入方）的 EL 上，read 必须跳回本侧 EL。
            guard let self, let context = self.context else { return }
            context.eventLoop.execute {
                context.read()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.close(promise: nil)
        context.close(promise: nil)
    }
}

/// TCP 侧：读 ByteBuffer 包成 SSHChannelData 写给对端 SSH 子 channel。
private final class TCPSideRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var peer: Channel?
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        peer = nil
    }

    func attach(peer: Channel) {
        self.peer = peer
        context?.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        peer?.writeAndFlush(payload).whenComplete { [weak self] _ in
            // 写完成回调运行在对端（写入方）的 EL 上，read 必须跳回本侧 EL。
            guard let self, let context = self.context else { return }
            context.eventLoop.execute {
                context.read()
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.close(promise: nil)
        context.close(promise: nil)
    }
}

// MARK: - -L 本地转发

/// 每条入站连接：建 directTCPIP 子 channel 后与本地连接粘接。
private final class LocalForwardAcceptHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let session: SSHSession
    private let targetHost: String
    private let targetPort: Int
    private let tcpRelay = TCPSideRelayHandler()

    init(session: SSHSession, targetHost: String, targetPort: Int) {
        self.session = session
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.pipeline.addHandler(tcpRelay)
    }

    func channelActive(context: ChannelHandlerContext) {
        // context.channel 只能在本 channel 的 eventLoop 上访问（NIO 线程断言，
        // ChannelPipeline.swift:158），异步回调里用的是 transport 的 EL，
        // 必须先把 channel 引用取出来。
        let localChannel = context.channel
        session.createDirectTCPIPChannel(targetHost: targetHost, targetPort: targetPort) { child in
            child.setOption(ChannelOptions.autoRead, value: false)
        }.whenComplete { [tcpRelay] result in
            switch result {
            case .failure:
                localChannel.close(promise: nil)
            case .success(let sshChannel):
                let sshRelay = SSHSideRelayHandler()
                sshChannel.pipeline.addHandler(sshRelay).whenComplete { _ in
                    // 此处运行在 sshChannel（transport）EL 上。
                    sshRelay.attach(peer: localChannel)
                    // tcpRelay 属于本地连接，状态读写跳回它自己的 EL。
                    localChannel.eventLoop.execute {
                        tcpRelay.attach(peer: sshChannel)
                    }
                }
            }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // 数据由 tcpRelay 处理（它在 pipeline 的更深处）。
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }
}

// MARK: - -D 动态转发（SOCKS5）

/// 最小 SOCKS5 server：无认证、仅 CONNECT。握手完成后同样走 directTCPIP。
private final class Socks5Handler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private enum State {
        case greeting
        case request
        case established
    }

    private let session: SSHSession
    private var state: State = .greeting
    private var buffer = ByteBuffer()
    private let tcpRelay = TCPSideRelayHandler()

    init(session: SSHSession) {
        self.session = session
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.pipeline.addHandler(tcpRelay)
        // 背压：autoRead=false，握手阶段由本 handler 自己驱动 read。
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // 握手完成后数据直通 tcpRelay（它在 pipeline 更深处），
        // 之后的读取节奏由 tcpRelay 的写完成回调驱动（背压）。
        if state == .established {
            context.fireChannelRead(data)
            return
        }
        defer {
            // 握手阶段：处理完一批就再要一批（解析不完整时等齐字节）。
            if state != .established {
                context.read()
            }
        }
        var inbound = unwrapInboundIn(data)
        buffer.writeBuffer(&inbound)

        switch state {
        case .greeting:
            guard buffer.readableBytes >= 2,
                  let nmethods = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
                  buffer.readableBytes >= 2 + Int(nmethods) else { return }
            buffer.moveReaderIndex(forwardBy: 2 + Int(nmethods))
            // VER=05, METHOD=00（无认证）
            write(context: context, bytes: [0x05, 0x00])
            state = .request
            if buffer.readableBytes > 0 {
                // 握手包与请求包同批到达：继续解析剩余字节。
                channelRead(context: context, data: NIOAny(ByteBuffer()))
            }

        case .request:
            guard buffer.readableBytes >= 4,
                  buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0x05,
                  buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) == 0x01 else {
                replyFailureAndClose(context: context)
                return
            }
            let atyp = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) ?? 0
            var host = ""
            var headerSize = 0
            switch atyp {
            case 0x01: // IPv4
                guard buffer.readableBytes >= 4 + 4 + 2 else { return }
                let b = buffer.getBytes(at: buffer.readerIndex + 4, length: 4) ?? []
                host = b.map(String.init).joined(separator: ".")
                headerSize = 4 + 4 + 2
            case 0x03: // 域名
                guard let len = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt8.self),
                      buffer.readableBytes >= 4 + 1 + Int(len) + 2 else { return }
                let bytes = buffer.getBytes(at: buffer.readerIndex + 5, length: Int(len)) ?? []
                host = String(decoding: bytes, as: UTF8.self)
                headerSize = 4 + 1 + Int(len) + 2
            case 0x04: // IPv6
                guard buffer.readableBytes >= 4 + 16 + 2 else { return }
                let b = buffer.getBytes(at: buffer.readerIndex + 4, length: 16) ?? []
                host = stride(from: 0, to: 16, by: 2)
                    .map { String(format: "%x", Int(b[$0]) << 8 | Int(b[$0 + 1])) }
                    .joined(separator: ":")
                headerSize = 4 + 16 + 2
            default:
                replyFailureAndClose(context: context)
                return
            }
            let port = Int(buffer.getInteger(at: buffer.readerIndex + headerSize - 2, as: UInt16.self) ?? 0)
            buffer.moveReaderIndex(forwardBy: headerSize)
            openTunnel(context: context, host: host, port: port)

        case .established:
            // 已在方法顶部直通，不会走到这里。
            break
        }
    }

    private func openTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        // 同 LocalForwardAcceptHandler：channel 引用先取出来，回调里涉及
        // 本 channel 状态的操作跳回它自己的 eventLoop。
        let localChannel = context.channel
        session.createDirectTCPIPChannel(targetHost: host, targetPort: port) { child in
            child.setOption(ChannelOptions.autoRead, value: false)
        }.whenComplete { [tcpRelay] result in
            localChannel.eventLoop.execute {
                switch result {
                case .failure:
                    self.replyFailureAndClose(context: context)
                case .success(let sshChannel):
                    // REP=00 成功（BND.ADDR/PORT 填 0，客户端不校验）
                    self.write(context: context, bytes: [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                    self.state = .established
                    let sshRelay = SSHSideRelayHandler()
                    sshChannel.pipeline.addHandler(sshRelay).whenComplete { _ in
                        // 此处运行在 sshChannel（transport）EL 上。
                        sshRelay.attach(peer: localChannel)
                        localChannel.eventLoop.execute {
                            tcpRelay.attach(peer: sshChannel)
                            // 握手阶段残留在 buffer 里的数据补发给隧道。
                            if self.buffer.readableBytes > 0,
                               let chunk = self.buffer.readSlice(length: self.buffer.readableBytes) {
                                tcpRelay.channelRead(context: context, data: NIOAny(chunk))
                            }
                        }
                    }
                }
            }
        }
    }

    private func replyFailureAndClose(context: ChannelHandlerContext) {
        // REP=01 general failure
        write(context: context, bytes: [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        context.close(promise: nil)
    }

    private func write(context: ChannelHandlerContext, bytes: [UInt8]) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }
}

// MARK: - Runtime

@MainActor
final class PortForwardRuntime {
    var rule: PortForwardRule
    private let onStatus: (UUID, PortForwardStatus) -> Void

    private(set) var isIntentionallyStopped = true

    private var session: SSHSession?
    private var listenerGroup: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private var stateCancellable: AnyCancellable?
    private var reconnectWork: DispatchWorkItem?
    /// 启动全流程走完后才为 true——之后的掉线才走"保活断开"重连；
    /// 启动期失败由启动 Task 自己处理，二者靠它区分。
    private var established = false
    private var consecutiveFailures = 0

    private static let maxConsecutiveFailures = 5
    private static let reconnectDelay: TimeInterval = 3

    init(rule: PortForwardRule, onStatus: @escaping (UUID, PortForwardStatus) -> Void) {
        self.rule = rule
        self.onStatus = onStatus
    }

    // MARK: 生命周期

    func start() {
        isIntentionallyStopped = false
        consecutiveFailures = 0
        startInternal()
    }

    func stop() {
        isIntentionallyStopped = true
        established = false
        reconnectWork?.cancel()
        reconnectWork = nil
        cleanupResources()
        onStatus(rule.id, .stopped)
    }

    /// 回到前台：传输还活就不动；死了立即重连（跳过 3s 延迟）。
    func resumeAfterForeground() {
        guard !isIntentionallyStopped else { return }
        if let session, session.isConnected { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        established = false
        cleanupResources()
        startInternal()
    }

    private func startInternal() {
        guard let connection = ConnectionStore.shared.connections
            .first(where: { $0.id == rule.sshConnectionID }) else {
            onStatus(rule.id, .failed(L("规则绑定的 SSH 连接已不存在")))
            return
        }
        onStatus(rule.id, .connecting)

        let session = SessionFactory.makeSession(for: connection)
        self.session = session
        if rule.type == .remote {
            let localServicePort = rule.localServicePort
            session.inboundForwardedTCPIPHandler = { child in
                // 该闭包在 transport eventLoop 上同步执行，不能触 @MainActor 状态。
                Self.attachForwardedChannel(child, localPort: localServicePort)
            }
        }
        stateCancellable = session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, self.established, !self.isIntentionallyStopped else { return }
                if state != .connected && state != .connecting {
                    self.handleUnexpectedLoss(nil)
                }
            }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.connect()
                switch rule.type {
                case .local:
                    try await startListener(socks: false)
                case .dynamic:
                    try await startListener(socks: true)
                case .remote:
                    try await session.requestRemoteForward(
                        listenHost: "localhost",
                        listenPort: rule.remotePort
                    )
                }
                established = true
                consecutiveFailures = 0
                onStatus(rule.id, .running)
            } catch {
                handleUnexpectedLoss(error)
            }
        }
    }

    private func startListener(socks: Bool) async throws {
        guard let session else { throw SSHSessionError.notConnected }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        listenerGroup = group
        let targetHost = rule.remoteHost
        let targetPort = rule.remotePort
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // 背压：accepted 连接与 SSH 子 channel 都关 autoRead，
            // 由 relay 的写完成回调驱动下一份读取。
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                if socks {
                    channel.pipeline.addHandler(Socks5Handler(session: session))
                } else {
                    channel.pipeline.addHandler(LocalForwardAcceptHandler(
                        session: session,
                        targetHost: targetHost,
                        targetPort: targetPort
                    ))
                }
            }
        listener = try await bootstrap.bind(host: rule.localListenHost, port: rule.localListenPort).get()    }

    /// -R：把入站的 forwardedTCPIP channel 接到本地服务端口。
    /// 在 transport eventLoop 上同步调用，故为 nonisolated static。
    private nonisolated static func attachForwardedChannel(
        _ child: Channel,
        localPort: Int
    ) -> EventLoopFuture<Void> {
        let sshRelay = SSHSideRelayHandler()
        do {
            try child.pipeline.syncOperations.addHandler(sshRelay)
        } catch {
            return child.close()
        }
        // 背压：SSH 子 channel 与本地连接都关 autoRead（本地侧在 bootstrap 上设）。
        child.eventLoop.execute {
            _ = child.setOption(ChannelOptions.autoRead, value: false)
        }
        ClientBootstrap(group: child.eventLoop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(host: "127.0.0.1", port: localPort)
            .whenComplete { result in
                switch result {
                case .failure:
                    child.close(promise: nil)
                case .success(let local):
                    let tcpRelay = TCPSideRelayHandler()
                    local.pipeline.addHandler(tcpRelay).whenComplete { _ in
                        // group 就是 child.eventLoop，两侧同 EL，可直接 attach。
                        sshRelay.attach(peer: local)
                        tcpRelay.attach(peer: child)
                    }
                }
            }
        return child.eventLoop.makeSucceededFuture(())
    }

    private func handleUnexpectedLoss(_ error: Error?) {
        guard !isIntentionallyStopped else { return }
        established = false
        cleanupResources()
        consecutiveFailures += 1
        guard consecutiveFailures <= Self.maxConsecutiveFailures else {
            onStatus(rule.id, .failed(error?.localizedDescription ?? L("重连次数过多，已自动停止")))
            return
        }
        onStatus(rule.id, .connecting)
        let work = DispatchWorkItem { [weak self] in
            self?.startInternal()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay, execute: work)
    }

    private func cleanupResources() {
        stateCancellable?.cancel()
        stateCancellable = nil
        listener?.close(promise: nil)
        listener = nil
        listenerGroup?.shutdownGracefully { _ in }
        listenerGroup = nil
        session?.disconnect()
        session = nil
    }
}
