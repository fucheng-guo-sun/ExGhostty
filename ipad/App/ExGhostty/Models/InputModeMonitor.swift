//
//  InputModeMonitor.swift
//  ExGhostty_iPad
//
//  Publishes a short label for the current text input mode (e.g. "中" /
//  "EN" / "あ") so the session function bar can show which IME is active
//  when typing with a hardware keyboard. The terminal view registers
//  itself as the active responder on becoming first responder (UIKit's
//  UITextInputMode.current() is deprecated; the live mode must be read
//  from the first responder's textInputMode, which lives on UIResponder). Updates are driven by the system
//  UITextInputCurrentInputModeDidChange notification.
//

import UIKit
import Combine

final class InputModeMonitor: ObservableObject {
    static let shared = InputModeMonitor()

    /// The responder currently receiving keystrokes (set by SshTerminalView
    /// on becomeFirstResponder). Weak: dead terminals must not linger.
    /// `textInputMode` lives on UIResponder, not on the UITextInput protocol.
    weak var activeResponder: UIResponder?

    @Published private(set) var label: String = ""

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputModeDidChange),
            name: Notification.Name("UITextInputCurrentInputModeDidChangeNotification"),
            object: nil
        )
    }

    @objc private func inputModeDidChange() {
        // 通知发出时 textInputMode 偶而还是旧值，延迟一拍再读。
        DispatchQueue.main.async {
            self.refresh()
        }
    }

    func refresh() {
        label = Self.label(for: activeResponder?.textInputMode?.primaryLanguage)
    }

    static func label(for language: String?) -> String {
        guard let language else { return "" }
        if language.hasPrefix("zh-Hant") { return "繁" }
        if language.hasPrefix("zh") { return "中" }
        if language.hasPrefix("en") { return "EN" }
        if language.hasPrefix("ja") { return "あ" }
        if language.hasPrefix("ko") { return "한" }
        // 其余语言：取语言码前两个字母大写（如 FR、DE）。
        let code = language.split(separator: "-").first.map(String.init) ?? language
        return String(code.prefix(2)).uppercased()
    }
}
