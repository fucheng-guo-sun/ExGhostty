//
//  Translations.swift
//  ExGhostty_iPad
//
//  English lookup table for L(): keys are the Chinese source strings used
//  in the UI. Missing entries fall back to the Chinese text, so partial
//  coverage degrades gracefully instead of breaking the UI.
//

import Foundation

enum Translations {
    /// English lookup table for L(): the per-area tables below are merged
    /// here. Keys are the Chinese source strings used in the UI; missing
    /// entries fall back to the Chinese text.
    static let en: [String: String] = settings
        .merging(home) { _, new in new }
        .merging(session) { _, new in new }
        .merging(panels) { _, new in new }
        .merging(ai) { _, new in new }

    static let settings: [String: String] = [
        // MARK: 设置页
        "设置": "Settings",
        "完成": "Done",
        "返回": "Back",
        "通用": "General",
        "语言": "Language",
        "语言切换立即生效。": "Language changes take effect immediately.",
        "编辑器": "Editor",
        "SFTP 文件列表中「使用编辑器打开」会在终端里执行该编辑器。":
            "The editor used by SFTP's \"Open with Editor\" runs in the terminal.",
        "外观": "Appearance",
        "主题": "Theme",
        "默认": "Default",
        "主题立即应用到所有打开的终端会话。":
            "Themes apply instantly to all open terminal sessions.",
        "字体": "Font",
        "系统等宽": "System Mono",
        "字号": "Font Size",
        "光标样式": "Cursor Style",
        "光标闪烁": "Cursor Blink",
        "块状": "Block",
        "下划线": "Underline",
        "竖线": "Bar",
        "AI 助手": "AI Assistant",
        "兼容 OpenAI 的 /chat/completions 接口": "Compatible with OpenAI's /chat/completions API",
        "密钥": "Keys",
        "密钥管理": "Key Management",
    ]
}
