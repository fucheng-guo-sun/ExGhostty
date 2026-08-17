//
//  KeychainHelper.swift
//  ExGhostty_iPad
//
//  Minimal Keychain wrapper for storing connection passwords and private
//  keys. Items are marked synchronizable (iCloud Keychain); every query
//  must therefore include kSecAttrSynchronizableAny, otherwise reads miss
//  synchronizable items (observed on devices without iCloud signed in:
//  SecItemAdd succeeds, SecItemCopyMatching returns errSecItemNotFound).
//
//  The service names were renamed from the SwiftTerm-sample leftovers
//  (org.tirania.SwiftTerm.iosSampleApp1.*); reads fall back to the legacy
//  service and migrate the item on first access.
//

import Foundation
import Security

enum KeychainHelper {
    /// Current service-name prefix (matches the bundle identifier).
    private static let servicePrefix = "com.xjai.exghostty.ipad"
    /// Legacy prefix from the SwiftTerm sample app; items under it are
    /// migrated to the current service on first read.
    private static let legacyServicePrefix = "org.tirania.SwiftTerm.iosSampleApp1"

    private static let service = "\(servicePrefix).passwords"

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
        delete(service: service, account: id.uuidString)
    }

    // MARK: - Private keys

    private static let keyService = "\(servicePrefix).keys"

    static func saveKey(_ text: String, for id: UUID) {
        save(Data(text.utf8), service: keyService, account: id.uuidString)
    }

    static func key(for id: UUID) -> String? {
        read(service: keyService, account: id.uuidString)
    }

    static func deleteKey(for id: UUID) {
        delete(service: keyService, account: id.uuidString)
    }

    // MARK: - Identity sudo passwords

    private static let identityService = "\(servicePrefix).identity"

    static func saveIdentityPassword(_ password: String, for id: UUID) {
        save(Data(password.utf8), service: identityService, account: id.uuidString)
    }

    static func identityPassword(for id: UUID) -> String? {
        read(service: identityService, account: id.uuidString)
    }

    static func deleteIdentityPassword(for id: UUID) {
        delete(service: identityService, account: id.uuidString)
    }

    // MARK: - Shared implementation

    /// Deletes the item from both the current and the legacy service, so
    /// unmigrated leftovers cannot survive the deletion of a connection.
    private static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
        let legacy = service.replacingOccurrences(of: servicePrefix, with: legacyServicePrefix)
        if legacy != service {
            SecItemDelete(query(service: legacy, account: account) as CFDictionary)
        }
    }

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
        if let value = readDirect(service: service, account: account) {
            return value
        }
        // Fall back to the legacy (SwiftTerm sample) service name and
        // migrate the item into the current service on first access.
        let legacy = service.replacingOccurrences(of: servicePrefix, with: legacyServicePrefix)
        guard legacy != service, let value = readDirect(service: legacy, account: account) else {
            return nil
        }
        save(Data(value.utf8), service: service, account: account)
        SecItemDelete(query(service: legacy, account: account) as CFDictionary)
        return value
    }

    private static func readDirect(service: String, account: String) -> String? {
        var readQuery = query(service: service, account: account)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
