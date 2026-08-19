//
//  LocalizationManager.swift
//  ExGhostty_iPad
//
//  In-app language switching (简体中文 / 繁體中文 / 日本語 / English). The
//  Chinese source text is used as the lookup key (gettext style): L("中文")
//  returns the Chinese text as-is in Chinese mode, or the entry from the
//  current language's Translations table.
//  Views that render L() strings must observe this manager — the codebase
//  convention is `@StateObject private var l10n = LocalizationManager.shared`
//  — so toggling `language` re-renders them immediately without rebuilding
//  the view tree (which would kill live terminal views).
//

import Foundation

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// "zh-Hans"（默认）或 "en"。
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "app.language") }
    }

    private init() {
        self.language = UserDefaults.standard.string(forKey: "app.language") ?? "zh-Hans"
    }

    var isEnglish: Bool { language == "en" }
}

/// 应用内文案翻译：key 为中文原文；按当前语言查表，缺失时回落中文。
func L(_ key: String) -> String {
    let table: [String: String]
    switch LocalizationManager.shared.language {
    case "en": table = Translations.en
    case "zh-Hant": table = Translations.zhHant
    case "ja": table = Translations.ja
    default: return key
    }
    return table[key] ?? key
}

/// L() 的格式化版本：先翻译 format，再代入参数。
func L(_ format: String, _ args: CVarArg...) -> String {
    String(format: L(format), arguments: args)
}
