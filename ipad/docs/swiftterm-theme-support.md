# SwiftTerm 自定义主题支持调研报告

> 调研对象：`Sources/SwiftTerm/`（本仓库内嵌快照）
> 调研日期：2026-08-18
> 结论先行：**SwiftTerm 没有现成的「主题」抽象，但提供了一整套原子颜色 API，且全部支持运行时动态切换（无需重建视图）。主题系统需要 App 侧自建，接入成本很低。**

## 0. 一个重要前提

这份快照**并非纯上游 migueldeicaza/SwiftTerm**，而是 **meshTerm fork**（见 `Sources/SwiftTerm/iOS/iOSTerminalView.swift:1357` 的自述 "Added by the meshTerm fork (`v1.13.0-meshterm.1`)"）。它比预期的新：已含 Metal 渲染器、`Ansi256PaletteStrategy`（base16Lab 调色板生成）、`selectedTextForegroundColor` 等 API。

## 1. 可配置的颜色 API（iOS 端 `TerminalView`）

全部位于 `Sources/SwiftTerm/iOS/iOSTerminalView.swift`（Mac 端等价物在 `Mac/MacTerminalView.swift`）：

| API | 类型 | 默认值 | 位置 |
|---|---|---|---|
| `nativeForegroundColor` | `UIColor` | 灰 `#8a8a8a`（`Color.defaultForeground`，Colors.swift:36） | iOSTerminalView.swift:1251 |
| `nativeBackgroundColor` | `UIColor` | 黑 → setup 时被改为 `UIColor.clear` | iOSTerminalView.swift:1267, 1231 |
| `caretColor` | `UIColor` | 灰（iOSCaretView.swift:108-110） | iOSTerminalView.swift:1280 |
| `caretTextColor` | `UIColor?` | `nil`（块光标下文字色，nil 用前景色） | iOSTerminalView.swift:1287 |
| `selectedTextBackgroundColor` | `UIColor` | 青绿 `rgb(0,166,178)` | iOSTerminalView.swift:1311-1322 |
| `selectedTextForegroundColor` | `UIColor` | 黑 | iOSTerminalView.swift:1324-1335 |
| `selectionHandleColor` | `UIColor` | `systemBlue`（选区拖把手柄） | iOSTerminalView.swift:1337-1346 |
| `useBrightColors` | `Bool` | `true`（bold 是否映射 bright 8 色） | iOSTerminalView.swift:1293 |
| `installColors(_ colors: [Color])` | 方法 | 安装 16 色 ANSI 调色板 + 刷新 UI | AppleTerminalView.swift:411-416 |
| `terminal.ansi256PaletteStrategy` | `Ansi256PaletteStrategy` | `.base16Lab` | Terminal.swift:547-558；枚举 Colors.swift:12-22 |

引擎层（跨平台 `Terminal` 类）：`foregroundColor` / `backgroundColor`（`SwiftTerm.Color`，didSet 回调 view 并重建调色板，Terminal.swift:514-542）、`cursorColor`（Terminal.swift:561）、`installPalette(colors:)`（Terminal.swift:716-723）。

## 2. 动态切换可行性（关键结论）

颜色消费统一入口是 `mapColor(color:isFg:isBold:)`（AppleTerminalView.swift:327-370），两条渲染路径都在**绘制时实时取色**：

- **CoreGraphics 路径**（当前 App 所用）：`draw(_:)`（iOSTerminalView.swift:1667）→ `getAttributedValue`（AppleTerminalView.swift:469）→ `mapColor`；背景填充直接用 `nativeBackgroundColor`（AppleTerminalView.swift:1448-1458, 1672）。
- **Metal 路径**（`setUseMetal(true)` 开启，当前未用）：`buildAttributedString`（MetalTerminalRenderer.swift:890）同样走 `mapColor`，并直接读 `nativeBackgroundColor`（397, 1062, 1070）、`nativeForegroundColor`（1196, 1264, 1307）、`caretColor`（2173, 2230-2232）。

重绘触发链路完整：

- `colorsChanged()`（AppleTerminalView.swift:390-397）清属性缓存 → `terminal.updateFullScreen()` → `queuePendingDisplay()`（60fps 节流）。
- `installColors` 先清 256 色缓存再 `colorsChanged()`（411-416 行）。
- `nativeForegroundColor` setter → `terminal.foregroundColor` didSet → `colorsChanged()`；`nativeBackgroundColor` setter 直接 `colorsChanged()`（iOSTerminalView.swift:1274）。
- 选区两色 setter 自带 `updateFullScreen + queuePendingDisplay`。

**结论：运行时改色即时全量换肤，无需重建视图。** 唯一缓存（256 色 UIColor 映射、truecolor 字典）会被正确失效。

## 3. 是否存在「主题」抽象

**没有。** 全库无 `Theme` / `ColorPalette` 类型。只有零散属性 + `installColors([Color])`。预置 5 套静态 16 色表（非完整主题）：`paleColors`、`vgaColors`、`terminalAppColors`（Terminal 默认安装，Terminal.swift:679）、`xtermColors`、`defaultInstalledColors`（Colors.swift:49-146）。

**上游也一样**：查了 migueldeicaza/SwiftTerm main 分支完整文件树，至今无主题抽象，颜色 API 与本地快照相同；新增的是 SemanticPrompt、BiDi、PowerlineRenderer 等与主题无关的东西。migueldeicaza 自己的终端 App（SwiftTermApp）也是在 App 层自建主题模型再调这些原子 API。**升级快照拿不到现成主题系统，自建是正确路线。**

## 4. ANSI 16 色 / 256 色 / truecolor

- 16 色（含 bright 8）= `installedColors[16]`，经 `installPalette(colors:)` 修改，**必须恰好 16 个，否则静默不生效**（Terminal.swift:718）。
- 256 色查表：`terminal.ansiColors[256]`（Terminal.swift:450）。前 16 来自 installedColors；16-255 由策略生成：
  - `.xterm`：固定 6×6×6 立方 + 灰阶（Colors.swift:169-190）；
  - `.base16Lab` / `.base16LabHarmonious`：用 16 色 + bg/fg 在 LAB 空间插值（Colors.swift:192-242）——**换 16 色主题后 256 色扩展区自动跟随重算**（当前默认 `.base16Lab`，TerminalOptions）。
- truecolor 不走表，直接 24-bit RGB。
- 文档 bug：`Documentation.docc/Customization.md:43-51` 说 `installPalette` 要 256 色，与代码（16 色）不符。

## 5. Buffer 中颜色的存储方式（决定换主题的波及面）

`Attribute.fg/bg` 是枚举 `Attribute.Color`（CharData.swift:69-102）：`.ansi256(code: UInt8)`（**存索引**）、`.trueColor(r,g,b)`（存 RGB）、`.defaultColor`、`.defaultInvertedColor`；另有 `underlineColor`（115 行）。

换主题时：

- ANSI 索引色（含 scrollback 历史行）→ 渲染时才查表，**全部自动跟着变色**；
- 默认色文本 → 跟随 `nativeForeground/BackgroundColor` 立即变；
- truecolor 内容（TUI 应用等）→ 不变，这是正确行为。

## 6. 光标 / 选区 / 粗斜体

- 光标：`caretColor` + `caretTextColor`；远端 OSC 12 可改（AppleTerminalView.swift:449-467）。
- 选区：`selectedTextBackgroundColor` / `selectedTextForegroundColor` / `selectionHandleColor`。
- 粗体：无独立颜色，仅 `useBrightColors` 开关（bold → bright 色 or 纯加粗字形）。
- 下划线：支持 SGR 58 彩色下划线（`Attribute.underlineColor`），缺省回落前景色。

## 7. 坑位提醒

1. 远端程序可通过转义序列覆盖主题色：OSC 4 重定义单个 ANSI 色（Terminal.swift:2000, 2016），OSC 10/11/12 改默认前景/背景/光标色（2068-2094）。如需主题强制生效，主题切换后要重装一次。
2. `installColors` / `installPalette` 必须传恰好 16 个颜色，多了少了都静默不生效。
3. iOS 端 `nativeBackgroundColor` setup 时是 `UIColor.clear`（靠 layer 背景透出），App 侧主题要同时刷 `terminalView.backgroundColor`（见 App 现状）。

## 8. App 侧现状（接入点）

整个 `App/ExGhostty_iPad/` 只有一处写死颜色，全黑：

- `App/ExGhostty_iPad/TerminalHostViewController.swift:25-29`：`view.backgroundColor = .black`、`terminalView.isOpaque = true`、`terminalView.backgroundColor = .black`、`terminalView.nativeBackgroundColor = .black`。

其余：`SshTerminalView`（SSH/SshTerminalView.swift:108）不设任何颜色；`TerminalFontCatalog` 只管字体；前景色从未设置（一直库默认灰 `#8a8a8a`）；16 色从未设置（一直 `terminalAppColors`）；未开 Metal。

## 9. 接入建议（实现路线）

一个主题 = 一个值类型：

```swift
struct TerminalTheme {
    var foreground: UIColor            // → nativeForegroundColor
    var background: UIColor            // → nativeBackgroundColor + view/terminalView.backgroundColor
    var ansi16: [SwiftTerm.Color]      // 恰好 16 个 → installColors(_:)
    var caret: UIColor                 // → caretColor
    var caretText: UIColor?            // → caretTextColor
    var selectionBackground: UIColor   // → selectedTextBackgroundColor
    var selectionForeground: UIColor   // → selectedTextForegroundColor
}
```

接入方式：在 `TerminalHostViewController` 里对标现有字体 sink 模式（TerminalHostViewController.swift:46-56），对 `SettingsStore` 的主题字段做订阅、逐项赋值即可即时全量换肤，历史行随索引色自动重染。256 色扩展区保持默认 `.base16Lab` 策略即可自动跟随主题。主题预设数据可参考 Mac 版 ghostty 主题或 iTerm2 配色集转换。
