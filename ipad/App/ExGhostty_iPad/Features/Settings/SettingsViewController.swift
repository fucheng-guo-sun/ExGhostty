//
//  SettingsViewController.swift
//  ExGhostty_iPad
//
//  Full-screen host for the SwiftUI SettingsView, pushed with a custom
//  slide-from-right transition (the app's root has no UINavigationController
//  to push onto). Two gotchas handled here: the manually created hosting
//  controller does not inherit the root view's forced dark mode, so
//  overrideUserInterfaceStyle must be set or the sidebar flashes light;
//  and the view is black-backed to avoid a white flash mid-transition.
//  The Done button inside SettingsView dismisses via the environment.
//

import UIKit
import SwiftUI

final class SettingsViewController: UIHostingController<SettingsView> {
    init() {
        super.init(rootView: SettingsView())
        modalPresentationStyle = .fullScreen
        transitioningDelegate = PushTransitionDelegate.shared
    }

    @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 手动创建的 hosting controller 不继承根视图的 .preferredColorScheme(.dark)，
        // 必须显式指定，否则 List 等区域在显示完成后回落成浅色样式。
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
    }

    /// Pushes the settings page full-screen on top of the current
    /// presentation stack.
    static func present() {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(SettingsViewController(), animated: true)
    }
}

// MARK: - Push 转场

/// 模拟 UINavigationController push 的转场：新页面从右侧滑入覆盖，关闭时向右滑出。
private final class PushTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = PushTransitionDelegate()

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        PushTransitionAnimator(presenting: true)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        PushTransitionAnimator(presenting: false)
    }
}

private final class PushTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(presenting: Bool) {
        self.isPresenting = presenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.3
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let fromVC = context.viewController(forKey: .from),
              let toVC = context.viewController(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        let frame = context.finalFrame(for: toVC)

        if isPresenting {
            container.addSubview(toVC.view)
            toVC.view.frame = frame.offsetBy(dx: frame.width, dy: 0)
            UIView.animate(
                withDuration: transitionDuration(using: context),
                delay: 0,
                options: .curveEaseOut
            ) {
                toVC.view.frame = frame
            } completion: { finished in
                context.completeTransition(finished)
            }
        } else {
            container.insertSubview(toVC.view, at: 0)
            fromVC.view.frame = frame
            UIView.animate(
                withDuration: transitionDuration(using: context),
                delay: 0,
                options: .curveEaseOut
            ) {
                fromVC.view.frame = frame.offsetBy(dx: frame.width, dy: 0)
            } completion: { finished in
                context.completeTransition(finished)
            }
        }
    }
}
