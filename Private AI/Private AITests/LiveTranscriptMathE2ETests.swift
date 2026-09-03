import AppKit
import LLMCore
import WebKit
import XCTest
@testable import Private_AI

@MainActor
final class LiveTranscriptMathE2ETests: XCTestCase {
    func testPythagoreanTheoremThroughOllamaAndProductionRenderer() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PRIVATEAI_RUN_LIVE_MATH_E2E"] == "1",
            "Set PRIVATEAI_RUN_LIVE_MATH_E2E=1 with Ollama running to execute this live E2E."
        )
        let model = ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_MODEL"]
            ?? "qwen3.8:27b-mlx"
        let prompt = """
        Give a concise area-based proof of the Pythagorean theorem. Include the conclusion \
        inline, one displayed area equation with a fraction, and the final square-root \
        expression for the hypotenuse. Use mathematical notation, no code fence, and keep \
        the answer under 140 words.
        """
        let runtime = AgentRuntime(
            provider: try OllamaProvider(),
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(
                model: model,
                keepAlive: "-1",
                options: ModelOptions(numContext: 8_192, temperature: 0.2, numPredict: 2_048),
                think: true,
                automaticallyWarmsUp: false
            )
        )

        let result = try await runtime.run(prompt: prompt)
        XCTAssertFalse(result.text.isEmpty)
        let artifactDirectory = try prepareArtifactDirectory(answer: result.text)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 900))
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrivateAI Math Rendering E2E"
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.close() }
        let navigation = LiveMathNavigationWaiter()
        try await navigation.load(
            TranscriptWebView.document,
            baseURL: try XCTUnwrap(TranscriptWebView.resourceBaseURL),
            in: webView
        )
        let messages: [[String: Any]] = [
            transcriptMessage(role: "user", content: prompt),
            transcriptMessage(role: "assistant", content: result.text)
        ]
        let rendered = try await webView.callAsyncJavaScript(
            """
            render(messages);
            await document.fonts.ready;
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            const content = document.querySelector('article.assistant .content');
            return {
              displayCount: content.querySelectorAll('.katex-display').length,
              errorCount: content.querySelectorAll('.katex-error').length,
              fontLoaded: document.fonts.check('16px KaTeX_Main'),
              mathCount: content.querySelectorAll('.katex').length,
              mathMLCount: content.querySelectorAll('.katex-mathml math').length,
              pageHeight: document.documentElement.scrollHeight
            };
            """,
            arguments: ["messages": messages],
            in: nil,
            contentWorld: .page
        )
        let values = try XCTUnwrap(rendered as? [String: Any])
        let mathCount = try XCTUnwrap(values["mathCount"] as? Int)

        XCTAssertGreaterThanOrEqual(mathCount, 3, result.text)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["displayCount"] as? Int), 1)
        XCTAssertEqual(values["mathMLCount"] as? Int, mathCount)
        XCTAssertEqual(values["errorCount"] as? Int, 0)
        XCTAssertEqual(values["fontLoaded"] as? Bool, true)

        let pageHeight = CGFloat(try XCTUnwrap(values["pageHeight"] as? Double))
        window.setContentSize(NSSize(width: 1_100, height: min(max(pageHeight, 900), 1_600)))
        webView.layoutSubtreeIfNeeded()
        await Task.yield()
        let image = try await snapshot(of: webView)
        try write(image: image, to: artifactDirectory.appending(path: "render.png"))
        print("LIVE_MATH model=\(model) answer=\(result.text.debugDescription)")
    }

    private func transcriptMessage(role: String, content: String) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "role": role,
            "content": content,
            "status": "complete",
            "error": "",
            "tool": "",
            "attachments": []
        ]
    }

    private func snapshot(of webView: WKWebView) async throws -> NSImage {
        try await SnapshotRequest().capture(webView)
    }

    private func prepareArtifactDirectory(answer: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "privateai-math-live", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try answer.write(
            to: directory.appending(path: "answer.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    private func write(image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else {
            throw LiveMathE2EError.snapshotUnavailable
        }
        try png.write(to: url, options: .atomic)
    }
}

@MainActor
private final class SnapshotRequest {
    private var continuation: CheckedContinuation<NSImage, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func capture(_ webView: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                resolve(.failure(LiveMathE2EError.snapshotTimedOut))
            }
            webView.takeSnapshot(with: nil) { image, error in
                Task { @MainActor in
                    if let error {
                        self.resolve(.failure(error))
                    } else if let image {
                        self.resolve(.success(image))
                    } else {
                        self.resolve(.failure(LiveMathE2EError.snapshotUnavailable))
                    }
                }
            }
        }
    }

    private func resolve(_ result: Result<NSImage, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}

@MainActor
private final class LiveMathNavigationWaiter: NSObject, WKNavigationDelegate {
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

private enum LiveMathE2EError: Error {
    case snapshotUnavailable
    case snapshotTimedOut
}