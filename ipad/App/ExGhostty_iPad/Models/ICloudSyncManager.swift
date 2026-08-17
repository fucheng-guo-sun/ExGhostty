//
//  ICloudSyncManager.swift
//  ExGhostty_iPad
//
//  Syncs two kinds of app data through NSUbiquitousKeyValueStore:
//  connection configs and SSH key metadata.
//  Secrets (passwords / private key material) are NOT synced here —
//  they travel via iCloud Keychain separately.
//
//  Notes on how this interacts with the stores:
//  - The manager reads/writes the same UserDefaults keys the stores use,
//    because ConnectionStore has no replaceAll and must not be modified.
//  - ExGhosttyApp calls `start()` before the stores are initialized, so
//    the first-launch pull lands in UserDefaults before any store loads.
//  - Later remote changes are written to UserDefaults and announced via
//    `didUpdateNotification`; the stores do not observe it, so those
//    changes take effect on next app launch.
//  - When iCloud is unavailable (not signed in), NSUbiquitousKeyValueStore
//    fails silently — all operations here are safe no-ops in that case.
//

import Foundation

final class ICloudSyncManager {
    static let shared = ICloudSyncManager()

    /// Posted after remote changes have been written into UserDefaults.
    static let didUpdateNotification = Notification.Name("exghostty.ipad.iCloudSyncDidUpdate")

    /// Local UserDefaults keys — must stay in sync with
    /// ConnectionStore / SSHKeyStore internals.
    /// Renamed from the legacy "iosterminal.*" keys; LegacyDataMigration
    /// copies old data over on first launch after the rename.
    private enum LocalKey {
        static let connections = "exghostty.ipad.connections"
        static let sshKeys = "exghostty.ipad.sshKeys"
    }

    /// Keys inside the iCloud key-value store.
    private enum CloudKey {
        static let connections = "sync.connections"
        static let sshKeys = "sync.sshKeys"
    }

    /// (cloud key, local key) pairs, in sync order.
    private let pairs: [(cloud: String, local: String)] = [
        (CloudKey.connections, LocalKey.connections),
        (CloudKey.sshKeys, LocalKey.sshKeys),
    ]

    private let defaults = UserDefaults.standard
    private var isObserving = false

    private init() {}

    /// Starts syncing. Safe to call multiple times; does nothing when the
    // iCloud sync setting is off or the kv store is unavailable.
    func start() {
        guard SettingsStore.shared.iCloudSyncEnabled else { return }
        let kvStore = NSUbiquitousKeyValueStore.default

        if !isObserving {
            isObserving = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(storeDidChangeExternally(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: kvStore
            )
        }

        // First launch on a new device: pull remote data only into keys
        // that have no local data yet, so we never clobber local edits.
        // Conversely, push local data up for keys the cloud doesn't have.
        for pair in pairs {
            let remote = kvStore.data(forKey: pair.cloud)
            let local = defaults.data(forKey: pair.local)
            if let remote, local == nil {
                defaults.set(remote, forKey: pair.local)
            } else if remote == nil, let local {
                kvStore.set(local, forKey: pair.cloud)
            }
        }
        kvStore.synchronize()
    }

    /// Stops observing remote changes (called when the setting is turned off).
    func stop() {
        guard isObserving else { return }
        isObserving = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
    }

    /// Pushes the current local data up to iCloud immediately.
    func syncNow() {
        guard SettingsStore.shared.iCloudSyncEnabled else { return }
        let kvStore = NSUbiquitousKeyValueStore.default
        for pair in pairs {
            if let local = defaults.data(forKey: pair.local) {
                kvStore.set(local, forKey: pair.cloud)
            }
        }
        kvStore.synchronize()
    }

    /// Applies remote changes locally: writes the incoming JSON into the
    /// matching UserDefaults keys and posts `didUpdateNotification`.
    /// The stores do not reload on this notification, so the new data
    /// takes effect on next app launch.
    @objc private func storeDidChangeExternally(_ notification: Notification) {
        // Ignore non-server-change reasons (e.g. quota exceeded) silently.
        guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }
        let kvStore = NSUbiquitousKeyValueStore.default
        var didUpdate = false
        for pair in pairs where changedKeys.contains(pair.cloud) {
            if let remote = kvStore.data(forKey: pair.cloud) {
                defaults.set(remote, forKey: pair.local)
            } else {
                defaults.removeObject(forKey: pair.local)
            }
            didUpdate = true
        }
        if didUpdate {
            NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
        }
    }
}
