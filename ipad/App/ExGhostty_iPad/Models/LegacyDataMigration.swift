//
//  LegacyDataMigration.swift
//  ExGhostty_iPad
//
//  One-time migrations for persisted data renamed after the "iOSTerminal"
//  leftovers were cleaned up, plus purges for removed features. Runs from
//  ExGhosttyApp.init() before any store touches UserDefaults. Keychain
//  items are NOT handled here — KeychainHelper migrates them lazily on
//  first read.
//

import Foundation

enum LegacyDataMigration {
    /// (legacy key, current key) pairs in UserDefaults.
    private static let renames: [(old: String, new: String)] = [
        ("iosterminal.connections", "exghostty.ipad.connections"),
        ("iosterminal.sshKeys", "exghostty.ipad.sshKeys"),
    ]

    /// Keys whose feature was removed; their data is deleted outright.
    /// (Port forwarding was dropped from the iPad app.)
    private static let purgedKeys = [
        "iosterminal.portForwardRules",
        "exghostty.ipad.portForwardRules",
    ]

    /// Copies each legacy value to its new key (without clobbering data
    /// already stored under the new key) and removes the legacy key, then
    /// deletes data of removed features. Safe to call on every launch;
    /// a no-op once migration has run.
    static func run() {
        let defaults = UserDefaults.standard
        for pair in renames {
            if let data = defaults.data(forKey: pair.old) {
                if defaults.data(forKey: pair.new) == nil {
                    defaults.set(data, forKey: pair.new)
                }
                defaults.removeObject(forKey: pair.old)
            }
        }
        for key in purgedKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
