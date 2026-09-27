//
//  OpenSSHKeyDecryptor.swift
//  ExGhostty_iPad
//
//  Decrypts the private block of passphrase-protected openssh-key-v1
//  blobs: the bcrypt KDF (see BCryptPBKDF.swift) derives key+IV from
//  kdfoptions (string salt + uint32 rounds), then AES-CTR/CBC via
//  CommonCrypto does the bulk decryption. Empirically verified:
//  CommonCrypto's kCCModeCTR increments the counter as a 128-bit
//  big-endian integer, matching OpenSSH — no ECB fallback needed.
//

import Foundation
import CommonCrypto

enum OpenSSHKeyDecryptorError: Error, LocalizedError {
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case invalidKDFOptions
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedCipher(let cipher):
            return "不支持的加密算法：\(cipher)"
        case .unsupportedKDF(let kdf):
            return "不支持的 KDF：\(kdf)"
        case .invalidKDFOptions:
            return "私钥 KDF 参数无效"
        case .decryptionFailed:
            return "私钥解密失败"
        }
    }
}

enum OpenSSHKeyDecryptor {
    private struct CipherParams {
        let keyLength: Int
        let ivLength: Int
        let mode: CCMode
    }

    /// Decrypts the (still encrypted) private block section of an
    /// openssh-key-v1 blob. `kdfOptions` is the raw kdf-options field.
    static func decryptPrivateBlock(cipher: String, kdf: String, kdfOptions: [UInt8],
                                    passphrase: String, encrypted: [UInt8]) throws -> [UInt8] {
        guard let params = cipherParams(cipher) else {
            throw OpenSSHKeyDecryptorError.unsupportedCipher(cipher)
        }
        guard kdf == "bcrypt" else {
            throw OpenSSHKeyDecryptorError.unsupportedKDF(kdf)
        }
        guard let (salt, rounds) = parseBCryptOptions(kdfOptions) else {
            throw OpenSSHKeyDecryptorError.invalidKDFOptions
        }
        guard !encrypted.isEmpty, encrypted.count % kCCBlockSizeAES128 == 0 else {
            throw OpenSSHKeyDecryptorError.decryptionFailed
        }

        // OpenSSH passes strlen(passphrase) — no trailing NUL.
        let derived = BCryptPBKDF.deriveKey(password: Array(passphrase.utf8), salt: salt,
                                            rounds: rounds, outputLength: params.keyLength + params.ivLength)
        guard derived.count == params.keyLength + params.ivLength else {
            throw OpenSSHKeyDecryptorError.decryptionFailed
        }
        let key = Array(derived[0..<params.keyLength])
        let iv = Array(derived[params.keyLength..<params.keyLength + params.ivLength])

        // CTR encryption and decryption are identical; CBC needs kCCDecrypt.
        // OpenSSH pads the private block to the cipher block size itself,
        // so CommonCrypto padding must stay off for both modes.
        let operation = params.mode == CCMode(kCCModeCTR) ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        guard let plain = crypt(operation: operation, mode: params.mode, key: key, iv: iv, data: encrypted),
              plain.count == encrypted.count else {
            throw OpenSSHKeyDecryptorError.decryptionFailed
        }
        return plain
    }

    private static func cipherParams(_ cipher: String) -> CipherParams? {
        switch cipher {
        case "aes256-ctr": return CipherParams(keyLength: 32, ivLength: 16, mode: CCMode(kCCModeCTR))
        case "aes192-ctr": return CipherParams(keyLength: 24, ivLength: 16, mode: CCMode(kCCModeCTR))
        case "aes128-ctr": return CipherParams(keyLength: 16, ivLength: 16, mode: CCMode(kCCModeCTR))
        case "aes256-cbc": return CipherParams(keyLength: 32, ivLength: 16, mode: CCMode(kCCModeCBC))
        case "aes192-cbc": return CipherParams(keyLength: 24, ivLength: 16, mode: CCMode(kCCModeCBC))
        case "aes128-cbc": return CipherParams(keyLength: 16, ivLength: 16, mode: CCMode(kCCModeCBC))
        default: return nil
        }
    }

    /// bcrypt kdfoptions: string salt || uint32 rounds (big-endian).
    private static func parseBCryptOptions(_ options: [UInt8]) -> (salt: [UInt8], rounds: UInt32)? {
        guard options.count >= 4 else { return nil }
        let saltLength = options[0..<4].reduce(0) { ($0 << 8) | Int($1) }
        guard options.count >= 4 + saltLength + 4 else { return nil }
        let salt = Array(options[4..<4 + saltLength])
        let roundsBytes = options[(4 + saltLength)..<(4 + saltLength + 4)]
        let rounds = roundsBytes.reduce(0) { ($0 << 8) | UInt32($1) }
        guard rounds >= 1 else { return nil }
        return (salt, rounds)
    }

    private static func crypt(operation: CCOperation, mode: CCMode, key: [UInt8],
                              iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(operation, mode, CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), ivPtr.baseAddress,
                                        keyPtr.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(0), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        var updateStatus = data.withUnsafeBytes { dataPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { return nil }
        var finalMoved = 0
        updateStatus = out.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(cryptor, outPtr.baseAddress!.advanced(by: moved),
                           outCapacity - moved, &finalMoved)
        }
        guard updateStatus == kCCSuccess else { return nil }
        return Array(out[0..<(moved + finalMoved)])
    }
}
