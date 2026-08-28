import SwiftUI
import WebKit

public struct OAuthWebView: NSViewRepresentable {
    public let initialURL: URL
    public let onRedirect: (URL) -> Bool // Returns true if URL handled and webview should close
    public let onCookieExtracted: (([HTTPCookie]) -> Void)?

    public init(
        initialURL: URL,
        onRedirect: @escaping (URL) -> Bool,
        onCookieExtracted: (([HTTPCookie]) -> Void)? = nil
    ) {
        self.initialURL = initialURL
        self.onRedirect = onRedirect
        self.onCookieExtracted = onCookieExtracted
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent() // Isolated session

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        
        let request = URLRequest(url: initialURL)
        webView.load(request)
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: OAuthWebView

        init(parent: OAuthWebView) {
            self.parent = parent
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                if parent.onRedirect(url) {
                    decisionHandler(.cancel)
                    return
                }
            }

            // Extract cookies if requested
            if let cookieExtractor = parent.onCookieExtracted {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cookieExtractor(cookies)
                }
            }

            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let cookieExtractor = parent.onCookieExtracted {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cookieExtractor(cookies)
                }
            }
        }
    }
}

