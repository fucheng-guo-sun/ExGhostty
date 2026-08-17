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
    }

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .preferredColorScheme(.dark)
        }
    }
}
