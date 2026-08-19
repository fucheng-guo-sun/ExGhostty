//
//  PortForwardViewController.swift
//  ExGhostty_iPad
//
//  Full-screen host for the SwiftUI PortForwardListView, pushed with the
//  same slide-from-right transition as SettingsViewController. Closing
//  this window never stops the forwards — they live in PortForwardStore.
//

import UIKit
import SwiftUI

final class PortForwardViewController: UIHostingController<PortForwardListView> {
    init() {
        super.init(rootView: PortForwardListView())
        modalPresentationStyle = .fullScreen
        transitioningDelegate = PushTransitionDelegate.shared
    }

    @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 同 SettingsViewController：手动 hosting controller 不继承深色模式。
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
    }

    /// Pushes the port-forward page full-screen on top of the current
    /// presentation stack.
    static func present() {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(PortForwardViewController(), animated: true)
    }
}
