//
//  GlueHandler.swift
//  iOSTerminal
//
//  Bidirectional byte pipe between two NIO channels, used by port
//  forwarding. SSH child channels speak SSHChannelData, so a codec
//  converts to plain ByteBuffer first.
//

import Foundation
import NIOCore
import NIOSSH

/// Converts SSHChannelData <-> ByteBuffer on SSH child channels
/// (directTCPIP / forwardedTCPIP), so they can be glued to raw TCP channels.
final class SSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = payload.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// One direction of a glue pair: everything read is written to the partner.
final class GlueHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let partner: Channel

    init(partner: Channel) {
        self.partner = partner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        partner.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner.close(promise: nil)
        context.close(promise: nil)
    }

    /// Installs a glue pair between two channels (both must speak ByteBuffer
    /// at this point in their pipelines). Handler installation hops onto each
    /// channel's own event loop; the returned future completes only after
    /// both handlers are in place and reads have been resumed on both sides.
    @discardableResult
    static func glue(_ first: Channel, _ second: Channel) -> EventLoopFuture<Void> {
        func add(_ channel: Channel, partner: Channel) -> EventLoopFuture<Void> {
            channel.eventLoop.flatSubmit {
                channel.pipeline.addHandler(GlueHandler(partner: partner))
            }
        }
        return add(first, partner: second).and(add(second, partner: first)).map { _ in
            resumeReading(first)
            resumeReading(second)
        }
    }

    /// Re-enables autoRead (forwarded channels are created with autoRead off
    /// so early data is not dropped before the glue is installed).
    static func resumeReading(_ channel: Channel) {
        channel.eventLoop.execute {
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
            channel.read()
        }
    }
}
