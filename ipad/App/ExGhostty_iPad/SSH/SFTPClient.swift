//
//  SFTPClient.swift
//  iOSTerminal
//
//  Minimal SFTP v3 client (draft-ietf-secsh-filexfer-02) running on an
//  NIOSSH child channel ("sftp" subsystem). Supports directory listing,
//  stat, upload, download, remove, rename and mkdir.
//

import Foundation
import NIOCore
import NIOSSH

// MARK: - Public model

struct SFTPItem: Identifiable, Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: UInt32
    let modificationDate: Date?

    var id: String { path }
}

enum SFTPError: Error, LocalizedError {
    case unexpectedMessage(UInt8)
    case server(code: UInt32, message: String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unexpectedMessage(let type):
            return "Unexpected SFTP message type \(type)"
        case .server(let code, let message):
            return message.isEmpty ? "SFTP error \(code)" : message
        case .notConnected:
            return "SFTP channel is not connected"
        }
    }
}

// MARK: - Wire format

private enum SFTPMessageType: UInt8 {
    case init_ = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6
    case stat = 16, lstat = 7
    case opendir = 11, readdir = 12
    case remove = 13, mkdir = 14, rmdir = 15, rename = 18
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
}

private enum SFTPStatus: UInt32 {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
}

private struct SFTPWriter {
    var buffer: ByteBuffer

    init(allocator: ByteBufferAllocator) {
        buffer = allocator.buffer(capacity: 256)
    }

    mutating func writeUInt8(_ value: UInt8) { buffer.writeInteger(value) }
    mutating func writeUInt32(_ value: UInt32) { buffer.writeInteger(value) }
    mutating func writeUInt64(_ value: UInt64) { buffer.writeInteger(value) }

    mutating func writeString(_ string: String) {
        let bytes = Array(string.utf8)
        buffer.writeInteger(UInt32(bytes.count))
        buffer.writeBytes(bytes)
    }

    mutating func writeByteString(_ bytes: [UInt8]) {
        buffer.writeInteger(UInt32(bytes.count))
        buffer.writeBytes(bytes)
    }
}

private struct SFTPReader {
    private(set) var buffer: ByteBuffer

    init(buffer: ByteBuffer) { self.buffer = buffer }

    var isAtEnd: Bool { buffer.readableBytes == 0 }

    mutating func readUInt8() -> UInt8? { buffer.readInteger() }
    mutating func readUInt32() -> UInt32? { buffer.readInteger() }
    mutating func readUInt64() -> UInt64? { buffer.readInteger() }

    mutating func readString() -> String? {
        guard let bytes: [UInt8] = readByteString() else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readByteString() -> [UInt8]? {
        guard let length: UInt32 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length)) else { return nil }
        return bytes
    }
}

private struct SFTPAttributes {
    var size: UInt64 = 0
    var permissions: UInt32 = 0
    var modificationDate: Date? = nil

    var isDirectory: Bool { permissions & 0o170000 == 0o040000 }

    static let empty = SFTPAttributes()
}

private extension SFTPReader {
    mutating func readAttributes() -> SFTPAttributes? {
        guard let flags: UInt32 = readUInt32() else { return nil }
        var attrs = SFTPAttributes()
        if flags & 0x1 != 0 {
            guard let size: UInt64 = readUInt64() else { return nil }
            attrs.size = size
        }
        if flags & 0x2 != 0 {
            // uid/gid, unused
            guard readUInt32() != nil, readUInt32() != nil else { return nil }
        }
        if flags & 0x4 != 0 {
            guard let permissions: UInt32 = readUInt32() else { return nil }
            attrs.permissions = permissions
        }
        if flags & 0x8 != 0 {
            guard readUInt32() != nil, let mtime: UInt32 = readUInt32() else { return nil }
            attrs.modificationDate = Date(timeIntervalSince1970: TimeInterval(mtime))
        }
        if flags & 0x8000_0000 != 0 {
            guard let count: UInt32 = readUInt32() else { return nil }
            for _ in 0..<count {
                guard readString() != nil, readString() != nil else { return nil }
            }
        }
        return attrs
    }
}

private struct SFTPResponse {
    var type: UInt8
    var reader: SFTPReader
}

// MARK: - Channel handler

private final class SFTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var inbound = ByteBuffer()
    private var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
    private var nextRequestID: UInt32 = 0

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: false)
        context.triggerUserOutboundEvent(request).whenComplete { result in
            if case .failure(let error) = result {
                self.failAll(with: error)
                context.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data else { return }
        inbound.writeBuffer(&buffer)
        drainPackets()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(with: SFTPError.notConnected)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(with: error)
        context.close(promise: nil)
    }

    /// Sends a request packet (length prefix + type + request id + payload)
    /// and returns a future for its response. Must be called on the event loop.
    func sendRequest(
        type: SFTPMessageType,
        on context: ChannelHandlerContext,
        payload: (inout SFTPWriter) -> Void
    ) -> EventLoopPromise<SFTPResponse> {
        let id = nextRequestID
        nextRequestID &+= 1

        var writer = SFTPWriter(allocator: context.channel.allocator)
        writer.writeUInt8(type.rawValue)
        writer.writeUInt32(id)
        payload(&writer)

        var framed = context.channel.allocator.buffer(capacity: writer.buffer.readableBytes + 4)
        framed.writeInteger(UInt32(writer.buffer.readableBytes))
        framed.writeBuffer(&writer.buffer)

        let promise = context.eventLoop.makePromise(of: SFTPResponse.self)
        pending[id] = promise
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(framed))), promise: nil)
        return promise
    }

    private func drainPackets() {
        while inbound.readableBytes >= 4 {
            guard let length: UInt32 = inbound.getInteger(at: inbound.readerIndex) else { return }
            guard inbound.readableBytes >= 4 + Int(length) else { return }
            inbound.moveReaderIndex(forwardBy: 4)
            guard var packet = inbound.readSlice(length: Int(length)),
                  let type: UInt8 = packet.readInteger() else { return }

            var response: SFTPResponse
            if type == SFTPMessageType.version.rawValue {
                response = SFTPResponse(type: type, reader: SFTPReader(buffer: packet))
                // VERSION has no request id; complete the synthetic id used by INIT.
                if let promise = pending.removeValue(forKey: UInt32.max) {
                    promise.succeed(response)
                }
                continue
            }

            guard let id: UInt32 = packet.readInteger() else { continue }
            response = SFTPResponse(type: type, reader: SFTPReader(buffer: packet))
            if let promise = pending.removeValue(forKey: id) {
                promise.succeed(response)
            }
        }
    }

    private func failAll(with error: Error) {
        let promises = pending
        pending.removeAll()
        for (_, promise) in promises {
            promise.fail(error)
        }
    }
}

// MARK: - SFTPClient

final class SFTPClient {
    private let channel: Channel
    private let handler: SFTPChannelHandler

    private init(channel: Channel, handler: SFTPChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Opens an SFTP subsystem on a fresh child channel of the session.
    static func open(on session: SSHSession) async throws -> SFTPClient {
        final class Box { var handler: SFTPChannelHandler? }
        let box = Box()

        let channel: Channel = try await withCheckedThrowingContinuation { continuation in
            session.createChildChannel { child in
                child.eventLoop.makeCompletedFuture {
                    let handler = SFTPChannelHandler()
                    box.handler = handler
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }.whenComplete { result in
                continuation.resume(with: result)
            }
        }

        guard let handler = box.handler else { throw SFTPError.notConnected }
        let client = SFTPClient(channel: channel, handler: handler)
        try await client.handshake()
        return client
    }

    func close() {
        channel.close(promise: nil)
    }

    // MARK: Handshake

    private func handshake() async throws {
        // SSH_FXP_INIT has a version field instead of a request id; the
        // response (VERSION) is matched with the synthetic id UInt32.max.
        let response = try await withChannelContext { context in
            let id = UInt32.max
            var writer = SFTPWriter(allocator: context.channel.allocator)
            writer.writeUInt8(SFTPMessageType.init_.rawValue)
            writer.writeUInt32(3) // protocol version
            var framed = context.channel.allocator.buffer(capacity: writer.buffer.readableBytes + 4)
            framed.writeInteger(UInt32(writer.buffer.readableBytes))
            framed.writeBuffer(&writer.buffer)
            let promise = self.handler.sendRawRequest(id: id, on: context, packet: framed)
            return promise
        }
        guard response.type == SFTPMessageType.version.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
    }

    // MARK: Directory listing

    func listDirectory(_ path: String) async throws -> [SFTPItem] {
        let handle = try await openDirectory(path)
        defer { closeHandle(handle) }

        var items: [SFTPItem] = []
        while true {
            let response = try await request(.readdir) { $0.writeByteString(handle) }
            switch response.type {
            case SFTPMessageType.name.rawValue:
                var reader = response.reader
                guard let count: UInt32 = reader.readUInt32() else {
                    throw SFTPError.unexpectedMessage(response.type)
                }
                for _ in 0..<count {
                    guard let name = reader.readString(),
                          reader.readString() != nil, // longname, unused
                          let attrs = reader.readAttributes() else { continue }
                    if name == "." || name == ".." { continue }
                    let itemPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    items.append(SFTPItem(
                        name: name,
                        path: itemPath,
                        isDirectory: attrs.isDirectory,
                        size: attrs.size,
                        permissions: attrs.permissions,
                        modificationDate: attrs.modificationDate
                    ))
                }
            case SFTPMessageType.status.rawValue:
                let status = try parseStatus(response.reader)
                if status.code == SFTPStatus.eof.rawValue { return items }
                throw SFTPError.server(code: status.code, message: status.message)
            default:
                throw SFTPError.unexpectedMessage(response.type)
            }
        }
    }

    // MARK: Stat

    func stat(_ path: String) async throws -> SFTPItem? {
        let response = try await request(.lstat) { $0.writeString(path) }
        if response.type == SFTPMessageType.status.rawValue {
            let status = try parseStatus(response.reader)
            if status.code == SFTPStatus.noSuchFile.rawValue { return nil }
            throw SFTPError.server(code: status.code, message: status.message)
        }
        guard response.type == SFTPMessageType.attrs.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        var reader = response.reader
        guard let attrs = reader.readAttributes() else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        let name = (path as NSString).lastPathComponent
        return SFTPItem(
            name: name,
            path: path,
            isDirectory: attrs.isDirectory,
            size: attrs.size,
            permissions: attrs.permissions,
            modificationDate: attrs.modificationDate
        )
    }

    // MARK: File transfer

    func download(remotePath: String, to localURL: URL, progress: (@Sendable (UInt64) -> Void)? = nil) async throws {
        let handle = try await openFile(remotePath, flags: 0x1, attrs: .empty)
        defer { closeHandle(handle) }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }

        var offset: UInt64 = 0
        let chunkSize: UInt32 = 64 * 1024
        while true {
            let response = try await request(.read) {
                $0.writeByteString(handle)
                $0.writeUInt64(offset)
                $0.writeUInt32(chunkSize)
            }
            switch response.type {
            case SFTPMessageType.data.rawValue:
                var reader = response.reader
                guard let bytes = reader.readByteString() else {
                    throw SFTPError.unexpectedMessage(response.type)
                }
                if bytes.isEmpty { return }
                try file.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                progress?(offset)
            case SFTPMessageType.status.rawValue:
                let status = try parseStatus(response.reader)
                if status.code == SFTPStatus.eof.rawValue { return }
                throw SFTPError.server(code: status.code, message: status.message)
            default:
                throw SFTPError.unexpectedMessage(response.type)
            }
        }
    }

    func upload(localURL: URL, to remotePath: String, progress: (@Sendable (UInt64) -> Void)? = nil) async throws {
        let handle = try await openFile(remotePath, flags: 0x2 | 0x8 | 0x10, attrs: .empty) // write|creat|trunc
        defer { closeHandle(handle) }

        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }

        var offset: UInt64 = 0
        let chunkSize = 64 * 1024
        while true {
            let data = try file.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { return }
            let response = try await request(.write) {
                $0.writeByteString(handle)
                $0.writeUInt64(offset)
                $0.writeByteString(Array(data))
            }
            let status = try parseResponseStatus(response)
            guard status.code == SFTPStatus.ok.rawValue else {
                throw SFTPError.server(code: status.code, message: status.message)
            }
            offset += UInt64(data.count)
            progress?(offset)
        }
    }

    // MARK: File operations

    func removeFile(_ path: String) async throws {
        let status = try parseResponseStatus(try await request(.remove) { $0.writeString(path) })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    func removeDirectory(_ path: String) async throws {
        let status = try parseResponseStatus(try await request(.rmdir) { $0.writeString(path) })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    func makeDirectory(_ path: String) async throws {
        let status = try parseResponseStatus(try await request(.mkdir) {
            $0.writeString(path)
            $0.writeUInt32(0) // empty attrs
        })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        let status = try parseResponseStatus(try await request(.rename) {
            $0.writeString(oldPath)
            $0.writeString(newPath)
        })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    // MARK: Internals

    private func openDirectory(_ path: String) async throws -> [UInt8] {
        let response = try await request(.opendir) { $0.writeString(path) }
        return try parseHandle(response)
    }

    private func openFile(_ path: String, flags: UInt32, attrs: SFTPAttributes) async throws -> [UInt8] {
        let response = try await request(.open) {
            $0.writeString(path)
            $0.writeUInt32(flags)
            $0.writeUInt32(0) // empty attrs
        }
        return try parseHandle(response)
    }

    private func closeHandle(_ handle: [UInt8]) {
        Task { try? await closeHandleAndWait(handle) }
    }

    private func closeHandleAndWait(_ handle: [UInt8]) async throws {
        let response = try await request(.close) { $0.writeByteString(handle) }
        _ = try parseResponseStatus(response)
    }

    private func parseHandle(_ response: SFTPResponse) throws -> [UInt8] {
        if response.type == SFTPMessageType.status.rawValue {
            let status = try parseStatus(response.reader)
            throw SFTPError.server(code: status.code, message: status.message)
        }
        guard response.type == SFTPMessageType.handle.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        var reader = response.reader
        guard let handle = reader.readByteString() else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        return handle
    }

    private func parseStatus(_ reader: SFTPReader) throws -> (code: UInt32, message: String) {
        var reader = reader
        guard let code: UInt32 = reader.readUInt32() else {
            throw SFTPError.unexpectedMessage(SFTPMessageType.status.rawValue)
        }
        let message = reader.readString() ?? ""
        return (code, message)
    }

    private func parseResponseStatus(_ response: SFTPResponse) throws -> (code: UInt32, message: String) {
        guard response.type == SFTPMessageType.status.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        return try parseStatus(response.reader)
    }

    /// Runs `body` on the channel's event loop, giving it the handler context,
    /// and awaits the resulting response future.
    private func request(
        _ type: SFTPMessageType,
        payload: @escaping (inout SFTPWriter) -> Void
    ) async throws -> SFTPResponse {
        try await withChannelContext { context in
            self.handler.sendRequest(type: type, on: context, payload: payload)
        }
    }

    private func withChannelContext(
        _ body: @escaping (ChannelHandlerContext) -> EventLoopPromise<SFTPResponse>
    ) async throws -> SFTPResponse {
        let future: EventLoopFuture<SFTPResponse> = channel.pipeline.context(handler: handler)
            .flatMap { context in
                body(context).futureResult
            }
        return try await future.get()
    }
}

// MARK: - Handler support for raw (id-less) requests

extension SFTPChannelHandler {
    /// Sends an already-framed packet and registers a pending promise under a
    /// caller-chosen id (used for INIT, whose response has no request id).
    func sendRawRequest(id: UInt32, on context: ChannelHandlerContext, packet: ByteBuffer) -> EventLoopPromise<SFTPResponse> {
        let promise = context.eventLoop.makePromise(of: SFTPResponse.self)
        pending[id] = promise
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(packet))), promise: nil)
        return promise
    }
}
