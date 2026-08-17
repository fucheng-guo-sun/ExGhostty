//
//  SSHKeyStore.swift
//  ExGhostty_iPad
//
//  Manages imported SSH private keys. Metadata (name/type/fingerprint-ish)
//  lives in UserDefaults; the private key material itself lives in Keychain.
//

import Foundation

struct SSHKeyMeta: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// e.g. "ssh-ed25519", "ecdsa-sha2-nistp256", detected at import time.
    var keyType: String
    var createdAt: Date = Date()
}

final class SSHKeyStore: ObservableObject {
    static let shared = SSHKeyStore()

    private let defaultsKey = "exghostty.ipad.sshKeys"

    @Published private(set) var keys: [SSHKeyMeta] = []

    init() {
        load()
    }

    /// Imports a private key (OpenSSH or PEM text). Returns the stored meta,
    /// or throws when the key cannot be parsed.
    @discardableResult
    func importKey(name: String, text: String) throws -> SSHKeyMeta {
        let parsed = try SSHKeyParser.parse(text)
        let meta = SSHKeyMeta(name: name, keyType: parsed.keyType)
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

    /// Replaces the metadata list (used by iCloud sync). Key material is
    /// expected to arrive via iCloud Keychain separately.
    func replaceAll(_ newKeys: [SSHKeyMeta]) {
        keys = newKeys
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
