import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import PrivateAI

@MainActor
final class ConversationWebViewTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []

    func testNativeComposerPastesFinderFileObjectAsAttachment() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-Paste-\(UUID().uuidString).md")
        try Data("# Pasted file".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            NSPasteboard.general.clearContents()
        }
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.writeObjects([file as NSURL]))
        let textView = SendingTextView()
        var pastedURLs: [URL] = []
        textView.onPasteFiles = { pastedURLs = $0 }

        textView.paste(nil)

        XCTAssertEqual(pastedURLs, [file])
        XCTAssertTrue(textView.string.isEmpty)
    }

    func testNativeComposerFocusRequestIsOneShot() throws {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 100)
        )
        let textView = SendingTextView()
        textView.string = "Draft"
        let firstRequest = UUID()
        let secondRequest = UUID()
        let firstHandled = expectation(description: "First focus request handled")
        let secondHandled = expectation(description: "Second focus request handled")
        var handledRequests: [UUID] = []
        textView.onFocusRequestHandled = { requestID in
            handledRequests.append(requestID)
            if requestID == firstRequest { firstHandled.fulfill() }
            if requestID == secondRequest { secondHandled.fulfill() }
        }
        textView.requestFocus(firstRequest)
        XCTAssertTrue(handledRequests.isEmpty)
        scrollView.documentView = textView
        let window = DeferredFirstResponderWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.rejectionsRemaining = 1
        window.contentView = scrollView

        wait(for: [firstHandled], timeout: 1)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertGreaterThanOrEqual(window.makeFirstResponderCallCount, 2)
        XCTAssertEqual(textView.selectedRange().location, textView.string.utf16.count)
        XCTAssertEqual(handledRequests, [firstRequest])

        XCTAssertTrue(window.makeFirstResponder(nil))
        textView.requestFocus(firstRequest)
        XCTAssertFalse(window.firstResponder === textView)
        XCTAssertEqual(handledRequests, [firstRequest])

        textView.requestFocus(secondRequest)
        XCTAssertTrue(window.firstResponder === textView)
        wait(for: [secondHandled], timeout: 1)
        XCTAssertEqual(handledRequests, [firstRequest, secondRequest])
    }

    func testTranscriptRendersOnlyValidRecoveryActions() async throws {
        let webView = try await loadedTranscriptWebView(
            size: NSSize(width: 900, height: 700)
        )
        let invocation = ToolInvocation(
            id: "search-1",
            name: "web_search",
            arguments: ["query": .string("current news")]
        )
        try await renderAsync(
            ConversationTranscriptPayload(
                messages: [
                    ChatMessage(
                        role: .user,
                        content: "Question",
                        attachments: [
                            AttachmentReference(
                                displayName: "research.pdf",
                                kind: .pdf,
                                contentTypeIdentifier: "com.adobe.pdf",
                                byteCount: 1_024,
                                sha256: String(repeating: "a", count: 64),
                                state: .ready,
                                artifact: AttachmentArtifactReceipt(
                                    parserID: "pdfkit-text",
                                    parserVersion: "system",
                                    pageCount: 300,
                                    chunkCount: 300,
                                    characterCount: 20_000
                                )
                            )
                        ]
                    ),
                    ChatMessage(
                        role: .assistant,
                        content: "Complete",
                        responseState: .complete
                    ),
                    ChatMessage(
                        role: .assistant,
                        content: "Partial",
                        responseState: .failed,
                        responseIssue: AssistantResponseIssue(
                            code: .timeout,
                            message: "The request timed out."
                        )
                    ),
                    ChatMessage(
                        role: .assistant,
                        content: "Stopped partial",
                        responseState: .stopped
                    ),
                    ChatMessage(
                        role: .assistant,
                        content: "Using tools",
                        responseState: .complete,
                        toolCalls: [invocation]
                    ),
                    ChatMessage(
                        role: .tool,
                        content: "Result",
                        tool: ToolActivity(
                            name: "web_search",
                            inputSummary: "current news",
                            reason: "This request needs current or external information.",
                            status: .success,
                            detail: "Found one result",
                            invocation: invocation
                        )
                    )
                ],
                transcriptRevision: 1,
                isActive: false
            ),
            in: webView
        )

        let actions = try XCTUnwrap(
            try evaluateString(
                "JSON.stringify([...document.querySelectorAll('.message-action')].map(button => button.dataset.transcriptAction))",
                in: webView
            )
        )
        XCTAssertEqual(actions, #"["edit","regenerate","retry","retry"]"#)
        XCTAssertNil(
            try evaluateString(
                "document.querySelector('[data-message-id=\"\(invocation.id)\"]')?.textContent",
                in: webView
            )
        )
        XCTAssertFalse(
            try XCTUnwrap(
                try evaluateString("document.body.textContent", in: webView)
            ).contains("Using tools")
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.message-attachment strong')?.textContent",
                in: webView
            ),
            "research.pdf"
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.message-attachment span')?.textContent",
                in: webView
            ),
            "300 pages · pdfkit-text"
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.response-issue')?.textContent",
                in: webView
            ),
            "The request timed out."
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.tool-name')?.textContent",
                in: webView
            ),
            "Web search"
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.tool-status')?.textContent",
                in: webView
            ),
            "Complete"
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.tool-reason')?.textContent",
                in: webView
            ),
            "This request needs current or external information."
        )
    }

    func testUserMessageAppearsAndSurvivesAssistantStreamingUpdate() throws {
        _ = NSApplication.shared
        guard let directory = TranscriptWebAssets.availableDirectoryURL() else {
            throw XCTSkip("Transcript web assets are unavailable.")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let copyRecorder = ScriptMessageRecorder()
        configuration.userContentController.add(copyRecorder, name: "copyText")
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderBack(nil)
        Self.retainedWindows.append(window)

        let loaded = expectation(description: "Transcript loaded")
        let waiter = WebLoadWaiter { result in
            if case .failure(let error) = result {
                XCTFail("Transcript failed to load: \(error)")
            }
            loaded.fulfill()
        }
        webView.navigationDelegate = waiter
        webView.loadFileURL(
            directory.appendingPathComponent("transcript.html"),
            allowingReadAccessTo: directory
        )
        wait(for: [loaded], timeout: 5)

        let userID = UUID()
        let assistantID = UUID()
        try render(
            ConversationTranscriptPayload(
                messages: [
                    ChatMessage(
                        id: userID,
                        role: .user,
                        content: "VISIBLE-USER-MESSAGE"
                    ),
                    ChatMessage(
                        id: assistantID,
                        role: .assistant,
                        content: ""
                    )
                ],
                transcriptRevision: 1,
                isActive: true,
                scrollAnchorMessageID: userID
            ),
            in: webView
        )

        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.message-user .user-bubble')?.textContent",
                in: webView
            ),
            "VISIBLE-USER-MESSAGE"
        )
        _ = try evaluateString(
            "document.querySelector('.message-user').dataset.testIdentity = 'preserved'",
            in: webView
        )

        try render(
            ConversationTranscriptPayload(
                messages: [
                    ChatMessage(
                        id: userID,
                        role: .user,
                        content: "VISIBLE-USER-MESSAGE"
                    ),
                    ChatMessage(
                        id: assistantID,
                        role: .assistant,
                        content: "Streaming answer"
                    )
                ],
                transcriptRevision: 2,
                isActive: true,
                scrollAnchorMessageID: userID
            ),
            in: webView
        )

        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.message-user .user-bubble')?.textContent",
                in: webView
            ),
            "VISIBLE-USER-MESSAGE"
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.message-assistant .markdown')?.textContent",
                in: webView
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Streaming answer"
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.message-user')?.dataset.testIdentity",
                in: webView
            ),
            "preserved"
        )

        let secondUserID = UUID()
        let secondAssistantID = UUID()
        let secondUserScrollRequestID = UUID()
        let baseMessages = [
            ChatMessage(
                id: userID,
                role: .user,
                content: "VISIBLE-USER-MESSAGE"
            ),
            ChatMessage(
                id: assistantID,
                role: .assistant,
                content: String(
                    repeating: "A long previous answer paragraph.\n\n",
                    count: 120
                )
            ),
            ChatMessage(
                id: secondUserID,
                role: .user,
                content: "SECOND-USER-MESSAGE"
            )
        ]
        try render(
            ConversationTranscriptPayload(
                messages: baseMessages + [
                    ChatMessage(
                        id: secondAssistantID,
                        role: .assistant,
                        content: ""
                    )
                ],
                transcriptRevision: 3,
                isActive: true,
                scrollAnchorMessageID: secondUserID,
                scrollRequestID: secondUserScrollRequestID
            ),
            in: webView
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let scrollState = try XCTUnwrap(try evaluateString(
            """
            (() => {
              const nodes = Array.from(document.querySelectorAll('.message-user'));
              const target = nodes[nodes.length - 1];
              return JSON.stringify({
                top: target?.getBoundingClientRect().top ?? -1,
                scrollY: window.scrollY
              });
            })()
            """,
            in: webView
        ))
        let state = try JSONDecoder().decode(
            ScrollState.self,
            from: Data(scrollState.utf8)
        )
        XCTAssertGreaterThanOrEqual(state.top, 0)
        XCTAssertLessThan(state.top, 100)
        XCTAssertGreaterThan(state.scrollY, 0)

        for revision in 4...7 {
            try render(
                ConversationTranscriptPayload(
                    messages: baseMessages + [
                        ChatMessage(
                            id: secondAssistantID,
                            role: .assistant,
                            content: String(
                                repeating: "Streaming token batch \(revision). ",
                                count: revision * 20
                            )
                        )
                    ],
                    transcriptRevision: revision,
                    isActive: true,
                    scrollAnchorMessageID: secondUserID,
                    scrollRequestID: secondUserScrollRequestID
                ),
                in: webView
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let afterStreaming = try XCTUnwrap(try evaluateString(
            """
            (() => {
              const nodes = Array.from(document.querySelectorAll('.message-user'));
              const target = nodes[nodes.length - 1];
              return JSON.stringify({
                top: target?.getBoundingClientRect().top ?? -1,
                scrollY: window.scrollY
              });
            })()
            """,
            in: webView
        ))
        let streamedState = try JSONDecoder().decode(
            ScrollState.self,
            from: Data(afterStreaming.utf8)
        )
        XCTAssertEqual(streamedState.scrollY, state.scrollY, accuracy: 1)
        XCTAssertEqual(streamedState.top, state.top, accuracy: 1)

        _ = try evaluateString("window.scrollTo(0, 0); 'ok'", in: webView)
        let repeatedRequestID = UUID()
        try render(
            ConversationTranscriptPayload(
                messages: baseMessages + [
                    ChatMessage(
                        id: secondAssistantID,
                        role: .assistant,
                        content: "Streaming token batch 7."
                    )
                ],
                transcriptRevision: 70,
                isActive: true,
                scrollAnchorMessageID: secondUserID,
                scrollRequestID: repeatedRequestID
            ),
            in: webView
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(
            try evaluateString(
                "document.getElementById('transcript')?.dataset.handledScrollRequestId",
                in: webView
            ),
            repeatedRequestID.uuidString
        )
        let repeatedTopText = try XCTUnwrap(try evaluateString(
            "String(Array.from(document.querySelectorAll('.message-user')).at(-1)?.getBoundingClientRect().top)",
            in: webView
        ))
        let repeatedTop = try XCTUnwrap(Double(repeatedTopText))
        XCTAssertGreaterThanOrEqual(repeatedTop, 0)
        XCTAssertLessThan(repeatedTop, 100)

        webView.setFrameSize(NSSize(width: 500, height: 600))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let compactLayout = try XCTUnwrap(try evaluateString(
            """
            (() => {
              const transcript = document.getElementById('transcript');
              const style = getComputedStyle(transcript);
              return JSON.stringify({
                paddingLeft: parseFloat(style.paddingLeft),
                transcriptWidth: transcript.getBoundingClientRect().width,
                viewportWidth: document.documentElement.clientWidth
              });
            })()
            """,
            in: webView
        ))
        let compactState = try JSONDecoder().decode(
            CompactLayoutState.self,
            from: Data(compactLayout.utf8)
        )
        XCTAssertLessThanOrEqual(compactState.paddingLeft, 12.5)
        XCTAssertLessThanOrEqual(compactState.transcriptWidth, compactState.viewportWidth)

        let successToolID = UUID()
        let failureToolID = UUID()
        let copyableResponse = """
        Finished

        > Please use this exact draft.
        """
        try render(
            ConversationTranscriptPayload(
                messages: baseMessages + [
                    ChatMessage(
                        id: secondAssistantID,
                        role: .assistant,
                        content: copyableResponse
                    ),
                    ChatMessage(
                        id: successToolID,
                        role: .tool,
                        content: "Fetched content",
                        tool: ToolActivity(
                            name: "fetch_url",
                            inputSummary: "https://example.com",
                            status: .success,
                            detail: "Fetched 42 characters"
                        )
                    ),
                    ChatMessage(
                        id: failureToolID,
                        role: .tool,
                        content: "HTTP 403 from example.com.",
                        tool: ToolActivity(
                            name: "web_search",
                            inputSummary: "query",
                            status: .failure,
                            detail: "HTTP 403 from example.com."
                        )
                    )
                ],
                transcriptRevision: 8,
                isActive: false,
                scrollAnchorMessageID: secondUserID
            ),
            in: webView
        )
        XCTAssertEqual(
            try evaluateString(
                "document.querySelector('.tool-card[data-status=\"failure\"] .tool-error')?.textContent",
                in: webView
            ),
            "HTTP 403 from example.com."
        )
        XCTAssertEqual(
            try evaluateString(
                """
                (() => {
                  const button = document.querySelector('.tool-detail-toggle');
                  button?.click();
                  const panel = document.getElementById(button?.getAttribute('aria-controls'));
                  return JSON.stringify({
                    expanded: button?.getAttribute('aria-expanded'),
                    hidden: panel?.hidden,
                    text: panel?.textContent
                  });
                })()
                """,
                in: webView
            ),
            #"{"expanded":"true","hidden":false,"text":"Fetched 42 characters"}"#
        )

        XCTAssertEqual(
            try evaluateString(
                "document.querySelectorAll('.quote-card').length.toString()",
                in: webView
            ),
            "1"
        )
        _ = try evaluateString(
            "document.querySelector('.copy-quote')?.click()",
            in: webView
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(copyRecorder.messages.last, "Please use this exact draft.")

        _ = try evaluateString(
            """
            document.querySelector(
              '[data-message-id="\(secondAssistantID.uuidString)"] .copy-response'
            )?.click()
            """,
            in: webView
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(copyRecorder.messages.last, copyableResponse)

        let nestedMathID = UUID()
        try render(
            ConversationTranscriptPayload(
                messages: [
                    ChatMessage(role: .user, content: "Prove it"),
                    ChatMessage(
                        id: nestedMathID,
                        role: .assistant,
                        content: """
                        1. **Area calculation**
                           The square has area:
                           $$
                           (a + b)^2 = a^2 + 2ab + b^2
                           $$

                        2. Continue the proof with inline $c^2$.
                        """
                    )
                ],
                transcriptRevision: 9,
                isActive: false
            ),
            in: webView
        )
        XCTAssertEqual(
            try evaluateString(
                """
                document.querySelector(
                  '[data-message-id="\(nestedMathID.uuidString)"] .math-display .katex'
                ) ? 'rendered' : 'missing'
                """,
                in: webView
            ),
            "rendered"
        )
        XCTAssertFalse(
            try XCTUnwrap(try evaluateString(
                """
                document.querySelector(
                  '[data-message-id="\(nestedMathID.uuidString)"] .markdown'
                )?.textContent || ''
                """,
                in: webView
            )).contains("$$")
        )
    }

    func testLiveNativeComposerSendRevealsLatestUserMessage() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CHAT_LIVE_SEND_E2E"] == "1" else {
            throw XCTSkip("Set LOCAL_CHAT_LIVE_SEND_E2E=1 to exercise Ollama-backed sending.")
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalChatLiveSend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionStore = try SessionStore(
            directory: temporaryRoot.appendingPathComponent("Sessions", isDirectory: true)
        )
        let memoryStore = try MemoryStore(
            directory: temporaryRoot.appendingPathComponent("Memories", isDirectory: true)
        )
        let logger = try EventLogger(
            directory: temporaryRoot.appendingPathComponent("Logs", isDirectory: true)
        )
        let session = ChatSession(
            title: "Live send scroll test",
            messages: [
                ChatMessage(role: .user, content: "Earlier question"),
                ChatMessage(
                    role: .assistant,
                    content: String(repeating: "Long previous response paragraph.\n\n", count: 160)
                )
            ]
        )
        try await sessionStore.save(session)

        let baseURL = "http://127.0.0.1:11434"
        let localURL = try XCTUnwrap(URL(string: baseURL))
        let viewModel = ChatViewModel(
            baseURL: baseURL,
            selectedModel: "",
            thinkingEnabled: false,
            sessionStore: sessionStore,
            memoryStore: memoryStore,
            logger: logger,
            ollamaClient: OllamaClient(baseURL: localURL),
            profileOllamaClient: OllamaClient(baseURL: localURL),
            memoryOllamaClient: OllamaClient(baseURL: localURL),
            attachmentStore: try AttachmentStore(
                directory: temporaryRoot.appendingPathComponent(
                    "Attachments",
                    isDirectory: true
                )
            )
        )
        try await viewModel.bootstrap()
        guard !viewModel.selectedModel.isEmpty else {
            throw XCTSkip("No local Ollama model is available.")
        }

        let host = NSHostingView(rootView: LiveSendHarness(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 680)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        Self.retainedWindows.append(window)
        try await Task.sleep(for: .milliseconds(500))

        let marker = "LIVE-NATIVE-COMPOSER-SEND-\(UUID().uuidString)"
        viewModel.composerText = marker
        try await Task.sleep(for: .milliseconds(100))
        let textView = try XCTUnwrap(findSubview(of: NSTextView.self, in: host))
        window.makeFirstResponder(textView)
        let returnEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        textView.keyDown(with: returnEvent)

        try await waitUntil(timeout: 3) {
            viewModel.currentSession?.messages.contains {
                $0.role == .user && $0.content == marker
            } == true
        }
        let webView = try XCTUnwrap(findSubview(of: WKWebView.self, in: host))
        try await waitUntil(timeout: 5) {
            let state = try? self.latestUserVisibility(in: webView, marker: marker)
            return state?.text == marker
                && state?.scrollY ?? 0 > 0
                && state?.top ?? -1 >= 0
                && state?.bottom ?? .greatestFiniteMagnitude <= state?.viewportHeight ?? 0
        }

        let state = try latestUserVisibility(in: webView, marker: marker)
        let sentMessageID = try XCTUnwrap(
            viewModel.currentSession?.messages.first {
                $0.role == .user && $0.content == marker
            }?.id
        )
        XCTAssertEqual(viewModel.requestedScrollMessageID, sentMessageID)
        XCTAssertEqual(state.text, marker)
        XCTAssertGreaterThan(
            state.scrollY,
            0,
            "requested=\(state.requestedAnchorID), handled=\(state.handledAnchorID)"
        )
        XCTAssertGreaterThanOrEqual(
            state.top,
            0,
            "requested=\(state.requestedAnchorID), handled=\(state.handledAnchorID)"
        )
        XCTAssertLessThanOrEqual(
            state.bottom,
            state.viewportHeight,
            "requested=\(state.requestedAnchorID), handled=\(state.handledAnchorID)"
        )
        viewModel.stop()
    }

    func testGenerateCommonQueryVisualAuditSnapshots() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "LOCAL_CHAT_VISUAL_AUDIT_DIR"
        ] else {
            throw XCTSkip("Set LOCAL_CHAT_VISUAL_AUDIT_DIR to generate live screenshots.")
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let client = OllamaClient()
        let models = try await client.models()
        let model = try XCTUnwrap(OllamaClient.preferredModel(from: models)?.name)
        let renderPrompt = """
        Return a compact Markdown rendering sample with no introduction. Include five sections: \
        a display-math quadratic formula using $$ delimiters; a three-row GFM table; exactly one \
        fenced Swift code block; exactly one copy-ready single-level blockquote; and a two-level \
        nested Markdown list using hyphens.
        """
        let renderResult = try await client.streamChat(
            model: model,
            messages: [
                LocalChatPrompt.systemMessage(),
                OllamaMessage(role: .user, content: renderPrompt)
            ],
            thinking: false,
            toolsEnabled: false,
            utilityToolsEnabled: false,
            localContextToolsEnabled: false,
            jsonFormat: false,
            onEvent: { _ in }
        )

        let webView = try await loadedTranscriptWebView(
            size: NSSize(width: 1100, height: 760)
        )
        try await renderAsync(
            ConversationTranscriptPayload(
                messages: [
                    ChatMessage(role: .user, content: renderPrompt),
                    ChatMessage(role: .assistant, content: renderResult.content)
                ],
                transcriptRevision: 1,
                isActive: false
            ),
            in: webView
        )
        try await Task.sleep(for: .milliseconds(250))
        let featureState = try XCTUnwrap(try evaluateString(
            """
            JSON.stringify({
              math: document.querySelectorAll('.math-display .katex').length,
              tables: document.querySelectorAll('.table-scroll table').length,
              code: document.querySelectorAll('.code-block').length,
              quotes: document.querySelectorAll('.quote-card').length,
              nestedLists: document.querySelectorAll('li ul, li ol').length,
              overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth
            })
            """,
            in: webView
        ))
        let features = try JSONDecoder().decode(
            VisualFeatureState.self,
            from: Data(featureState.utf8)
        )
        XCTAssertGreaterThanOrEqual(features.math, 1)
        XCTAssertGreaterThanOrEqual(features.tables, 1)
        XCTAssertEqual(features.code, 1)
        XCTAssertEqual(features.quotes, 1)
        XCTAssertGreaterThanOrEqual(features.nestedLists, 1)
        XCTAssertFalse(features.overflow)
        try await captureSnapshot(
            webView,
            at: outputDirectory.appendingPathComponent("common-render-top.png")
        )
        _ = try evaluateString(
            "window.scrollTo(0, document.documentElement.scrollHeight); 'ok'",
            in: webView
        )
        try await Task.sleep(for: .milliseconds(150))
        try await captureSnapshot(
            webView,
            at: outputDirectory.appendingPathComponent("common-render-bottom.png")
        )
        webView.setFrameSize(NSSize(width: 500, height: 760))
        _ = try evaluateString("window.scrollTo(0, 0); 'ok'", in: webView)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            try evaluateString(
                "(document.documentElement.scrollWidth <= document.documentElement.clientWidth).toString()",
                in: webView
            ),
            "true"
        )
        try await captureSnapshot(
            webView,
            at: outputDirectory.appendingPathComponent("common-render-narrow.png")
        )
        webView.setFrameSize(NSSize(width: 1100, height: 760))

        let invocation = ToolInvocation(
            name: "web_search",
            arguments: [
                "query": .string("Apple developer news 2026"),
                "max_results": .number(5)
            ]
        )
        let toolResult = try await WebToolExecutor().execute(invocation)
        let webPrompt = "Briefly summarize current Apple developer news using the supplied search results."
        let webResult = try await client.streamChat(
            model: model,
            messages: [
                LocalChatPrompt.systemMessage(),
                OllamaMessage(role: .user, content: webPrompt),
                OllamaMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        OllamaToolCall(
                            name: invocation.name,
                            arguments: invocation.arguments
                        )
                    ]
                ),
                OllamaMessage(role: .tool, content: toolResult.content)
            ],
            thinking: false,
            toolsEnabled: false,
            utilityToolsEnabled: false,
            localContextToolsEnabled: false,
            jsonFormat: false,
            onEvent: { _ in }
        )
        XCTAssertFalse(webResult.content.localizedCaseInsensitiveContains("Sources:"))
        XCTAssertNil(
            webResult.content.range(
                of: #"https?://[^\s]+"#,
                options: .regularExpression
            )
        )
        try await renderAsync(
            ConversationTranscriptPayload(
                messages: [
                    ChatMessage(role: .user, content: webPrompt),
                    ChatMessage(
                        role: .tool,
                        content: toolResult.content,
                        tool: ToolActivity(
                            name: invocation.name,
                            inputSummary: "Apple developer news 2026",
                            status: .success,
                            detail: toolResult.summary,
                            sources: toolResult.sources
                        )
                    ),
                    ChatMessage(role: .assistant, content: webResult.content)
                ],
                transcriptRevision: 2,
                isActive: false
            ),
            in: webView
        )
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(
            try evaluateString(
                "document.querySelectorAll('.tool-card[data-status=\"success\"]').length.toString()",
                in: webView
            ),
            "1"
        )
        XCTAssertGreaterThan(
            Int(try evaluateString(
                "document.querySelectorAll('.source-chip').length.toString()",
                in: webView
            ) ?? "0") ?? 0,
            0
        )
        _ = try evaluateString("window.scrollTo(0, 0); 'ok'", in: webView)
        try await Task.sleep(for: .milliseconds(150))
        try await captureSnapshot(
            webView,
            at: outputDirectory.appendingPathComponent("web-answer-top.png")
        )
        _ = try evaluateString(
            "window.scrollTo(0, document.documentElement.scrollHeight); 'ok'",
            in: webView
        )
        try await Task.sleep(for: .milliseconds(150))
        try await captureSnapshot(
            webView,
            at: outputDirectory.appendingPathComponent("web-answer-bottom.png")
        )
    }

    private struct ScrollState: Decodable {
        let top: Double
        let scrollY: Double
    }

    private struct CompactLayoutState: Decodable {
        let paddingLeft: Double
        let transcriptWidth: Double
        let viewportWidth: Double
    }

    private struct LatestUserVisibility: Decodable {
        let text: String
        let top: Double
        let bottom: Double
        let viewportHeight: Double
        let scrollY: Double
        let requestedAnchorID: String
        let handledAnchorID: String
    }

    private struct VisualFeatureState: Decodable {
        let math: Int
        let tables: Int
        let code: Int
        let quotes: Int
        let nestedLists: Int
        let overflow: Bool
    }

    private struct LiveSendHarness: View {
        @ObservedObject var viewModel: ChatViewModel

        var body: some View {
            VStack(spacing: 0) {
                ConversationWebView(
                    messages: viewModel.currentSession?.messages ?? [],
                    transcriptRevision: viewModel.transcriptRevision,
                    isActive: viewModel.isStreaming,
                    scrollAnchorMessageID: viewModel.requestedScrollMessageID
                )
                NativeComposerView(text: $viewModel.composerText) {
                    viewModel.send()
                }
                .frame(height: 80)
            }
        }
    }

    private func findSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T {
            return match
        }
        for child in root.subviews {
            if let match = findSubview(of: type, in: child) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for live send state.")
    }

    private func latestUserVisibility(
        in webView: WKWebView,
        marker: String
    ) throws -> LatestUserVisibility {
        let encodedMarker = try JSONEncoder().encode(marker)
        let markerLiteral = try XCTUnwrap(String(data: encodedMarker, encoding: .utf8))
        let json = try XCTUnwrap(try evaluateString(
            """
            (() => {
              const nodes = Array.from(document.querySelectorAll('.message-user'));
              const target = nodes.find(
                (node) => node.querySelector('.user-bubble')?.textContent === \(markerLiteral)
              );
              const rect = target?.getBoundingClientRect();
              return JSON.stringify({
                text: target?.querySelector('.user-bubble')?.textContent || '',
                top: rect?.top ?? -1,
                bottom: rect?.bottom ?? -1,
                viewportHeight: window.innerHeight,
                scrollY: window.scrollY,
                requestedAnchorID:
                  document.getElementById('transcript')?.dataset.requestedScrollAnchorId || '',
                handledAnchorID:
                  document.getElementById('transcript')?.dataset.handledScrollAnchorId || ''
              });
            })()
            """,
            in: webView
        ))
        return try JSONDecoder().decode(
            LatestUserVisibility.self,
            from: Data(json.utf8)
        )
    }

    private func loadedTranscriptWebView(size: NSSize) async throws -> WKWebView {
        let directory = try XCTUnwrap(TranscriptWebAssets.availableDirectoryURL())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: size),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderBack(nil)
        Self.retainedWindows.append(window)

        let loaded = expectation(description: "Visual audit transcript loaded")
        let waiter = WebLoadWaiter { result in
            if case .failure(let error) = result {
                XCTFail("Visual audit transcript failed to load: \(error)")
            }
            loaded.fulfill()
        }
        webView.navigationDelegate = waiter
        webView.loadFileURL(
            directory.appendingPathComponent("transcript.html"),
            allowingReadAccessTo: directory
        )
        await fulfillment(of: [loaded], timeout: 5)
        return webView
    }

    private func renderAsync(
        _ payload: ConversationTranscriptPayload,
        in webView: WKWebView
    ) async throws {
        let data = try ConversationTranscriptEncoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                "renderConversation(payload)",
                arguments: ["payload": object],
                in: nil,
                in: .page
            ) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    private func captureSnapshot(_ webView: WKWebView, at url: URL) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "LocalChatVisualAudit",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "WKWebView returned no snapshot."]
                        )
                    )
                }
            }
        }
        let tiff: Data = try XCTUnwrap(image.tiffRepresentation)
        let representation: NSBitmapImageRep = try XCTUnwrap(
            NSBitmapImageRep(data: tiff)
        )
        let png: Data = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try png.write(to: url, options: .atomic)
    }

    private func render(
        _ payload: ConversationTranscriptPayload,
        in webView: WKWebView
    ) throws {
        let data = try ConversationTranscriptEncoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        let completed = expectation(description: "Conversation rendered")
        var renderError: Error?
        webView.callAsyncJavaScript(
            "renderConversation(payload)",
            arguments: ["payload": object],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                renderError = error
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        if let renderError { throw renderError }
    }

    private func evaluateString(
        _ script: String,
        in webView: WKWebView
    ) throws -> String? {
        let completed = expectation(description: "JavaScript evaluated")
        var output: String?
        var evaluationError: Error?
        webView.evaluateJavaScript(script) { value, error in
            output = value as? String
            evaluationError = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        if let evaluationError { throw evaluationError }
        return output
    }
}

@MainActor
private final class DeferredFirstResponderWindow: NSWindow {
    var rejectionsRemaining = 0
    private(set) var makeFirstResponderCallCount = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCallCount += 1
        if responder != nil, rejectionsRemaining > 0 {
            rejectionsRemaining -= 1
            return false
        }
        return super.makeFirstResponder(responder)
    }
}

private final class ScriptMessageRecorder: NSObject, WKScriptMessageHandler {
    private(set) var messages: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let text = message.body as? String {
            messages.append(text)
        }
    }
}

private final class WebLoadWaiter: NSObject, WKNavigationDelegate {
    private let completion: (Result<Void, Error>) -> Void

    init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        completion(.failure(error))
    }
}
