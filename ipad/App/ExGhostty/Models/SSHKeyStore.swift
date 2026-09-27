//
//  SSHKeyStore.swift
//  ExGhostty_iPad
//
//  Manages imported SSH private keys. Metadata (name/type/fingerprint-ish)
//  lives in UserDefaults; the private key material itself lives in Keychain.
//

import Foundation

struct SSHKeyMeta: Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// e.g. "ssh-ed25519", "ecdsa-sha2-nistp256", detected at import time.
    var keyType: String
    var createdAt: Date = Date()
    /// Whether the stored key material is passphrase-encrypted (imported
    /// without decryption; the passphrase is supplied per connection).
    var isEncrypted: Bool = false
}

// Custom Codable: `isEncrypted` was added after the first release, so old
// saved JSON lacks it — decode with decodeIfPresent + a default. Kept in an
// extension to preserve the memberwise initializer (same pattern as
// SSHConnectionConfig).
extension SSHKeyMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, keyType, createdAt, isEncrypted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        keyType = try container.decodeIfPresent(String.self, forKey: .keyType) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isEncrypted = try container.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(keyType, forKey: .keyType)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isEncrypted, forKey: .isEncrypted)
    }
}

final class SSHKeyStore: ObservableObject {
    static let shared = SSHKeyStore()

    private let defaultsKey = "exghostty.ipad.sshKeys"

    @Published private(set) var keys: [SSHKeyMeta] = []

    init() {
        load()
    }

    /// Imports a private key (OpenSSH or PEM text). Returns the stored meta,
    /// or throws when the key cannot be parsed. An encrypted key is accepted
    /// without decryption (flagged via `isEncrypted`); the passphrase is
    /// then supplied per connection at auth time.
    @discardableResult
    func importKey(name: String, text: String) throws -> SSHKeyMeta {
        let meta: SSHKeyMeta
        do {
            let parsed = try SSHKeyParser.parse(text)
            meta = SSHKeyMeta(name: name, keyType: parsed.keyType)
        } catch SSHKeyParserError.passphraseRequired {
            guard let info = SSHKeyParser.inspect(text) else {
                throw SSHKeyParserError.passphraseRequired
            }
            meta = SSHKeyMeta(name: name, keyType: info.keyType, isEncrypted: true)
        }
        KeychainHelper.saveKey(text, for: meta.id)
        keys.append(meta)
        save()
        return meta
    }

    func keyText(for id: UUID) -> String? {
        KeychainHelper.key(for: id)
    }

    func meta(for id: UUID?) -> SSHKeyMeta? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }

    func delete(_ meta: SSHKeyMeta) {
        keys.removeAll { $0.id == meta.id }
        KeychainHelper.deleteKey(for: meta.id)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SSHKeyMeta].self, from: data) else {
            keys = []
            return
        }
        keys = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
