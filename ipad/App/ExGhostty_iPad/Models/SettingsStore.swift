//
//  SettingsStore.swift
//  iOSTerminal
//
//  App-wide settings persisted in UserDefaults.
//

import Foundation
import Combine

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var aiEndpoint: String {
        didSet { defaults.set(aiEndpoint, forKey: "ai.endpoint") }
    }

    @Published var aiAPIKey: String {
        didSet { defaults.set(aiAPIKey, forKey: "ai.apikey") }
    }

    @Published var aiModel: String {
        didSet { defaults.set(aiModel, forKey: "ai.model") }
    }

    @Published var terminalFontSize: Double {
        didSet { defaults.set(terminalFontSize, forKey: "terminal.fontSize") }
    }

    @Published var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: "iCloud.syncEnabled") }
    }

    init() {
        self.aiEndpoint = defaults.string(forKey: "ai.endpoint") ?? "https://api.openai.com/v1"
        self.aiAPIKey = defaults.string(forKey: "ai.apikey") ?? ""
        self.aiModel = defaults.string(forKey: "ai.model") ?? "gpt-4o-mini"
        let size = defaults.double(forKey: "terminal.fontSize")
        self.terminalFontSize = size > 0 ? size : 13
        self.iCloudSyncEnabled = defaults.bool(forKey: "iCloud.syncEnabled")
    }
}
