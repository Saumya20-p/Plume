import Foundation
import WebKit

@MainActor
public class WebViewFetcher: NSObject {
    public static let shared = WebViewFetcher()
    
    // We retain active fetchers here so they aren't deallocated while fetching
    private var activeFetchers: Set<SingleWebViewFetch> = []
    
    private override init() {
        super.init()
    }
    
    public func fetchHTML(from url: URL) async throws -> String {
        let fetcher = SingleWebViewFetch()
        activeFetchers.insert(fetcher)
        
        defer {
            activeFetchers.remove(fetcher)
        }
        
        return try await fetcher.fetch(url: url)
    }
}

@MainActor
class SingleWebViewFetch: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<String, Error>?
    private var targetURL: URL?
    
    override init() {
        super.init()
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Optional: set a custom user agent so we look like a mobile browser
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
    }
    
    func fetch(url: URL) async throws -> String {
        targetURL = url
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
        }
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Debounce / Ensure we only resume continuation once
        guard continuation != nil else { return }
        
        // Wait a short moment for JS frameworks to finish rendering their DOM
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            guard let cont = self.continuation else { return }
            
            // Sanity check: Ensure the webview didn't navigate completely away from our target URL
            let currentURL = self.webView.url?.absoluteString ?? ""
            _ = self.targetURL?.absoluteString ?? ""
            
            // We do a soft match on the host and path to allow for http/https redirects or trailing slashes
            if let targetHost = self.targetURL?.host, !currentURL.contains(targetHost) {
                // If it navigated to a completely different domain, it's either an ad redirect or a failure.
                // We will just let it scrape whatever is there or fail, but it's safer to fail loudly.
                cont.resume(throwing: URLError(.badURL))
                self.continuation = nil
                return
            }
            
            self.webView.evaluateJavaScript("document.documentElement.outerHTML") { (result, error) in
                if let html = result as? String {
                    cont.resume(returning: html)
                } else {
                    let err = error ?? URLError(.cannotParseResponse)
                    cont.resume(throwing: err)
                }
                self.continuation = nil
            }
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let cont = continuation else { return }
        cont.resume(throwing: error)
        self.continuation = nil
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let cont = continuation else { return }
        cont.resume(throwing: error)
        self.continuation = nil
    }
}
