//
//  KeychainHelper.swift
//  iOSTerminal
//
//  Minimal Keychain wrapper for storing connection passwords and private
//  keys. Items are marked synchronizable (iCloud Keychain); every query
//  must therefore include kSecAttrSynchronizableAny, otherwise reads miss
//  synchronizable items (observed on devices without iCloud signed in:
//  SecItemAdd succeeds, SecItemCopyMatching returns errSecItemNotFound).
//

import Foundation
import Security

enum KeychainHelper {
    private static let service = "org.tirania.SwiftTerm.iosSampleApp1.passwords"

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    static func savePassword(_ password: String, for id: UUID) {
        save(Data(password.utf8), service: service, account: id.uuidString)
    }

    static func password(for id: UUID) -> String? {
        read(service: service, account: id.uuidString)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(query(service: service, account: id.uuidString) as CFDictionary)
    }

    // MARK: - Private keys

    private static let keyService = "org.tirania.SwiftTerm.iosSampleApp1.keys"

    static func saveKey(_ text: String, for id: UUID) {
        save(Data(text.utf8), service: keyService, account: id.uuidString)
    }

    static func key(for id: UUID) -> String? {
        read(service: keyService, account: id.uuidString)
    }

    static func deleteKey(for id: UUID) {
        SecItemDelete(query(service: keyService, account: id.uuidString) as CFDictionary)
    }

    // MARK: - Identity sudo passwords

    private static let identityService = "org.tirania.SwiftTerm.iosSampleApp1.identity"

    static func saveIdentityPassword(_ password: String, for id: UUID) {
        save(Data(password.utf8), service: identityService, account: id.uuidString)
    }

    static func identityPassword(for id: UUID) -> String? {
        read(service: identityService, account: id.uuidString)
    }

    static func deleteIdentityPassword(for id: UUID) {
        SecItemDelete(query(service: identityService, account: id.uuidString) as CFDictionary)
    }

    // MARK: - Shared implementation

    private static func save(_ data: Data, service: String, account: String) {
        let base = query(service: service, account: account)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrSynchronizable as String] = true
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func read(service: String, account: String) -> String? {
        var readQuery = query(service: service, account: account)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
