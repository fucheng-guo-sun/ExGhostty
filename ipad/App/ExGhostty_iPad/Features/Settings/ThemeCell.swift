//
//  ThemeCell.swift
//  ExGhostty_iPad
//
//  Settings theme-grid cell. Unlike the Mac version (which ships 16MB of
//  preview PNGs), the preview is drawn live from the theme's own colors:
//  background fill + sample text + the 16 palette swatches.
//

import SwiftUI

struct ThemeCell: View {
    @StateObject private var l10n = LocalizationManager.shared

    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
            Text(theme.id == "default" ? L("默认") : theme.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.teal : Color.primary)
        }
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(uiColor: theme.background))
            .aspectRatio(2.0, contentMode: .fit)
            .overlay {
                VStack(alignment: .leading, spacing: 6) {
                    sampleText
                    Spacer(minLength: 0)
                    paletteRow(Array(theme.palette.prefix(8)))
                    paletteRow(Array(theme.palette.suffix(8)))
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.teal : Color.gray.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.teal)
                        .background(Circle().fill(.black))
                        .padding(4)
                }
            }
    }

    /// 用前景色 + 调色板前 4 色画两行示例文本，近似终端里带语法高亮的样子。
    private var sampleText: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                colorText("$", index: 2)
                colorText("ls -la", color: theme.foreground)
            }
            HStack(spacing: 4) {
                colorText("main", index: 5)
                colorText("README.md", index: 4)
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
    }

    private func colorText(_ text: String, index: Int) -> some View {
        Text(text).foregroundStyle(Color(uiColor: theme.palette[index]))
    }

    private func colorText(_ text: String, color: UIColor) -> some View {
        Text(text).foregroundStyle(Color(uiColor: color))
    }

    private func paletteRow(_ colors: [UIColor]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(uiColor: color))
                    .frame(height: 8)
            }
        }
    }
}

#Preview {
    HStack {
        ThemeCell(theme: TerminalThemeCatalog.defaultTheme, isSelected: true)
        if let theme = TerminalThemeCatalog.all.dropFirst().first {
            ThemeCell(theme: theme, isSelected: false)
        }
    }
    .padding()
    .background(Color.black)
}
