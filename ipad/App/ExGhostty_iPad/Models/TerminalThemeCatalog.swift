//
//  TerminalThemeCatalog.swift
//  ExGhostty_iPad
//
//  Bundled terminal themes: the 574 ghostty/iTerm2 theme files under
//  `Themes/*.theme` (copied from the desktop repo's zig-out resources,
//  `key = value` text format) plus a synthetic "default" entry matching
//  the library's out-of-box look. Parses lazily, applies to a SwiftTerm
//  TerminalView at runtime (colors re-render live, no view rebuild).
//

import UIKit
import SwiftTerm

struct TerminalTheme: Identifiable {
    /// 主题 id：内置默认为 "default"，其余为主题文件名（去掉 .theme）。
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor
    /// 恰好 16 个（0-7 常规 + 8-15 bright），SwiftTerm installColors 的硬性要求。
    let palette: [UIColor]
    let cursorColor: UIColor?
    let cursorText: UIColor?
    let selectionBackground: UIColor?
    let selectionForeground: UIColor?
}

enum TerminalThemeCatalog {
    /// 内置默认主题：复刻 SwiftTerm 开箱外观（黑底、#8a8a8a 前景、
    /// macOS Terminal.app 调色板——库内 terminalAppColors 是 internal，
    /// 这里复制一份；光标灰、选区青绿同为库默认值）。
    static let defaultTheme = TerminalTheme(
        id: "default", name: "默认",
        background: UIColor(red: 0, green: 0, blue: 0, alpha: 1),
        foreground: UIColor(red: 138 / 255, green: 138 / 255, blue: 138 / 255, alpha: 1),
        palette: [
            0x000000, 0xc23621, 0x25bc24, 0xadad27, 0x492ee1, 0xd338d3, 0x33bbc8, 0xcbcccd,
            0x818383, 0xfc391f, 0x31e722, 0xeaec23, 0x5833ff, 0xf935f8, 0x14f0f0, 0xe9ebeb,
        ].map(Self.rgb(_:)),
        cursorColor: .gray,
        cursorText: nil,
        selectionBackground: UIColor(red: 0, green: 166 / 255, blue: 178 / 255, alpha: 1),
        selectionForeground: .black
    )

    /// 占位时期（UI 先行）存过的旧 id 映射到真实主题，避免老存档失配。
    private static let legacyIDs = [
        "light": "Builtin Light",
        "high-contrast": "Builtin Dark",
    ]

    /// 全部主题：默认 + bundle 内 574 套，按名称排序。首次访问时解析。
    static let all: [TerminalTheme] = {
        var themes = [defaultTheme]
        let urls = Bundle.main.urls(forResourcesWithExtension: "theme", subdirectory: nil) ?? []
        themes += urls.compactMap { parse(url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return themes
    }()

    static func entry(for id: String) -> TerminalTheme {
        let resolved = legacyIDs[id] ?? id
        return all.first { $0.id == resolved } ?? defaultTheme
    }

    /// 把主题应用到终端视图，全部颜色立即生效（历史行随索引色重染）。
    static func apply(to terminal: TerminalView, themeID: String) {
        let theme = entry(for: themeID)
        terminal.backgroundColor = theme.background
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.installColors(theme.palette.map(swiftTermColor(_:)))
        terminal.caretColor = theme.cursorColor ?? theme.foreground
        terminal.caretTextColor = theme.cursorText
        terminal.selectedTextBackgroundColor = theme.selectionBackground ?? theme.foreground
        terminal.selectedTextForegroundColor = theme.selectionForeground ?? theme.background
    }

    // MARK: - 解析 ghostty 主题文件（key = value，# 注释）

    private static func parse(url: URL) -> TerminalTheme? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var palette = [Int: UIColor]()
        var background: UIColor?
        var foreground: UIColor?
        var cursorColor: UIColor?
        var cursorText: UIColor?
        var selectionBackground: UIColor?
        var selectionForeground: UIColor?

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "palette":
                // 形如 "0=#050404"
                let pair = value.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, let index = Int(pair[0]),
                      let color = hex(String(pair[1])) else { continue }
                palette[index] = color
            case "background": background = hex(value)
            case "foreground": foreground = hex(value)
            case "cursor-color": cursorColor = hex(value)
            case "cursor-text": cursorText = hex(value)
            case "selection-background": selectionBackground = hex(value)
            case "selection-foreground": selectionForeground = hex(value)
            default: continue // 其余 ghostty 键（selection-invert 等）忽略
            }
        }

        let ordered = (0 ..< 16).compactMap { palette[$0] }
        guard ordered.count == 16, let background, let foreground else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return TerminalTheme(
            id: name, name: name,
            background: background, foreground: foreground, palette: ordered,
            cursorColor: cursorColor, cursorText: cursorText,
            selectionBackground: selectionBackground, selectionForeground: selectionForeground
        )
    }

    private static func hex(_ string: String) -> UIColor? {
        var value = string
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return rgb(number)
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }

    private static func swiftTermColor(_ color: UIColor) -> SwiftTerm.Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // red8/green8/blue8 的便利构造器是 internal，只能用 0...65535 的公开构造器。
        return SwiftTerm.Color(
            red: UInt16(clamping: Int((red * 65535).rounded())),
            green: UInt16(clamping: Int((green * 65535).rounded())),
            blue: UInt16(clamping: Int((blue * 65535).rounded()))
        )
    }
}
