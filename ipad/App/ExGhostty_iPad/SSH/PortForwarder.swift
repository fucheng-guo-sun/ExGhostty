//
//  PortForwarder.swift
//  iOSTerminal
//
//  Port forwarding engine: local (-L), remote (-R) and dynamic (-D, SOCKS5).
//  One manager per SSHSession; started rules are torn down with the session.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - SOCKS5

/// Minimal SOCKS5 server handler (no-auth, CONNECT only). After the
/// handshake it opens a directTCPIP channel through the SSH session and
/// glues the two sides, then removes itself from the pipeline.
private final class SOCKS5Handler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase {
        case greeting
        case request
    }

    private let session: SSHSession
    private var phase: Phase = .greeting
    private var buffer = ByteBuffer()

    init(session: SSHSession) {
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        buffer.writeBuffer(&inbound)
        switch phase {
        case .greeting:
            parseGreeting(context: context)
        case .request:
            parseRequest(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func parseGreeting(context: ChannelHandlerContext) {
        // VER NMETHODS METHODS...
        guard buffer.readableBytes >= 2,
              let count = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
              buffer.readableBytes >= 2 + Int(count) else { return }

        guard let version: UInt8 = buffer.readInteger(), version == 5 else {
            context.close(promise: nil)
            return
        }
        _ = buffer.readInteger(as: UInt8.self) // nmethods
        buffer.moveReaderIndex(forwardBy: Int(count))

        // No authentication required.
        var reply = context.channel.allocator.buffer(capacity: 2)
        reply.writeBytes([0x05, 0x00])
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        phase = .request
    }

    private func parseRequest(context: ChannelHandlerContext) {
        // VER CMD RSV ATYP DST.ADDR DST.PORT
        guard buffer.readableBytes >= 5,
              let atyp: UInt8 = buffer.getInteger(at: buffer.readerIndex + 3) else { return }

        let addressLength: Int
        switch atyp {
        case 0x01: addressLength = 4
        case 0x03:
            guard let len: UInt8 = buffer.getInteger(at: buffer.readerIndex + 4) else { return }
            addressLength = 1 + Int(len)
        case 0x04: addressLength = 16
        default:
            sendReply(context: context, status: 0x08) // address type not supported
            return
        }
        guard buffer.readableBytes >= 4 + addressLength + 2 else { return }

        guard let version: UInt8 = buffer.readInteger(), version == 5,
              let command: UInt8 = buffer.readInteger(),
              buffer.readInteger(as: UInt8.self) != nil, // RSV
              buffer.readInteger(as: UInt8.self) != nil  // ATYP
        else {
            context.close(promise: nil)
            return
        }

        let host: String
        switch atyp {
        case 0x01:
            guard let bytes = buffer.readBytes(length: 4) else { return }
            host = bytes.map(String.init).joined(separator: ".")
        case 0x03:
            guard let len: UInt8 = buffer.readInteger(),
                  let bytes = buffer.readBytes(length: Int(len)) else { return }
            host = String(decoding: bytes, as: UTF8.self)
        case 0x04:
            guard let bytes = buffer.readBytes(length: 16) else { return }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { ptr in
                ptr.copyBytes(from: bytes)
            }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var copy = addr
            guard inet_ntop(AF_INET6, &copy, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                sendReply(context: context, status: 0x04)
                return
            }
            host = String(cString: text)
        default:
            return
        }

        guard let portRaw: UInt16 = buffer.readInteger() else { return }
        let port = Int(portRaw)

        guard command == 0x01 else {
            sendReply(context: context, status: 0x07) // command not supported
            return
        }

        let leftover = buffer.readableBytes > 0 ? buffer.readSlice(length: buffer.readableBytes) : nil

        session.openDirectTCPIP(host: host, port: port).whenComplete { result in
            // The completion runs on the transport's loop; context belongs to
            // the accepted child channel's loop, so hop before touching it.
            context.eventLoop.execute {
                switch result {
                case .failure:
                    self.sendReply(context: context, status: 0x05) // connection refused
                case .success(let sshChannel):
                    self.sendReply(context: context, status: 0x00)
                    GlueHandler.glue(context.channel, sshChannel).whenComplete { _ in
                        if let leftover, leftover.readableBytes > 0 {
                            sshChannel.writeAndFlush(leftover, promise: nil)
                        }
                        context.eventLoop.execute {
                            context.pipeline.removeHandler(self, promise: nil)
                        }
                    }
                }
            }
        }
    }

    private func sendReply(context: ChannelHandlerContext, status: UInt8) {
        // VER REP RSV ATYP(IPv4) BND.ADDR(0.0.0.0) BND.PORT(0)
        var reply = context.channel.allocator.buffer(capacity: 10)
        reply.writeBytes([0x05, status, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in
            if status != 0x00 {
                context.close(promise: nil)
            }
        }
    }
}

// MARK: - PortForwardManager

@MainActor
final class PortForwardManager: ObservableObject {
    enum ForwardState: Equatable {
        case starting
        case active
        case failed(String)
        case stopped
    }

    @Published private(set) var states: [UUID: ForwardState] = [:]

    private let session: SSHSession
    private var listeners: [UUID: Channel] = [:]

    init(session: SSHSession) {
        self.session = session
    }

    /// Starts all enabled rules for the session's connection.
    func startAll(rules: [PortForwardRule]) async {
        for rule in rules where rule.isEnabled {
            await start(rule: rule)
        }
    }

    func start(rule: PortForwardRule) async {
        if case .active = states[rule.id] { return }
        states[rule.id] = .starting
        do {
            switch rule.type {
            case .local:
                try await startLocal(rule: rule)
            case .dynamic:
                try await startDynamic(rule: rule)
            case .remote:
                try await startRemote(rule: rule)
            }
            states[rule.id] = .active
        } catch {
            states[rule.id] = .failed(error.localizedDescription)
        }
    }

    func stop(rule: PortForwardRule) async {
        if let listener = listeners.removeValue(forKey: rule.id), listener.isActive {
            try? await listener.close()
        }
        if rule.type == .remote {
            session.unregisterRemoteForward(port: rule.listenPort)
            if let handler = try? await session.sshHandler(),
               let transport = try? session.requireTransport() {
                transport.eventLoop.execute {
                    handler.sendTCPForwardingRequest(
                        .cancel(host: rule.listenHost, port: rule.listenPort),
                        promise: nil
                    )
                }
            }
        }
        states[rule.id] = .stopped
    }

    func stopAll() async {
        for (_, listener) in listeners where listener.isActive {
            try? await listener.close()
        }
        listeners.removeAll()
        states.removeAll()
    }

    // MARK: Local (-L)

    private func startLocal(rule: PortForwardRule) async throws {
        let group = try session.requireGroup()
        let session = self.session

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { child in
                session.openDirectTCPIP(host: rule.targetHost, port: rule.targetPort)
                    .flatMap { sshChannel in
                        GlueHandler.glue(child, sshChannel)
                    }
            }

        let server = try await bootstrap.bind(host: rule.listenHost, port: rule.listenPort).get()
        listeners[rule.id] = server
    }

    // MARK: Dynamic (-D, SOCKS5)

    private func startDynamic(rule: PortForwardRule) async throws {
        let group = try session.requireGroup()
        let session = self.session

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { child in
                child.pipeline.addHandler(SOCKS5Handler(session: session))
            }

        let server = try await bootstrap.bind(host: rule.listenHost, port: rule.listenPort).get()
        listeners[rule.id] = server
    }

    // MARK: Remote (-R)

    private func startRemote(rule: PortForwardRule) async throws {
        // Register first so early inbound connections find the rule.
        session.registerRemoteForward(rule: rule)

        let handler = try await session.sshHandler()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let transport: Channel
            do {
                transport = try session.requireTransport()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let promise = transport.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            promise.futureResult.whenComplete { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            transport.eventLoop.execute {
                handler.sendTCPForwardingRequest(
                    .listen(host: rule.listenHost, port: rule.listenPort),
                    promise: promise
                )
            }
        }
    }
}
