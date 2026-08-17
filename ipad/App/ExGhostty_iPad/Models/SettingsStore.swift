//
//  SettingsStore.swift
//  ExGhostty_iPad
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

    /// TerminalFontCatalog 的字体 id；空串 = 系统等宽。
    @Published var terminalFontName: String {
        didSet { defaults.set(terminalFontName, forKey: "terminal.fontName") }
    }

    /// 主题选择（占位：UI 已保留，切换逻辑后续实现）。
    @Published var themeName: String {
        didSet { defaults.set(themeName, forKey: "app.theme") }
    }

    /// 光标样式："block"（默认）/ "underline" / "bar"。
    @Published var terminalCursorStyle: String {
        didSet { defaults.set(terminalCursorStyle, forKey: "terminal.cursorStyle") }
    }

    /// 光标是否闪烁（默认开）。
    @Published var terminalCursorBlink: Bool {
        didSet { defaults.set(terminalCursorBlink, forKey: "terminal.cursorBlink") }
    }

    /// Terminal editor used by SFTP's "open with editor" action.
    /// Raw value of TerminalEditor (see SettingsView).
    @Published var terminalEditor: String {
        didSet { defaults.set(terminalEditor, forKey: "terminal.editor") }
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
        self.terminalFontName = defaults.string(forKey: "terminal.fontName") ?? ""
        self.themeName = defaults.string(forKey: "app.theme") ?? "default"
        self.terminalCursorStyle = defaults.string(forKey: "terminal.cursorStyle") ?? "block"
        // Bool 键未写入过时应默认为 true，不能用 ?? false。
        self.terminalCursorBlink = defaults.object(forKey: "terminal.cursorBlink") as? Bool ?? true
        self.terminalEditor = defaults.string(forKey: "terminal.editor") ?? "vim"
        self.iCloudSyncEnabled = defaults.bool(forKey: "iCloud.syncEnabled")
    }
}
