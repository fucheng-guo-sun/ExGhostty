//
//  TerminalFontCatalog.swift
//  ExGhostty_iPad
//
//  Bundled terminal fonts (OFL-licensed, copied from the desktop repo's
//  src/font + pkg/freetype resources) and the logic that applies the user's
//  font family / size settings to a SwiftTerm TerminalView. Registered via
//  UIAppFonts in Info.plist; UIFont(name:) uses the PostScript names below.
//

import UIKit
import SwiftTerm

enum TerminalFontCatalog {
    struct Entry: Identifiable {
        /// 空 id 表示系统等宽字体。
        let id: String
        let displayName: String
        /// PostScript 名（与字体文件内嵌一致，不是文件名）。
        let regular: String
        let bold: String?
        let italic: String?
        let boldItalic: String?
    }

    static let system = Entry(
        id: "", displayName: "系统等宽", regular: "",
        bold: nil, italic: nil, boldItalic: nil
    )

    static let all: [Entry] = [
        system,
        Entry(
            id: "jetbrains-mono", displayName: "JetBrains Mono",
            regular: "JetBrainsMonoNF-Regular",
            bold: "JetBrainsMonoNF-Bold",
            italic: "JetBrainsMonoNF-Italic",
            boldItalic: "JetBrainsMonoNF-BoldItalic"
        ),
        // Nerd Font 的 Mono 变体：图标字形收敛为单宽，来自 nerd-fonts 官方
        // 发布包（OFL），桌面仓库未内置，单独下载。
        Entry(
            id: "jetbrains-mono-nfm", displayName: "JetBrainsMono Nerd Font Mono",
            regular: "JetBrainsMonoNFM-Regular",
            bold: "JetBrainsMonoNFM-Bold",
            italic: "JetBrainsMonoNFM-Italic",
            boldItalic: "JetBrainsMonoNFM-BoldItalic"
        ),
        Entry(
            id: "fira-code", displayName: "Fira Code",
            regular: "FiraCode-Regular", bold: nil, italic: nil, boldItalic: nil
        ),
        Entry(
            id: "julia-mono", displayName: "JuliaMono",
            regular: "JuliaMono-Regular", bold: nil, italic: nil, boldItalic: nil
        ),
        Entry(
            id: "monaspace-neon", displayName: "Monaspace Neon",
            regular: "MonaspaceNeon-Regular", bold: nil, italic: nil, boldItalic: nil
        ),
    ]

    static func entry(for id: String) -> Entry {
        all.first { $0.id == id } ?? system
    }

    /// 把字体设置应用到终端视图。自定义字体加载失败时回退系统等宽。
    static func apply(to terminal: TerminalView, fontID: String, size: CGFloat) {
        let entry = entry(for: fontID)
        guard !entry.id.isEmpty else {
            terminal.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            return
        }
        func font(_ name: String?) -> UIFont? {
            guard let name else { return nil }
            return UIFont(name: name, size: size)
        }
        guard let regular = font(entry.regular) else {
            terminal.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            return
        }
        if let bold = font(entry.bold), let italic = font(entry.italic), let boldItalic = font(entry.boldItalic) {
            terminal.setFonts(normal: regular, bold: bold, italic: italic, boldItalic: boldItalic)
        } else {
            // 单字重字体：交给 SwiftTerm 用 descriptor 派生粗体/斜体。
            terminal.font = regular
        }
    }
}
