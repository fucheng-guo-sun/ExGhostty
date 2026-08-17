//
//  ExGhosttyApp.swift
//  ExGhostty_iPad
//
//  App entry. SwiftUI lifecycle (scene-based, per TN3187), dark appearance.
//

import SwiftUI

@main
struct ExGhosttyApp: App {
    init() {
        // Rename-era data migration must run first, before any store loads.
        LegacyDataMigration.run()
        // Must run before the data stores are first touched, so a fresh
        // device can pull remote data before the stores load from defaults.
        ICloudSyncManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .preferredColorScheme(.dark)
        }
    }
}
