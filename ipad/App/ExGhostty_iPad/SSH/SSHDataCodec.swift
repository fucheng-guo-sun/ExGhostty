//
//  SSHDataCodec.swift
//  ExGhostty_iPad
//
//  Converts SSHChannelData <-> ByteBuffer on SSH child channels. Used by
//  the jump-host (ssh -J) nested transport, where a second NIOSSHHandler
//  — which expects raw bytes — runs on top of a directTCPIP child channel.
//

import Foundation
import NIOCore
import NIOSSH

/// Converts SSHChannelData <-> ByteBuffer on SSH child channels
/// (directTCPIP), so a nested SSH handshake can run on top of them.
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
