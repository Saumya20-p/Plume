import Foundation
import WebKit

@MainActor public class WebViewFetcher: NSObject {
    public static let shared = WebViewFetcher()
    private var activeFetchers: Set<SingleWebViewFetch> = []
    private override init() { super.init() }

    public func fetchHTML(from url: URL) async throws -> String {
        let fetcher = SingleWebViewFetch()
        activeFetchers.insert(fetcher)
        defer { activeFetchers.remove(fetcher) }
        return try await fetcher.fetch(url: url)
    }
}

@MainActor final class SingleWebViewFetch: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var gate: ImportCompletionGate<String>?
    private var timeoutTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var targetURL: URL?

    override init() {
        super.init()
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
    }

    func fetch(url: URL) async throws -> String {
        targetURL = url
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate = ImportCompletionGate(continuation)
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let gate else { return }
        self.gate = nil
        timeoutTask?.cancel()
        renderTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        gate.finish(result)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard gate != nil else { return }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, self.gate != nil else { return }
            guard self.webView.url?.host?.lowercased() == self.targetURL?.host?.lowercased() else {
                self.finish(.failure(URLError(.badURL)))
                return
            }
            self.webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                guard let self else { return }
                if let html = result as? String { self.finish(.success(html)) }
                else { self.finish(.failure(error ?? URLError(.cannotParseResponse))) }
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
