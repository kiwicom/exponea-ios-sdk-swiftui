//
//  WKWebViewHeightCalculator.swift
//  ExponeaSDK
//
//  Created by Ankmara on 07.07.2023.
//  Copyright © 2023 Exponea. All rights reserved.
//

import Foundation
import WebKit
import UIKit

public final class WKWebViewHeightCalculator: WKWebView, WKNavigationDelegate, WKScriptMessageHandler {

    private static let messageHandlerName = "exponeaHeightCalculator"
    private static let heightScriptSource = """
        (function() {
            var pending = false;
            function postHeight() {
                if (pending) { return; }
                pending = true;
                requestAnimationFrame(function() {
                    pending = false;
                    try {
                        var height = Math.max(
                            document.documentElement ? document.documentElement.scrollHeight : 0,
                            document.body ? document.body.scrollHeight : 0
                        );
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.exponeaHeightCalculator) {
                            window.webkit.messageHandlers.exponeaHeightCalculator.postMessage(height);
                        }
                    } catch (e) {}
                });
            }
            if (document.readyState === 'complete') {
                postHeight();
            } else {
                window.addEventListener('load', function() { postHeight(); }, { once: true });
            }
            try {
                var target = document.documentElement || document.body;
                if (target) {
                    var observer = new MutationObserver(function() { postHeight(); });
                    observer.observe(target, { attributes: true, childList: true, subtree: true, characterData: true });
                }
            } catch (e) {}
        })();
        """
    private static let heightScript = WKUserScript(
        source: heightScriptSource,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    // MARK: - Properties
    var defaultPadding: CGFloat = 20
    var heightUpdate: TypeBlock<CalculatorData>?
    public var publicHeightUpdate: TypeBlock<CalculatorData>?
    private var lastReportedHeight: CGFloat?
    private var isReadyForMessages: Bool = false
    private var messageHandler: WeakScriptMessageHandler?
    var id: String = ""
    // Cached so we can recover from `webViewWebContentProcessDidTerminate(_:)`.
    // The calculator never enters a view hierarchy, so iOS does not auto-recover
    // its WebContent process after termination (e.g. while the app is backgrounded
    // with the device locked). Without re-issuing the load explicitly, no
    // `didFinish` reaches `heightUpdate`, the carousel stays pinned at its
    // initial height, and the screen renders empty when the user returns.
    private var lastLoadedHtml: String?

    public init() {
        let userContentController = WKUserContentController()
        userContentController.addUserScript(Self.heightScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        super.init(frame: .init(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 0), configuration: configuration)
        let handler = WeakScriptMessageHandler(delegate: self)
        configuration.userContentController.add(handler, name: Self.messageHandlerName)
        messageHandler = handler
        navigationDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    public func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        guard !IntegrationManager.shared.isStopped else {
            Exponea.logger.log(.error, message: "Method has not been invoked, SDK is stopping")
            self.publicHeightUpdate?(.init(height: 0, placeholderId: ""))
            return
        }
        isReadyForMessages = true
        requestHeight(from: webView, retriesRemaining: 1)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Exponea.logger.log(
            .warning,
            message: "Height calculator WebContent process terminated; reissuing last load for placeholder \(id)"
        )
        isReadyForMessages = false
        lastReportedHeight = nil
        guard let html = lastLoadedHtml, !html.isEmpty else { return }
        // The `webView` parameter here is `self` at runtime (WebKit always passes
        // the receiver as the delegate's webView), but routing the recovery load
        // through the parameter mirrors the cell's recovery path and lets specs
        // substitute a load-recording double in place of the real WebContent IPC.
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func requestHeight(from webView: WKWebView, retriesRemaining: Int) {
        webView.evaluateJavaScript("document.documentElement.scrollHeight || document.body.scrollHeight || 0") { [weak self] result, _ in
            guard let self else { return }
            let jsHeight = (result as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            let contentSizeHeight = webView.scrollView.contentSize.height
            let rawHeight = max(jsHeight, contentSizeHeight)
            if rawHeight > 0 {
                self.reportHeight(rawHeight)
            } else if retriesRemaining > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.requestHeight(from: webView, retriesRemaining: retriesRemaining - 1)
                }
            } else {
                self.reportHeight(contentSizeHeight)
            }
        }
    }

    private func reportHeight(_ rawHeight: CGFloat) {
        let height = rawHeight + defaultPadding
        if let lastReportedHeight, abs(height - lastReportedHeight) < 1 {
            return
        }
        lastReportedHeight = height
        self.heightUpdate?(.init(height: height, placeholderId: id))
        self.publicHeightUpdate?(.init(height: height, placeholderId: id))
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName else { return }
        guard isReadyForMessages else { return }
        guard !IntegrationManager.shared.isStopped else { return }
        if let number = message.body as? NSNumber {
            reportHeight(CGFloat(truncating: number))
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

public extension WKWebViewHeightCalculator {
    func loadHtml(placedholderId: String, html: String) {
        onMain {
            guard !html.isEmpty else {
                self.heightUpdate?(.init(height: 0, placeholderId: placedholderId))
                self.publicHeightUpdate?(.init(height: 0, placeholderId: self.id))
                return
            }
            self.id = placedholderId
            self.lastReportedHeight = nil
            self.isReadyForMessages = false
            self.lastLoadedHtml = html
            self.loadHTMLString(html, baseURL: nil)
        }
    }
}
