import WebKit
import XCTest
@testable import Private_AI

@MainActor
final class TranscriptMathRenderingTests: XCTestCase {
    func testRendersStandardMathWithBundledResources() async throws {
        let webView = WKWebView()
        let navigation = NavigationWaiter()
        try await navigation.load(
            TranscriptWebView.document,
            baseURL: try XCTUnwrap(TranscriptWebView.resourceBaseURL),
            in: webView
        )

        let result = try await webView.callAsyncJavaScript(
            #"""
            const host = document.createElement('div');
            host.innerHTML = markdown(String.raw`Inline $a^2+b^2=c^2$ and \(x+y\).

            $$\frac{a}{b}$$

            \[\sqrt{2}\]

            Code: ` + '`$notMath$`');
            renderMath(host);
            document.body.appendChild(host);
            await document.fonts.load('16px KaTeX_Main');
            return {
              codeText: host.querySelector('code')?.textContent,
              displayCount: host.querySelectorAll('.katex-display').length,
              errorCount: host.querySelectorAll('.katex-error').length,
              fontLoaded: document.fonts.check('16px KaTeX_Main'),
              mathCount: host.querySelectorAll('.katex').length,
              mathMLCount: host.querySelectorAll('.katex-mathml math').length
            };
            """#,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let values = try XCTUnwrap(result as? [String: Any])

        XCTAssertEqual(values["mathCount"] as? Int, 4)
        XCTAssertEqual(values["displayCount"] as? Int, 2)
        XCTAssertEqual(values["mathMLCount"] as? Int, 4)
        XCTAssertEqual(values["errorCount"] as? Int, 0)
        XCTAssertEqual(values["codeText"] as? String, "$notMath$")
        XCTAssertEqual(values["fontLoaded"] as? Bool, true)
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        fail(with: error)
    }

    private func fail(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}