//
//  TerminalHostViewController.swift
//  ExGhostty_iPad
//
//  UIKit container hosting a full-size SshTerminalView with keyboard handling.
//  Applies the terminal font / cursor / theme settings (SettingsStore) and
//  re-applies them live when they change — each sink replays the current
//  value immediately, so no separate initial-apply step exists.
//

import UIKit
import Combine
import SwiftTerm

final class TerminalHostViewController: UIViewController {
    private let terminalView = SshTerminalView(frame: .zero)
    private var session: SSHSession?
    private var fontCancellable: AnyCancellable?
    private var cursorCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?

    var hostedTerminalView: SshTerminalView { terminalView }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.isOpaque = true
        terminalView.isOpaque = true
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
        terminalView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        terminalView.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true

        if #available(iOS 15.0, *) {
            view.keyboardLayoutGuide.topAnchor.constraint(equalTo: terminalView.bottomAnchor).isActive = true
        } else {
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        }

        // 初始应用 + 跟随设置变更（sink 会立即回放当前值）。
        let settings = SettingsStore.shared
        fontCancellable = settings.$terminalFontName
            .combineLatest(settings.$terminalFontSize)
            .receive(on: RunLoop.main)
            .sink { [weak self] name, size in
                guard let self else { return }
                TerminalFontCatalog.apply(
                    to: self.terminalView,
                    fontID: name,
                    size: CGFloat(size)
                )
            }
        cursorCancellable = settings.$terminalCursorStyle
            .combineLatest(settings.$terminalCursorBlink)
            .receive(on: RunLoop.main)
            .sink { [weak self] style, blink in
                guard let self else { return }
                let cursorStyle: CursorStyle
                switch (style, blink) {
                case ("underline", true): cursorStyle = .blinkUnderline
                case ("underline", false): cursorStyle = .steadyUnderline
                case ("bar", true): cursorStyle = .blinkBar
                case ("bar", false): cursorStyle = .steadyBar
                case (_, true): cursorStyle = .blinkBlock
                default: cursorStyle = .steadyBlock
                }
                self.terminalView.getTerminal().setCursorStyle(cursorStyle)
            }
        themeCancellable = settings.$themeName
            .receive(on: RunLoop.main)
            .sink { [weak self] themeID in
                guard let self else { return }
                TerminalThemeCatalog.apply(to: self.terminalView, themeID: themeID)
                self.view.backgroundColor = self.terminalView.nativeBackgroundColor
            }

        if let session {
            terminalView.start(with: session)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminalView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        _ = terminalView.resignFirstResponder()
    }

    func configure(session: SSHSession) {
        self.session = session
        if isViewLoaded {
            terminalView.start(with: session)
        }
    }
}
