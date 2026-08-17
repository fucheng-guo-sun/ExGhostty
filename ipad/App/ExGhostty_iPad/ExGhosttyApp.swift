//
//  iOSTerminalApp.swift
//  iOSTerminal
//
//  App entry. SwiftUI lifecycle (scene-based, per TN3187), dark appearance.
//

import SwiftUI

@main
struct iOSTerminalApp: App {
    init() {
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
