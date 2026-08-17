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
        "iCloud 同步": "iCloud Sync",
        "编辑器": "Editor",
        "SFTP 文件列表中「使用编辑器打开」会在终端里执行该编辑器。":
            "The editor used by SFTP's \"Open with Editor\" runs in the terminal.",
        "外观": "Appearance",
        "主题": "Theme",
        "默认深色": "Default Dark",
        "浅色": "Light",
        "高对比度": "High Contrast",
        "主题切换即将推出，当前始终使用深色主题。":
            "Theme switching is coming soon; the dark theme is always used for now.",
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
        "开启同步": "Enable Sync",
        "立即同步": "Sync Now",
        "连接配置和密钥元数据通过 iCloud 键值存储同步；密码与私钥通过 iCloud 钥匙串同步。其他设备上的变更将在下次启动时生效。":
            "Connection configs and key metadata sync via iCloud Key-Value Storage; passwords and private keys via iCloud Keychain. Changes from other devices take effect on the next launch.",
    ]
}
