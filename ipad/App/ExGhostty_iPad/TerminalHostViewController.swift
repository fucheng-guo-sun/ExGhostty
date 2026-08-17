//
//  TerminalHostViewController.swift
//  iOSTerminal
//
//  UIKit container hosting a full-size SshTerminalView with keyboard handling.
//

import UIKit

final class TerminalHostViewController: UIViewController {
    private let terminalView = SshTerminalView(frame: .zero)
    private var session: SSHSession?

    var hostedTerminalView: SshTerminalView { terminalView }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        view.isOpaque = true
        terminalView.isOpaque = true
        terminalView.backgroundColor = .black
        terminalView.nativeBackgroundColor = .black
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
