//
//  SSHKeyParser.swift
//  iOSTerminal
//
//  Parses unencrypted OpenSSH ("openssh-key-v1") and PEM private keys
//  (Ed25519 / ECDSA / RSA) into NIOSSHPrivateKey. RSA support comes from
//  the vendored swift-nio-ssh fork (Vendor/swift-nio-ssh) backed by
//  swift-crypto's _CryptoExtras. Passphrase-encrypted keys are rejected
//  with a clear error.
//

import Foundation
import Crypto
import _CryptoExtras
import NIOSSH

enum SSHKeyParserError: Error, LocalizedError {
    case unrecognizedFormat
    case encryptedKeyUnsupported
    case invalidKeyMaterial(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "无法识别的私钥格式（支持未加密的 OpenSSH / PEM 格式 Ed25519、ECDSA、RSA 私钥）"
        case .encryptedKeyUnsupported:
            return "暂不支持带口令加密的私钥，请使用未加密私钥"
        case .invalidKeyMaterial(let detail):
            return "私钥内容无效：\(detail)"
        }
    }
}

enum SSHKeyParser {
    struct ParsedKey {
        let key: NIOSSHPrivateKey
        let keyType: String
    }

    static func parse(_ text: String) throws -> ParsedKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(trimmed)
        }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            return try parseRSAPEM(trimmed)
        }
        if trimmed.contains("BEGIN PRIVATE KEY") || trimmed.contains("BEGIN EC PRIVATE KEY") {
            // PKCS#8 / SEC1：先按 EC 解析，失败再按 RSA 解析
            if let ec = try? parsePEM(trimmed) {
                return ec
            }
            return try parseRSAPEM(trimmed)
        }
        throw SSHKeyParserError.unrecognizedFormat
    }

    // MARK: PEM (SEC1 / PKCS8 EC keys via swift-crypto)

    private static func parsePEM(_ pem: String) throws -> ParsedKey {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return ParsedKey(key: NIOSSHPrivateKey(p256Key: key), keyType: "ecdsa-sha2-nistp256")
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return ParsedKey(key: NIOSSHPrivateKey(p384Key: key), keyType: "ecdsa-sha2-nistp384")
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return ParsedKey(key: NIOSSHPrivateKey(p521Key: key), keyType: "ecdsa-sha2-nistp521")
        }
        throw SSHKeyParserError.invalidKeyMaterial("PEM 解析失败")
    }

    // MARK: PEM RSA (PKCS#1 / PKCS#8 via _CryptoExtras)

    private static func parseRSAPEM(_ pem: String) throws -> ParsedKey {
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: base64) else {
            throw SSHKeyParserError.invalidKeyMaterial("Base64 解码失败")
        }
        do {
            // unsafeDERRepresentation 同时接受 PKCS#1 和 PKCS#8，允许 >=1024 位的旧密钥
            let key = try _RSA.Signing.PrivateKey(unsafeDERRepresentation: der)
            return ParsedKey(key: NIOSSHPrivateKey(rsaKey: key), keyType: "ssh-rsa")
        } catch {
            throw SSHKeyParserError.invalidKeyMaterial("RSA 私钥解析失败")
        }
    }

    // MARK: OpenSSH openssh-key-v1

    private struct Reader {
        var data: [UInt8]
        var offset = 0

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard offset + count <= data.count else { return nil }
            defer { offset += count }
            return Array(data[offset..<offset + count])
        }

        mutating func readUInt32() -> UInt32? {
            guard let bytes = readBytes(4) else { return nil }
            return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func readString() -> [UInt8]? {
            guard let length = readUInt32() else { return nil }
            return readBytes(Int(length))
        }

        mutating func readText() -> String? {
            readString().map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private static func parseOpenSSH(_ pem: String) throws -> ParsedKey {
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let blob = Data(base64Encoded: base64) else {
            throw SSHKeyParserError.invalidKeyMaterial("Base64 解码失败")
        }

        var reader = Reader(data: Array(blob))
        let magic = reader.readBytes(15).map { String(decoding: $0, as: UTF8.self) }
        guard magic == "openssh-key-v1\0" else {
            throw SSHKeyParserError.invalidKeyMaterial("魔数不匹配")
        }

        guard let cipher = reader.readText(), let kdf = reader.readText() else {
            throw SSHKeyParserError.invalidKeyMaterial("头部不完整")
        }
        guard cipher == "none", kdf == "none" else {
            throw SSHKeyParserError.encryptedKeyUnsupported
        }
        guard reader.readString() != nil, // kdf options
              reader.readUInt32() != nil, // key count
              reader.readString() != nil, // public key blob
              let privateBlock = reader.readString() else {
            throw SSHKeyParserError.invalidKeyMaterial("头部不完整")
        }

        var priv = Reader(data: privateBlock)
        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32(), check1 == check2 else {
            throw SSHKeyParserError.invalidKeyMaterial("校验失败")
        }
        guard let keyType = priv.readText() else {
            throw SSHKeyParserError.invalidKeyMaterial("缺少密钥类型")
        }

        switch keyType {
        case "ssh-ed25519":
            guard let publicKey = priv.readString(), publicKey.count == 32,
                  let privateKey = priv.readString(), privateKey.count == 64 else {
                throw SSHKeyParserError.invalidKeyMaterial("Ed25519 密钥长度错误")
            }
            let seed = Data(privateKey[0..<32])
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                return ParsedKey(key: NIOSSHPrivateKey(ed25519Key: key), keyType: keyType)
            } catch {
                throw SSHKeyParserError.invalidKeyMaterial("Ed25519 构造失败")
            }

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let size = keyType.hasSuffix("256") ? 32 : keyType.hasSuffix("384") ? 48 : 66
            guard priv.readText() != nil, // curve name
                  priv.readString() != nil, // public point Q
                  let scalar = priv.readString() else {
                throw SSHKeyParserError.invalidKeyMaterial("ECDSA 字段不完整")
            }
            let raw = fixedWidthBytes(scalar, size: size)
            do {
                switch size {
                case 32:
                    let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
                    return ParsedKey(key: NIOSSHPrivateKey(p256Key: key), keyType: keyType)
                case 48:
                    let key = try P384.Signing.PrivateKey(rawRepresentation: raw)
                    return ParsedKey(key: NIOSSHPrivateKey(p384Key: key), keyType: keyType)
                default:
                    let key = try P521.Signing.PrivateKey(rawRepresentation: raw)
                    return ParsedKey(key: NIOSSHPrivateKey(p521Key: key), keyType: keyType)
                }
            } catch {
                throw SSHKeyParserError.invalidKeyMaterial("ECDSA 构造失败")
            }

        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            // openssh-key-v1 中 ssh-rsa 字段顺序：n, e, d, iqmp, p, q
            guard let n = priv.readString(), let e = priv.readString(),
                  let d = priv.readString(), priv.readString() != nil, // iqmp 不需要
                  let p = priv.readString(), let q = priv.readString() else {
                throw SSHKeyParserError.invalidKeyMaterial("RSA 字段不完整")
            }
            do {
                let key = try _RSA.Signing.PrivateKey(
                    n: stripLeadingZeros(n), e: stripLeadingZeros(e), d: stripLeadingZeros(d),
                    p: stripLeadingZeros(p), q: stripLeadingZeros(q)
                )
                return ParsedKey(key: NIOSSHPrivateKey(rsaKey: key), keyType: "ssh-rsa")
            } catch {
                throw SSHKeyParserError.invalidKeyMaterial("RSA 构造失败")
            }

        default:
            throw SSHKeyParserError.invalidKeyMaterial("不支持的密钥类型 \(keyType)")
        }
    }

    /// mpint → fixed-width big-endian bytes.
    private static func fixedWidthBytes(_ mpint: [UInt8], size: Int) -> Data {
        var bytes = mpint
        while bytes.first == 0 && bytes.count > size {
            bytes.removeFirst()
        }
        if bytes.count < size {
            bytes = Array(repeating: 0, count: size - bytes.count) + bytes
        }
        return Data(bytes.prefix(size))
    }

    /// 剥掉正数 mpint 的前导零字节。
    private static func stripLeadingZeros(_ mpint: [UInt8]) -> [UInt8] {
        var bytes = mpint
        while bytes.count > 1 && bytes.first == 0 {
            bytes.removeFirst()
        }
        return bytes
    }
}
