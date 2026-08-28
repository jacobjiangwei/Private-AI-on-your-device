import CoreLocation
import Foundation
import XCTest
@testable import PrivateAI

final class LocalChatCoreTests: XCTestCase {
    func testSessionPersistenceRoundTripAndDelete() async throws {
        let directory = try scratchDirectory(named: "sessions")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(
            title: "Persisted",
            createdAt: timestamp,
            updatedAt: timestamp,
            messages: [
                ChatMessage(role: .user, content: "Hello", timestamp: timestamp),
                ChatMessage(role: .assistant, content: "Hi", timestamp: timestamp)
            ]
        )

        try await store.save(session)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, [session])
        try await store.delete(id: session.id)
        let afterDelete = try await store.load()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testSessionStoreRejectsStaleSnapshotsAndPostDeleteWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-SessionOrdering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(directory: directory)
        let id = UUID()
        let newer = ChatSession(
            id: id,
            title: "Newer",
            messages: [ChatMessage(role: .assistant, content: "FINAL")]
        )
        let stale = ChatSession(
            id: id,
            title: "Stale",
            messages: [ChatMessage(role: .assistant, content: "PARTIAL")]
        )

        try await store.save(newer, revision: 2)
        try await store.save(stale, revision: 1)
        let afterStaleWrite = try await store.load()
        XCTAssertEqual(afterStaleWrite.first?.title, "Newer")
        XCTAssertEqual(afterStaleWrite.first?.messages.first?.content, "FINAL")

        try await store.delete(id: id, revision: 3)
        try await store.save(newer, revision: 4)
        let afterLateWrite = try await store.load()
        XCTAssertTrue(afterLateWrite.isEmpty)
    }

    func testSessionStoreReconcilesDurableDeletionBeforeLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-SessionDeleteRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ChatSession(
            title: "Must stay deleted",
            messages: [ChatMessage(role: .user, content: "Sensitive")]
        )
        var store: SessionStore? = try SessionStore(directory: directory)
        try await store?.save(session)
        store = nil
        let marker = directory
            .appendingPathComponent("Deleted", isDirectory: true)
            .appendingPathComponent(session.id.uuidString)
        try Data().write(to: marker, options: .atomic)

        let reopened = try SessionStore(directory: directory)
        let loaded = try await reopened.load()

        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent(session.id.uuidString)
                    .appendingPathExtension("json").path
            )
        )
    }

    func testLegacySessionJSONDecodesWithoutRecoveryMetadata() throws {
        let json = """
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "title":"Legacy",
          "createdAt":0,
          "updatedAt":0,
          "messages":[{
            "id":"00000000-0000-0000-0000-000000000002",
            "role":"assistant",
            "content":"Old answer",
            "timestamp":0
          }]
        }
        """

        let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))

        XCTAssertNil(session.fork)
        XCTAssertNil(session.messages.first?.responseState)
        XCTAssertNil(session.messages.first?.toolCalls)
        XCTAssertNil(session.messages.first?.responseIssue)
        XCTAssertNil(session.messages.first?.contextReceipt)
    }

    func testRecoveryAndToolMetadataRoundTrips() throws {
        let parentID = UUID()
        let sourceID = UUID()
        let invocation = ToolInvocation(
            id: "search-1",
            name: "web_search",
            arguments: ["query": .string("Ollama news")]
        )
        let receipt = ContextReceipt(
            contextWindow: 32_768,
            outputReserve: 4_096,
            estimatedPromptTokens: 2_000,
            actualPromptTokens: 1_900,
            fullTurns: 3,
            compactedTurns: 1,
            omittedTurns: 2,
            memoryRecords: 2,
            toolPairs: 1
        )
        let session = ChatSession(
            title: "Fork",
            messages: [
                ChatMessage(role: .user, content: "Research"),
                ChatMessage(
                    role: .assistant,
                    content: "Partial",
                    responseState: .failed,
                    toolCalls: [invocation],
                    responseIssue: AssistantResponseIssue(
                        code: .timeout,
                        message: "Timed out"
                    ),
                    contextReceipt: receipt
                ),
                ChatMessage(
                    role: .tool,
                    content: "Result",
                    tool: ToolActivity(
                        name: invocation.name,
                        inputSummary: "Ollama news",
                        status: .success,
                        invocation: invocation
                    )
                )
            ],
            fork: SessionFork(
                parentSessionID: parentID,
                parentTitle: "Parent",
                sourceMessageID: sourceID,
                reason: .retry
            )
        )

        let decoded = try JSONDecoder().decode(
            ChatSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(decoded, session)
    }

    func testMemorySelectionHonorsRecordAndCharacterBounds() {
        let now = Date(timeIntervalSince1970: 2_000)
        let records = [
            MemoryRecord(createdAt: now, sessionID: UUID(), summary: "User prefers concise Swift examples"),
            MemoryRecord(createdAt: now.addingTimeInterval(-10), sessionID: UUID(), summary: "User owns a red bicycle"),
            MemoryRecord(createdAt: now.addingTimeInterval(-20), sessionID: UUID(), summary: "Swift concurrency matters")
        ]

        let selected = MemoryStore.boundedRelevant(
            records,
            query: "Help with Swift concurrency",
            maximumRecords: 2,
            maximumCharacters: 60
        )

        XCTAssertLessThanOrEqual(selected.count, 2)
        XCTAssertLessThanOrEqual(selected.reduce(0) { $0 + $1.summary.count }, 60)
        XCTAssertTrue(selected.first?.summary.contains("Swift") == true)
    }

    func testSessionListTimestampIsStaticAndCalendarBased() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-26T14:55:00Z")
        )
        let today = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-26T09:30:00Z")
        )
        let yesterday = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-25T23:59:00Z")
        )
        let older = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z")
        )

        let todayLabel = SessionListPresentation.updatedTimestamp(
            for: today,
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(todayLabel.contains("ago"))
        XCTAssertFalse(todayLabel.contains("sec"))
        XCTAssertEqual(
            SessionListPresentation.updatedTimestamp(
                for: yesterday,
                now: now,
                calendar: calendar
            ),
            "Yesterday"
        )
        XCTAssertFalse(
            SessionListPresentation.updatedTimestamp(
                for: older,
                now: now,
                calendar: calendar
            ).isEmpty
        )
    }

    func testURLSafetyRejectsLocalPrivateAndNonHTTP() throws {
        XCTAssertThrowsError(try URLSafety.validate("http://localhost:8080", resolveDNS: false))
        XCTAssertThrowsError(try URLSafety.validate("http://192.168.1.20/page"))
        XCTAssertThrowsError(try URLSafety.validate("file:///etc/hosts", resolveDNS: false))
        XCTAssertNoThrow(try URLSafety.validate("https://example.com/path", resolveDNS: false))
    }

    func testToolPolicyValidatesModelSelectedActionsAndEvidence() throws {
        XCTAssertEqual(
            ToolPolicy.modelActionToolNames,
            [
                "local_context", "local_search", "web_search",
                "fetch_url", "code_interpreter"
            ]
        )

        let localSearch = try ToolPolicy.validateModelInvocation(
            ToolInvocation(
                name: "local_search",
                arguments: [
                    "query": .string("  餐馆  "),
                    "radius_km": .number(500),
                    "max_results": .number(50)
                ]
            ),
            for: "我附近的餐馆有什么推荐吗"
        )
        XCTAssertEqual(localSearch.arguments["query"]?.stringValue, "餐馆")
        XCTAssertEqual(localSearch.arguments["radius_km"]?.numberValue, 50)
        XCTAssertEqual(localSearch.arguments["max_results"]?.integerValue, 12)

        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "local_search",
                    arguments: ["query": .string("餐馆")]
                ),
                for: "不要获取我的位置，只翻译‘附近餐馆’"
            )
        ) { error in
            guard case ToolPolicy.InvocationValidationError.blockedLocationActivation = error
            else { return XCTFail("Expected location activation to be blocked") }
        }

        let localContext = try ToolPolicy.validateModelInvocation(
            ToolInvocation(
                name: "local_context",
                arguments: [
                    "fields": .array([.string("time"), .string("time"), .string("power")])
                ]
            ),
            for: "What time is it and what is my battery level?"
        )
        XCTAssertEqual(
            localContext.arguments["fields"]?.arrayValue,
            [.string("time"), .string("power")]
        )
        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "local_context",
                    arguments: ["fields": .array([.string("contacts")])]
                ),
                for: "Read my contacts"
            )
        )

        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "web_search",
                    arguments: ["query": .string("private attachment contents")]
                ),
                for: "Summarize this attached file",
                hasAttachments: true
            )
        ) { error in
            guard case ToolPolicy.InvocationValidationError
                .externalAttachmentRetrievalNotAuthorized = error else {
                return XCTFail("Expected attachment-derived web retrieval to be blocked")
            }
        }
        XCTAssertNoThrow(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "web_search",
                    arguments: ["query": .string("current public release notes")]
                ),
                for: "Compare this attachment with current public release notes; search the web",
                hasAttachments: true
            )
        )

        let webSearch = try ToolPolicy.validateModelInvocation(
            ToolInvocation(
                name: "web_search",
                arguments: [
                    "query": .string("current Swift release"),
                    "max_results": .number(99)
                ]
            ),
            for: "What is the current Swift release?"
        )
        XCTAssertEqual(webSearch.arguments["max_results"]?.integerValue, 8)
        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "web_search",
                    arguments: ["query": .string("/Users/example/private.md")]
                ),
                for: "Search this"
            )
        )

        XCTAssertNoThrow(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "fetch_url",
                    arguments: ["url": .string("https://example.com/article")]
                ),
                for: "Summarize this URL"
            )
        )
        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "fetch_url",
                    arguments: ["url": .string("http://localhost:8080/private")]
                ),
                for: "Read this URL"
            )
        )

        XCTAssertNoThrow(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "code_interpreter",
                    arguments: ["expression": .string("(37 * 19) - 44")]
                ),
                for: "Calculate it"
            )
        )
        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "code_interpreter",
                    arguments: ["expression": .string(#""Find restaurants near me""#)]
                ),
                for: "Translate 'Find restaurants near me' into Chinese"
            )
        )
        XCTAssertThrowsError(
            try ToolPolicy.validateModelInvocation(
                ToolInvocation(
                    name: "code_interpreter",
                    arguments: [
                        "expression": .string(
                            #""Find restaurants near me".replace("Find", "查找")"#
                        )
                    ]
                ),
                for: "Translate 'Find restaurants near me' into Chinese"
            )
        )

        XCTAssertNotNil(
            ToolPolicy.unsupportedToolClaim(
                in: "根据 Apple Maps，你附近有三家餐馆。",
                successfulTools: []
            )
        )
        XCTAssertNil(
            ToolPolicy.unsupportedToolClaim(
                in: "根据 Apple Maps，你附近有三家餐馆。",
                successfulTools: ["local_search"]
            )
        )

        let localFilePrompt = """
        /Users/example/Documents/Project/word-online-snapshot.md
        读一下文件
        """
        XCTAssertEqual(
            ToolPolicy.localFilePaths(in: localFilePrompt),
            ["/Users/example/Documents/Project/word-online-snapshot.md"]
        )
        XCTAssertEqual(
            ToolPolicy.promptByRemovingLocalFilePaths(localFilePrompt)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "读一下文件"
        )
        XCTAssertFalse(
            ToolPolicy.shouldRequestJSONFormat(
                for: "/Users/example/Documents/valid-json-only.md\nRead this file"
            )
        )
        XCTAssertTrue(
            ToolPolicy.shouldRequestJSONFormat(
                for: "Return only one valid JSON object"
            )
        )
        XCTAssertFalse(
            ToolPolicy.shouldRequestJSONFormat(
                for: "Explain JSON parsing in Swift"
            )
        )
    }

    func testCodeInterpreterHandlesMathAndDataWithoutStatements() async throws {
        XCTAssertEqual(
            try CodeInterpreterTool.evaluate("(37 * 19) - 44"),
            "659"
        )
        XCTAssertEqual(
            try CodeInterpreterTool.evaluate("sum([2, 3, 4])"),
            "9"
        )
        XCTAssertEqual(
            try CodeInterpreterTool.evaluate("mean([1, 2, 3, 4])"),
            "2.5"
        )
        XCTAssertEqual(
            try CodeInterpreterTool.evaluate(#"JSON.stringify({status: "ok", value: 4})"#),
            #"{"status":"ok","value":4}"#
        )
        XCTAssertThrowsError(
            try CodeInterpreterTool.evaluate("while (true) {}")
        )
        XCTAssertThrowsError(
            try CodeInterpreterTool.evaluate("'x'.repeat(1000000)")
        )
        let toolResult = try await WebToolExecutor().execute(ToolInvocation(
            name: "code_interpreter",
            arguments: ["expression": .string("6 * 7")]
        ))
        XCTAssertEqual(toolResult.content, "42")
    }

    func testLiveGenerationMeterUsesEstimateThenExactMetrics() {
        var meter = LiveGenerationMeter()
        meter.beginRound()
        let started = Date(timeIntervalSince1970: 1_000)
        _ = meter.ingest(characterCount: 40, at: started)
        let live = meter.ingest(
            characterCount: 40,
            at: started.addingTimeInterval(2)
        )
        XCTAssertEqual(live.totalTokens, 20)
        XCTAssertEqual(live.tokensPerSecond, 10, accuracy: 0.001)

        let exact = meter.finishRound(
            exactTokens: 18,
            evaluationDurationNanoseconds: 1_500_000_000
        )
        XCTAssertEqual(exact.totalTokens, 18)
        XCTAssertEqual(exact.tokensPerSecond, 12, accuracy: 0.001)

        meter.beginRound()
        let next = meter.ingest(
            characterCount: 16,
            at: started.addingTimeInterval(3)
        )
        XCTAssertEqual(next.totalTokens, 22)
    }

    func testDuckDuckGoFixtureParsing() throws {
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "duckduckgo",
                withExtension: "html",
                subdirectory: "Fixtures"
            ) ?? Bundle(for: Self.self).url(
                forResource: "duckduckgo",
                withExtension: "html"
            )
        )
        let html = try String(contentsOf: fixture, encoding: .utf8)
        let results = DuckDuckGoParser.parse(html, limit: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Swift Programming Language")
        XCTAssertEqual(results[0].url, "https://www.swift.org/")
        XCTAssertEqual(results[1].snippet, "A second bounded result.")
    }

    func testDuckDuckGoLiteMarkupParsing() {
        let html = """
        <html><body>
          <a rel='nofollow' href='//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2F'
             class='result-link'>Apple &amp; Developer</a>
          <td class='result-snippet'>Official <b>developer</b> documentation.</td>
        </body></html>
        """
        let results = DuckDuckGoParser.parse(html, limit: 1)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Apple & Developer")
        XCTAssertEqual(results[0].url, "https://developer.apple.com/")
        XCTAssertEqual(results[0].snippet, "Official developer documentation.")
    }

    func testMarkdownBlockParser() {
        let markdown = """
        # Heading

        Paragraph with **bold**.

        - One
        - Two

        > Quoted

        ```swift
        print("hello")
        ```

        ---
        """

        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [
                .heading(level: 1, text: "Heading"),
                .paragraph("Paragraph with **bold**."),
                .list(ordered: false, items: ["One", "Two"]),
                .quote("Quoted"),
                .code(language: "swift", content: "print(\"hello\")"),
                .rule
            ]
        )
    }

    func testMarkdownTableParserWithAlignmentAndInlineFormatting() {
        let markdown = """
        | 项目 | 情况 | 温度 |
        | :--- | :---: | ---: |
        | 天气 | **多云** | `29°C` |
        | 湿度 | 93% |  |
        """

        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [
                .table(
                    headers: ["项目", "情况", "温度"],
                    alignments: [.leading, .center, .trailing],
                    rows: [
                        ["天气", "**多云**", "`29°C`"],
                        ["湿度", "93%", ""]
                    ]
                )
            ]
        )
    }

    func testMarkdownMathBlockAndInlineParser() {
        XCTAssertEqual(
            MarkdownBlockParser.parse(
                """
                Before

                $$\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$$
                """
            ),
            [
                .paragraph("Before"),
                .math(#"\frac{-b \pm \sqrt{b^2-4ac}}{2a}"#)
            ]
        )
        XCTAssertEqual(
            InlineMathParser.parse(
                #"平方根是 $\sqrt{16}=4$，价格是 \$5。"#
            ),
            [
                .text("平方根是 "),
                .math(#"\sqrt{16}=4"#),
                .text("，价格是 $5。")
            ]
        )
        XCTAssertEqual(
            InlineMathParser.parse("unfinished $x + 1"),
            [.text("unfinished $x + 1")]
        )
    }

    func testConversationTranscriptPayloadSafeJSONRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = ConversationTranscriptPayload(
            messages: [
                ChatMessage(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    role: .user,
                    content: "Quotes: \"hello\"\nUnicode: 你好 👋\n</script>",
                    timestamp: timestamp
                ),
                ChatMessage(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    role: .tool,
                    content: "raw\nresult",
                    timestamp: timestamp,
                    tool: ToolActivity(
                        name: "web_search",
                        inputSummary: "query \"Swift 6\"\nlimit 3",
                        status: .success,
                        detail: "Found: café ☕️",
                        sources: [
                            SourceLink(
                                title: "Swift \"Docs\"",
                                url: "https://example.com/a?x=1&y=%E4%B8%AD"
                            )
                        ]
                    )
                )
            ],
            transcriptRevision: 42,
            isActive: true
        )

        let encoded = try ConversationTranscriptEncoder.encode(payload)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(jsonObject))
        XCTAssertEqual(
            try JSONDecoder().decode(ConversationTranscriptPayload.self, from: encoded),
            payload
        )
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains(#"\"hello\""#))
        XCTAssertTrue(json.contains("你好"))
        XCTAssertTrue(json.contains("\\n"))
    }

    func testOfflineTranscriptAssetsAndRendererWiring() throws {
        let webDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PrivateAI/Web", isDirectory: true)
        let requiredFiles = [
            "transcript.html",
            "transcript.css",
            "transcript.js",
            "vendor.js",
            "katex.min.css",
            "katex-LICENSE",
            "markdown-it-LICENSE",
            "highlight.js-LICENSE",
            "dompurify-LICENSE"
        ]
        for path in requiredFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: webDirectory.appendingPathComponent(path).path
                ),
                "Missing offline transcript asset: \(path)"
            )
        }

        let html = try String(
            contentsOf: webDirectory.appendingPathComponent("transcript.html"),
            encoding: .utf8
        )
        let script = try String(
            contentsOf: webDirectory.appendingPathComponent("transcript.js"),
            encoding: .utf8
        )
        XCTAssertTrue(html.contains("katex.min.css"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(script.contains("html: false"))
        XCTAssertTrue(script.contains("vendors.DOMPurify.sanitize"))
        XCTAssertTrue(script.contains("vendors.katex.renderToString"))
        XCTAssertTrue(script.contains("vendors.hljs.highlight"))
        XCTAssertTrue(script.contains("window.renderConversation"))

        let fonts = try FileManager.default.contentsOfDirectory(
            at: webDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(fonts.contains { $0.pathExtension == "woff2" })
    }

    func testToolCallAccumulationAcrossChunks() {
        var accumulator = ToolCallAccumulator()
        accumulator.append(
            ToolCallDelta(
                index: 0,
                id: "abc",
                nameFragment: "web_",
                argumentsFragment: #"{"query":""#
            )
        )
        accumulator.append(
            ToolCallDelta(
                index: 0,
                nameFragment: "search",
                argumentsFragment: #"Swift 6","max_results":3}"#
            )
        )

        let invocation = accumulator.invocations().first
        XCTAssertEqual(invocation?.id, "abc")
        XCTAssertEqual(invocation?.name, "web_search")
        XCTAssertEqual(invocation?.arguments["query"]?.stringValue, "Swift 6")
        XCTAssertEqual(invocation?.arguments["max_results"]?.integerValue, 3)
    }

    func testContentNormalizerRemovesLeakedDisabledThinkingPrefix() {
        let leaked = "hidden draft\n</think>\n\nVisible answer"
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent(leaked, thinkingEnabled: false),
            "Visible answer"
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent(leaked, thinkingEnabled: true),
            leaked
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent("Plain answer", thinkingEnabled: false),
            "Plain answer"
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent(
                "<antThinking>internal plan</antThinking>\nFinal answer",
                thinkingEnabled: false
            ),
            "Final answer"
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent(
                "The user is asking for nearby food.\n\nLet me call local_search.\n\n这里是最终答复。",
                thinkingEnabled: false
            ),
            "这里是最终答复。"
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent(
                "Let me call the local_search tool.\n\n这里是最终答复。",
                thinkingEnabled: false
            ),
            "这里是最终答复。"
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent("The user is ask", thinkingEnabled: false),
            ""
        )
        XCTAssertEqual(
            OllamaContentNormalizer.visibleContent("Let me ca", thinkingEnabled: false),
            ""
        )
    }

    func testSystemPromptReservesBlockquotesForCopyableText() {
        let prompt = LocalChatPrompt.systemMessage().content

        XCTAssertTrue(prompt.contains("never use them for explanations"))
        XCTAssertTrue(prompt.contains("Never nest blockquotes"))
        XCTAssertTrue(prompt.contains("copy verbatim"))
        XCTAssertTrue(prompt.contains("You may answer programming questions"))
        XCTAssertFalse(prompt.contains("attempt coding"))
        XCTAssertTrue(prompt.contains("do not append a Sources section"))
    }

    func testLiveLargeFetchWhenEnabled() async throws {
        guard let url = ProcessInfo.processInfo.environment[
            "LOCAL_CHAT_WEB_INTEGRATION_URL"
        ] else { return }
        let result = try await WebToolExecutor().execute(ToolInvocation(
            name: "fetch_url",
            arguments: ["url": .string(url)]
        ))
        XCTAssertFalse(result.content.isEmpty)
    }

    func testLiveWebSearchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CHAT_LIVE_WEB_SEARCH"] == "1" else {
            return
        }
        let result = try await WebToolExecutor().execute(ToolInvocation(
            name: "web_search",
            arguments: [
                "query": .string("Apple developer technologies 2026"),
                "max_results": .number(5)
            ]
        ))

        XCTAssertFalse(result.content.isEmpty)
        XCTAssertFalse(result.sources.isEmpty)
        XCTAssertTrue(result.summary.contains("Found"))
    }

    func testLocalContextReturnsOnlyRequestedLocalFields() async throws {
        let result = try await WebToolExecutor().execute(ToolInvocation(
            name: "local_context",
            arguments: [
                "fields": .array([
                    .string("time"),
                    .string("locale"),
                    .string("device"),
                    .string("power"),
                    .string("storage"),
                    .string("local_network")
                ])
            ]
        ))
        let data = try XCTUnwrap(result.content.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(
            Set(object.keys),
            Set(["time", "locale", "device", "power", "storage", "local_network"])
        )
        let device = try XCTUnwrap(object["device"]?.objectValue)
        XCTAssertNotNil(device["operating_system"])
        XCTAssertNotNil(device["physical_memory_bytes"])
        XCTAssertNil(device["serial_number"])
        XCTAssertNil(device["host_name"])
        XCTAssertNil(device["user_name"])
        XCTAssertFalse(result.content.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @MainActor
    func testCancellingLocationResolutionStopsTheManager() async throws {
        let manager = FakeLocationManager()
        let resolver = LocationResolver(
            manager: manager,
            locationServicesEnabled: { true }
        )
        let task = Task {
            try await resolver.resolve()
        }
        await Task.yield()
        XCTAssertEqual(manager.requestLocationCount, 1)

        task.cancel()
        resolver.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 31.2304,
                    longitude: 121.4737
                ),
                altitude: 0,
                horizontalAccuracy: 50,
                verticalAccuracy: -1,
                timestamp: Date()
            )]
        )

        do {
            _ = try await task.value
            XCTFail("Expected location resolution to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(manager.stopUpdatingLocationCount, 1)
    }

    @MainActor
    func testLocationResolutionRequestsPermissionBeforeLocation() async throws {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .notDetermined
        let resolver = LocationResolver(
            manager: manager,
            locationServicesEnabled: { true }
        )
        let task = Task {
            try await resolver.resolve()
        }
        await Task.yield()

        XCTAssertEqual(manager.authorizationRequestCount, 1)
        XCTAssertEqual(manager.requestLocationCount, 0)

        manager.authorizationStatus = .authorizedAlways
        resolver.locationManagerDidChangeAuthorization(CLLocationManager())
        XCTAssertEqual(manager.requestLocationCount, 1)

        let expected = CLLocation(latitude: 31.2304, longitude: 121.4737)
        resolver.locationManager(
            CLLocationManager(),
            didUpdateLocations: [expected]
        )
        let resolved = try await task.value
        XCTAssertEqual(resolved.coordinate.latitude, expected.coordinate.latitude)
        XCTAssertEqual(resolved.coordinate.longitude, expected.coordinate.longitude)
    }

    @MainActor
    func testLocationResolutionRejectsStaleFixAndStopsOnTimeout() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = FakeLocationManager()
        let resolver = LocationResolver(
            manager: manager,
            locationServicesEnabled: { true },
            timeout: .seconds(30),
            now: { now }
        )
        let staleTask = Task { try await resolver.resolve() }
        await Task.yield()
        resolver.locationManagerDidChangeAuthorization(CLLocationManager())
        XCTAssertEqual(manager.requestLocationCount, 1)
        resolver.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 31.2, longitude: 121.4),
                altitude: 0,
                horizontalAccuracy: -1,
                verticalAccuracy: -1,
                timestamp: now.addingTimeInterval(-60)
            )]
        )
        do {
            _ = try await staleTask.value
            XCTFail("Expected stale location to be rejected")
        } catch let error as LocalContextError {
            guard case .locationUnavailable = error else {
                return XCTFail("Expected locationUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(manager.stopUpdatingLocationCount, 1)

        let timeoutManager = FakeLocationManager()
        let timeoutResolver = LocationResolver(
            manager: timeoutManager,
            locationServicesEnabled: { true },
            timeout: .zero,
            now: { now }
        )
        do {
            _ = try await timeoutResolver.resolve()
            XCTFail("Expected location timeout")
        } catch LocalContextError.locationTimedOut {
        }
        XCTAssertEqual(timeoutManager.stopUpdatingLocationCount, 1)
    }

    @MainActor
    func testLocationResolutionDistinguishesRestrictedAuthorization() async throws {
        let manager = FakeLocationManager()
        manager.authorizationStatus = .restricted
        let resolver = LocationResolver(
            manager: manager,
            locationServicesEnabled: { true }
        )

        do {
            _ = try await resolver.resolve()
            XCTFail("Expected restricted location authorization")
        } catch LocalContextError.locationPermissionRestricted {
        }
        XCTAssertEqual(manager.requestLocationCount, 0)
        XCTAssertEqual(manager.authorizationRequestCount, 0)
        XCTAssertEqual(manager.stopUpdatingLocationCount, 1)
    }

    func testLivePublicIPContextWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CHAT_LIVE_PUBLIC_IP"] == "1" else {
            return
        }
        let result = try await WebToolExecutor().execute(ToolInvocation(
            name: "local_context",
            arguments: ["fields": .array([.string("public_ip")])]
        ))
        let data = try XCTUnwrap(result.content.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let publicIP = try XCTUnwrap(value.objectValue?["public_ip"]?.objectValue)
        let address = try XCTUnwrap(publicIP["address"]?.stringValue)

        XCTAssertNotNil(
            address.range(
                of: #"^(?:\d{1,3}\.){3}\d{1,3}$|^[0-9a-fA-F:]+$"#,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(publicIP["provider"]?.stringValue)
    }

    func testLiveAppleMapsLocalSearchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CHAT_LIVE_MAPKIT"] == "1" else {
            return
        }
        let result = try await LocalSearchProvider().search(
            query: "星巴克",
            radiusKilometers: 10,
            maximumResults: 3,
            near: CLLocation(latitude: 31.2304, longitude: 121.4737)
        )

        XCTAssertFalse(result.content.isEmpty)
        XCTAssertFalse(result.sources.isEmpty)
        XCTAssertLessThanOrEqual(result.sources.count, 3)
        XCTAssertTrue(result.sources.allSatisfy { $0.url.hasPrefix("https://maps.apple.com/") })
        XCTAssertTrue(result.summary.contains("Apple Maps"))
    }

    func testLargeDownloadedFileIsStreamExtractedWithoutFailure() throws {
        let directory = try scratchDirectory(named: "large-download")
        let file = directory.appendingPathComponent("large.html")
        let row = "<p>Microsoft stock price and market data.</p>"
        let html = "<html><body>" + String(repeating: row, count: 160_000)
            + "</body></html>"
        try Data(html.utf8).write(to: file)

        let result = try DirectWebClient.extractBoundedText(
            from: file,
            contentType: "text/html",
            maximumCharacters: 30_000
        )

        XCTAssertEqual(result.text.count, 30_000)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.text.contains("Microsoft stock price"))
    }

    private func scratchDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-TestArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
private final class FakeLocationManager: LocationManagerControlling {
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    private(set) var authorizationRequestCount = 0
    private(set) var requestLocationCount = 0
    private(set) var stopUpdatingLocationCount = 0

    func requestLocation() {
        requestLocationCount += 1
    }

    func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    func stopUpdatingLocation() {
        stopUpdatingLocationCount += 1
    }
}
