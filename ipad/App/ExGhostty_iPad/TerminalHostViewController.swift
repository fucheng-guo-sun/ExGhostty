//
//  TerminalHostViewController.swift
//  ExGhostty_iPad
//
//  UIKit container hosting a full-size SshTerminalView with keyboard handling.
//  The terminal fills the whole view (bottom edge included); software-keyboard
//  avoidance is done by adjusting the bottom constraint from
//  keyboardWillChangeFrameNotification — keyboardLayoutGuide would leave a
//  safe-area-sized blank strip at the bottom when no keyboard is up.
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
    /// 终端到底部的约束：无键盘时贴满屏幕底边，键盘弹出时抬高避让
    /// （keyboardLayoutGuide 在键盘隐藏时会停在安全区上沿，底部留一条空白）。
    private var bottomConstraint: NSLayoutConstraint?

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

        let bottom = terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottom.isActive = true
        bottomConstraint = bottom

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        // 锁屏/后台会杀死 SSH 连接，回到前台时按需重连。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

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

    @objc private func appDidBecomeActive() {
        terminalView.attemptReconnect()
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let endInView = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - endInView.minY)
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        bottomConstraint?.constant = -overlap
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
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
