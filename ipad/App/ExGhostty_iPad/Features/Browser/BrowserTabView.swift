//
//  BrowserTabView.swift
//  ExGhostty_iPad
//
//  In-app browser tab (WKWebView) opened from a running local port-forward
//  rule's "访问页面" button. Chrome: back / forward / reload-or-stop, an
//  editable address field and a thin progress bar; navigation state is
//  mirrored into BrowserModel via KVO so the SwiftUI bar stays in sync.
//  ATS needs NSAllowsLocalNetworking for cleartext localhost (Info.plist).
//

import SwiftUI
import WebKit

// MARK: - 状态模型

@MainActor
final class BrowserModel: ObservableObject {
    weak var webView: WKWebView?

    @Published var addressText = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reloadOrStop() {
        guard let webView else { return }
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    /// 地址栏回车：无协议头时补 http://（转发场景都是 http）。
    func navigate(to text: String) {
        var target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if !target.contains("://") {
            target = "http://" + target
        }
        guard let url = URL(string: target) else { return }
        webView?.load(URLRequest(url: url))
    }

    /// KVO/导航回调后同步 WebView 状态到地址栏。
    func sync(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
        if let url = webView.url {
            addressText = url.absoluteString
        }
    }
}

// MARK: - Tab 视图

struct BrowserTabView: View {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var model = BrowserModel()

    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            BrowserWebView(initialURL: url, model: model)
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            model.addressText = url.absoluteString
        }
    }

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)

                Button(action: model.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)

                Button(action: model.reloadOrStop) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }

                TextField(L("输入网址"), text: $model.addressText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        model.navigate(to: model.addressText)
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.teal)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.11))

            // 细进度条：不加载时占 2pt 透明位，避免布局跳动。
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(.teal)
                .frame(height: 2)
                .opacity(model.isLoading ? 1 : 0)
        }
    }
}

// MARK: - WKWebView 桥接

private struct BrowserWebView: UIViewRepresentable {
    let initialURL: URL
    let model: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// KVO 监听 WebView 的导航状态，同步给 BrowserModel。
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: BrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel) {
            self.model = model
        }

        func attach(to webView: WKWebView) {
            model.webView = webView
            let sync = { [weak self, weak webView] in
                guard let self, let webView else { return }
                Task { @MainActor in
                    self.model.sync(from: webView)
                }
            }
            observations = [
                webView.observe(\.url) { _, _ in sync() },
                webView.observe(\.canGoBack) { _, _ in sync() },
                webView.observe(\.canGoForward) { _, _ in sync() },
                webView.observe(\.isLoading) { _, _ in sync() },
                webView.observe(\.estimatedProgress) { _, _ in sync() },
            ]
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                model.sync(from: webView)
            }
        }
    }
}
