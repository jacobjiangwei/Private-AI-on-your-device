import Combine
import AppKit
import CoreGraphics
import CoreLocation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrivateAI

@MainActor
final class ChatViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        cancellables = []
        ScriptedURLProtocol.reset()
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testSuccessfulGenerationCompletesSingleAssistantMessage() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"Hello"},"done":true}

        """)
        let finished = expectation(description: "Generation finished")
        observeCompletion(of: viewModel, fulfilling: finished)

        viewModel.composerText = "Say hello"
        viewModel.send()
        await fulfillment(of: [finished], timeout: 2)

        let assistantMessages = viewModel.currentSession?.messages.filter {
            $0.role == .assistant
        }
        XCTAssertEqual(assistantMessages?.count, 1)
        XCTAssertEqual(assistantMessages?.first?.content, "Hello")
        XCTAssertEqual(assistantMessages?.first?.responseState, .complete)
        XCTAssertNotNil(assistantMessages?.first?.contextReceipt)
        XCTAssertEqual(assistantMessages?.first?.contextReceipt?.actualPromptTokens, 0)
        XCTAssertEqual(viewModel.statusMessage, "Ready")
    }

    func testOrdinaryPromptLetsModelChooseFromEverySupportedAction() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"Hello"},"done":true}

        """)

        try await send("Say hello", with: viewModel)

        let request = try lastRequestJSONObject()
        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        })
        XCTAssertEqual(names, ToolPolicy.modelActionToolNames)
        XCTAssertEqual(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })?
                .content,
            "Hello"
        )
        await viewModel.shutdown()
    }

    func testModelCannotActivateLocationAgainstUserDenial() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"tool_calls":[{"id":"forbidden-location","function":{"name":"local_context","arguments":{"fields":["location"]}}}]},"done":true}

            """
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"I won't access your location. The phrase means asking where someone is."},"done":true}

            """
        )
        let viewModel = try await makeViewModel()

        try await send(
            "Don't access my location. Rewrite the phrase 'where am I'.",
            with: viewModel
        )

        XCTAssertFalse(
            viewModel.currentSession?.messages.contains { $0.role == .tool } == true
        )
        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.responseState, .complete)
        XCTAssertTrue(assistant.content.contains("won't access"))
        XCTAssertEqual(
            viewModel.currentSession?.messages.filter { $0.role == .assistant }.count,
            1
        )
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        await viewModel.shutdown()
    }

    func testInvalidComputationActionSelfCorrectsToDirectTranslation() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"tool_calls":[{"id":"wrong-computation","function":{"name":"code_interpreter","arguments":{"expression":"\\\"Find restaurants near me\\\".replace(\\\"Find\\\", \\\"查找\\\")"}}}]},"done":true}

            """
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"翻译：查找我附近的餐馆。"},"done":true}

            """
        )
        let viewModel = try await makeViewModel()

        try await send(
            "Translate 'Find restaurants near me' into Chinese. Do not perform the search.",
            with: viewModel
        )

        XCTAssertFalse(
            viewModel.currentSession?.messages.contains { $0.role == .tool } == true
        )
        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.responseState, .complete)
        XCTAssertEqual(assistant.content, "翻译：查找我附近的餐馆。")
        XCTAssertEqual(
            viewModel.currentSession?.messages.filter { $0.role == .assistant }.count,
            1
        )
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        await viewModel.shutdown()
    }

    func testLocationPromptUsesReadableCoreLocationWithoutWebTools() async throws {
        let root = try makeTemporaryRoot(prefix: "ReadableLocation")
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2989, longitude: 120.5853),
            altitude: 0,
            horizontalAccuracy: 75,
            verticalAccuracy: -1,
            timestamp: Date()
        )
        let localContext = LocalContextProvider(
            resolveLocation: { location },
            describeLocation: { _ in
                [
                    "place_name_status": .string("available"),
                    "city": .string("Suzhou"),
                    "administrative_area": .string("Jiangsu"),
                    "country": .string("China")
                ]
            }
        )
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"tool_calls":[{"id":"current-location","function":{"name":"local_context","arguments":{"fields":["location"]}}}]},"done":true}

            """
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"You are in Suzhou, Jiangsu, China."},"done":true}

            """
        )
        let viewModel = try makeViewModel(
            root: root,
            webTools: WebToolExecutor(localContext: localContext)
        )
        try await viewModel.bootstrap()

        try await send("你帮我查一下我在哪儿", with: viewModel)

        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertFalse((object["tools"] as? [[String: Any]])?.isEmpty == true)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let toolContent = messages.compactMap { message -> String? in
            guard message["role"] as? String == "tool" else { return nil }
            return message["content"] as? String
        }.joined(separator: "\n")
        XCTAssertTrue(toolContent.contains("Suzhou"))
        XCTAssertTrue(toolContent.contains("Jiangsu"))
        XCTAssertTrue(toolContent.contains("macOS Core Location"))
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        await viewModel.shutdown()
    }

    func testFailedWeatherLocationRemovesDependentWebTools() async throws {
        let root = try makeTemporaryRoot(prefix: "WeatherLocationFailure")
        let localContext = LocalContextProvider(
            resolveLocation: {
                throw LocalContextError.locationPermissionDenied
            },
            describeLocation: { _ in [:] }
        )
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"tool_calls":[{"id":"weather-location","function":{"name":"local_context","arguments":{"fields":["location"]}}}]},"done":true}

            """
        )
        let viewModel = try makeViewModel(
            root: root,
            webTools: WebToolExecutor(localContext: localContext)
        )
        try await viewModel.bootstrap()

        try await send("weather near me", with: viewModel)

        let tool = try XCTUnwrap(
            viewModel.currentSession?.messages.first(where: { $0.role == .tool })
        )
        XCTAssertEqual(tool.tool?.status, .failure)
        XCTAssertTrue(tool.content.contains("Location permission was denied"))
        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.responseState, .failed)
        XCTAssertTrue(assistant.content.contains("couldn't read"))
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        await viewModel.shutdown()
    }

    func testNearbyRestaurantPromptUsesModelSelectedActionAndToolEvidence() async throws {
        let root = try makeTemporaryRoot(prefix: "ModelSelectedNearbySearch")
        let localSearch = LocalSearchStub(
            outcome: .success(
                ToolResult(
                    content: "1. 方洲面馆\nDistance: 280 m\nAddress: Suzhou",
                    summary: "Found 1 nearby place with Apple Maps",
                    sources: [
                        SourceLink(
                            title: "方洲面馆",
                            url: "https://maps.apple.com/?q=fangzhou"
                        )
                    ],
                    groundedAnswer: """
                    Apple Maps 找到以下附近地点，已按距离排序：

                    1. **方洲面馆**
                       - 距离：280 m

                    Apple Maps 没有返回评分或实时营业状态，请打开地点链接确认。
                    """
                )
            )
        )
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"The user is asking for nearby restaurants.\\n\\nLet me call local_search.","tool_calls":[{"id":"nearby-restaurants","function":{"name":"local_search","arguments":{"query":"餐馆","radius_km":5,"max_results":8}}}]},"done":true}

            """
        )
        let viewModel = try makeViewModel(
            root: root,
            webTools: WebToolExecutor(localSearch: localSearch)
        )
        try await viewModel.bootstrap()

        try await send("我附近的餐馆有什么推荐吗", with: viewModel)

        let callMessage = try XCTUnwrap(
            viewModel.currentSession?.messages.first(where: {
                $0.role == .assistant && $0.toolCalls?.isEmpty == false
            })
        )
        XCTAssertEqual(callMessage.content, "")
        XCTAssertEqual(callMessage.toolCalls?.first?.name, "local_search")
        let tool = try XCTUnwrap(
            viewModel.currentSession?.messages.first(where: { $0.role == .tool })
        )
        XCTAssertEqual(tool.tool?.status, .success)
        XCTAssertTrue(tool.content.contains("方洲面馆"))
        let answer = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: {
                $0.role == .assistant && $0.toolCalls == nil
            })
        )
        XCTAssertEqual(answer.responseState, .complete)
        XCTAssertTrue(answer.content.contains("方洲面馆"))
        XCTAssertTrue(answer.content.contains("没有返回评分或实时营业状态"))
        XCTAssertFalse(answer.content.contains("The user is asking"))
        XCTAssertFalse(answer.content.contains("Cheesecake Factory"))
        let calls = await localSearch.calls
        XCTAssertEqual(calls.map(\.query), ["餐馆"])
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let logText = try FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil
        ).map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(logText.contains("\"event\":\"action_selected\""))
        XCTAssertTrue(logText.contains("\"action\":\"local_search\""))
        XCTAssertFalse(logText.contains("\"query\""))
        XCTAssertFalse(logText.contains("餐馆"))
        await viewModel.shutdown()
    }

    func testNearbySearchFailureStopsBeforeModelCanInventResults() async throws {
        let root = try makeTemporaryRoot(prefix: "NearbySearchFailure")
        let localSearch = LocalSearchStub(
            outcome: .failure(.localSearchUnavailable("fixture unavailable"))
        )
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"tool_calls":[{"id":"nearby-failure","function":{"name":"local_search","arguments":{"query":"restaurants"}}}]},"done":true}

            """
        )
        let viewModel = try makeViewModel(
            root: root,
            webTools: WebToolExecutor(localSearch: localSearch)
        )
        try await viewModel.bootstrap()

        try await send("Recommend somewhere nearby to eat", with: viewModel)

        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.responseState, .failed)
        XCTAssertTrue(assistant.content.contains("won't invent recommendations"))
        XCTAssertFalse(assistant.content.contains("Cheesecake Factory"))
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        await viewModel.shutdown()
    }

    func testDirectAnswerClaimingAppleMapsWithoutToolEvidenceIsRejected() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"The user is asking for nearby restaurants.\\n\\nLet me call local_search.\\n\\n根据 Apple Maps，你附近有七家 The Cheesecake Factory。"},"done":true}

        """)

        try await send("我附近的餐馆有什么推荐吗", with: viewModel)

        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.responseState, .failed)
        XCTAssertTrue(assistant.content.contains("verified tool result"))
        XCTAssertFalse(assistant.content.contains("Cheesecake Factory"))
        await viewModel.shutdown()
    }

    func testModelWithoutToolSupportFailsWithoutToolFreeFallback() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 400,
            body: #"{"error":"selected model does not support tools"}"#
        )
        let viewModel = try await makeViewModel()

        try await send("Hello", with: viewModel)

        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.responseState, .failed)
        XCTAssertEqual(assistant.content, "Request failed.")
        XCTAssertTrue(
            assistant.responseIssue?.message.contains("does not support tools") == true
        )
        XCTAssertFalse(
            viewModel.currentSession?.messages.contains { $0.role == .tool } == true
        )
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        await viewModel.shutdown()
    }

    func testNextTurnHTTPRequestReplaysPersistedToolPair() async throws {
        let invocation = ToolInvocation(
            id: "search-42",
            name: "web_search",
            arguments: ["query": .string("current Qwen release")]
        )
        let existing = ChatSession(
            title: "Tool history",
            messages: [
                ChatMessage(role: .user, content: "Find current Qwen release"),
                ChatMessage(
                    role: .assistant,
                    content: "",
                    responseState: .complete,
                    toolCalls: [invocation]
                ),
                ChatMessage(
                    role: .tool,
                    content: "Qwen release result",
                    tool: ToolActivity(
                        name: invocation.name,
                        inputSummary: "current Qwen release",
                        status: .success,
                        detail: "Found release",
                        invocation: invocation
                    )
                ),
                ChatMessage(
                    role: .assistant,
                    content: "Qwen was updated.",
                    responseState: .complete
                )
            ]
        )
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"It was Qwen release result."},"done":true,"prompt_eval_count":123}

            """
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-ToolReplay-\(UUID().uuidString)")
        temporaryRoots.append(root)
        let store = try SessionStore(directory: root.appendingPathComponent("Sessions"))
        try await store.save(existing)
        let viewModel = try makeViewModel(root: root, sessionStore: store)
        try await viewModel.bootstrap()

        try await send("What did the result say?", with: viewModel)

        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let callMessage = try XCTUnwrap(messages.first { message in
            (message["tool_calls"] as? [[String: Any]])?.isEmpty == false
        })
        let calls = try XCTUnwrap(callMessage["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, invocation.id)
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, invocation.name)
        let arguments = try XCTUnwrap(function["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["query"] as? String, "current Qwen release")
        XCTAssertTrue(messages.contains { message in
            message["role"] as? String == "tool"
                && message["content"] as? String == "Qwen release result"
        })
        XCTAssertEqual(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })?
                .contextReceipt?.actualPromptTokens,
            123
        )
    }

    func testAttachmentOnlyImageSendPersistsReferenceAndEncodesVision() async throws {
        let root = try makeTemporaryRoot(prefix: "Vision")
        let imageURL = root.appendingPathComponent("red.png")
        try makeRedImage(at: imageURL)
        let viewModel = try await makeReadyViewModel(
            chatResponse: """
            {"message":{"content":"The image is red."},"done":true,"prompt_eval_count":77}

            """,
            root: root
        )

        await viewModel.importAttachments([imageURL])
        XCTAssertEqual(viewModel.draftAttachments.count, 1)
        XCTAssertTrue(viewModel.canSend)
        let attachmentID = try XCTUnwrap(viewModel.draftAttachments.first?.id)
        let finished = expectation(description: "Vision send finished")
        observeCompletion(of: viewModel, fulfilling: finished)
        viewModel.send()
        await fulfillment(of: [finished], timeout: 2)

        let user = try XCTUnwrap(
            viewModel.currentSession?.messages.first(where: { $0.role == .user })
        )
        XCTAssertEqual(user.content, "Analyze the attached files.")
        XCTAssertEqual(user.attachments?.first?.id, attachmentID)
        XCTAssertTrue(viewModel.draftAttachments.isEmpty)
        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertEqual(assistant.contextReceipt?.visionImages, 1)
        XCTAssertEqual(assistant.contextReceipt?.actualPromptTokens, 77)
        let requestObject = try lastRequestJSONObject()
        let messages = try XCTUnwrap(requestObject["messages"] as? [[String: Any]])
        let images = try XCTUnwrap(messages.last?["images"] as? [String])
        XCTAssertEqual(images.count, 1)
        XCTAssertNotNil(Data(base64Encoded: images[0]))
    }

    func testTextPDFSendIncludesBoundedRelevantExcerptWithoutVisionPayload() async throws {
        let root = try makeTemporaryRoot(prefix: "PDF")
        let pdfURL = root.appendingPathComponent("notes.pdf")
        try makePDF(
            at: pdfURL,
            pages: [
                "Fruit notes about apples and pears.",
                "The private project codename is HARBOR-LANTERN.",
                "Other notes about oranges and grapes."
            ]
        )
        let viewModel = try await makeReadyViewModel(
            chatResponse: """
            {"message":{"content":"HARBOR-LANTERN"},"done":true,"prompt_eval_count":101}

            """,
            root: root
        )

        await viewModel.importAttachments([pdfURL])
        viewModel.composerText = "What is the project codename?"
        try await send(viewModel.composerText, with: viewModel)

        let requestObject = try lastRequestJSONObject()
        let messages = try XCTUnwrap(requestObject["messages"] as? [[String: Any]])
        let current = try XCTUnwrap(messages.last)
        let content = try XCTUnwrap(current["content"] as? String)
        XCTAssertTrue(content.contains("Local attachment excerpts"))
        XCTAssertTrue(content.contains("HARBOR-LANTERN"))
        XCTAssertNil(current["images"])
        let assistant = try XCTUnwrap(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })
        )
        XCTAssertGreaterThan(assistant.contextReceipt?.attachmentChunks ?? 0, 0)
        XCTAssertEqual(assistant.contextReceipt?.visionImages, 0)
    }

    func testTypedLocalPathRequiresAuthorizationWithoutAnyRequest() async throws {
        let root = try makeTemporaryRoot(prefix: "PathPermission")
        let source = root.appendingPathComponent("word-online-snapshot.md")
        try Data("# Local snapshot".utf8).write(to: source)
        let viewModel = try await makeReadyViewModel(
            chatResponse: """
            {"message":{"content":"Should not run"},"done":true}

            """,
            root: root
        )
        let prompt = "\(source.path)\n读一下文件"
        viewModel.composerText = prompt

        viewModel.send()

        XCTAssertEqual(
            viewModel.pendingLocalFileAuthorization?.typedPaths,
            [source.path]
        )
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertTrue(viewModel.currentSession?.messages.isEmpty == true)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
        XCTAssertEqual(viewModel.composerText, prompt)

        viewModel.cancelLocalFileAuthorization()
        XCTAssertNil(viewModel.pendingLocalFileAuthorization)
        XCTAssertEqual(viewModel.composerText, prompt)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
    }

    func testAuthorizedLocalMarkdownIsReadWithoutExposingPathOrExecutingWebAction() async throws {
        let root = try makeTemporaryRoot(prefix: "AuthorizedPath")
        let source = root.appendingPathComponent("word-online-snapshot.md")
        try Data("""
        # Local Microsoft Scout snapshot

        The selected local file says tracked changes are preserved.
        """.utf8).write(to: source)
        let viewModel = try await makeReadyViewModel(
            chatResponse: """
            {"message":{"content":"Tracked changes are preserved."},"done":true,"prompt_eval_count":88}

            """,
            root: root
        )
        viewModel.composerText = "\(source.path)\n读一下文件"
        viewModel.send()
        let finished = expectation(description: "Authorized local file answered")
        observeCompletion(of: viewModel, fulfilling: finished)

        await viewModel.authorizePendingLocalFiles([source])
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(viewModel.pendingLocalFileAuthorization)
        XCTAssertTrue(viewModel.draftAttachments.isEmpty)
        let user = try XCTUnwrap(
            viewModel.currentSession?.messages.first(where: { $0.role == .user })
        )
        XCTAssertEqual(user.content, "读一下文件")
        XCTAssertEqual(user.attachments?.first?.kind, .text)
        let request = try lastRequestJSONObject()
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let serialized = String(decoding: requestData, as: UTF8.self)
        XCTAssertFalse(serialized.contains(source.path))
        XCTAssertFalse(serialized.contains("/Users/"))
        XCTAssertTrue(serialized.contains("tracked changes are preserved"))
        XCTAssertFalse((request["tools"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertFalse(
            viewModel.currentSession?.messages.contains { message in
                message.role == .tool && [
                    "web_search", "fetch_url", "browser_snapshot", "browser_extract"
                ].contains(message.tool?.name)
            } == true
        )
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
    }

    func testTwoSelectedFilesBothReachOllamaContext() async throws {
        let root = try makeTemporaryRoot(prefix: "TwoFiles")
        let receiptURL = root.appendingPathComponent("e-receipt.md")
        let readmeURL = root.appendingPathComponent("README.md")
        try Data(
            ("RECEIPT-FACT: TOTAL-452-55\n" + String(repeating: "Receipt details. ", count: 900)).utf8
        ).write(to: receiptURL)
        try Data(
            ("README-FACT: PROJECT-SCOUT\n" + String(repeating: "README details. ", count: 900)).utf8
        ).write(to: readmeURL)
        let viewModel = try await makeReadyViewModel(
            chatResponse: """
            {"message":{"content":"Both files received."},"done":true,"prompt_eval_count":180}

            """,
            root: root
        )

        await viewModel.importAttachments([receiptURL, readmeURL])
        viewModel.composerText = "我给你了2个文件呢，请分别说明"
        try await send(viewModel.composerText, with: viewModel)

        let request = try lastRequestJSONObject()
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let current = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(current.contains("The user explicitly attached 2 local file(s)"))
        XCTAssertTrue(current.contains("e-receipt.md"))
        XCTAssertTrue(current.contains("README.md"))
        XCTAssertTrue(current.contains("RECEIPT-FACT: TOTAL-452-55"))
        XCTAssertTrue(current.contains("README-FACT: PROJECT-SCOUT"))
        XCTAssertEqual(
            viewModel.currentSession?.messages.first(where: { $0.role == .user })?
                .attachments?.count,
            2
        )
    }

    func testDocumentProfileIsGeneratedOnceAndReusedInChatContext() async throws {
        let root = try makeTemporaryRoot(prefix: "DocumentProfile")
        let source = root.appendingPathComponent("harbor.md")
        try Data(
            "# Harbor Plan\n\nRAW-MARKER-ALPHA-71 follows privacy review.".utf8
        ).write(to: source)
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx","digest":"digest-v1"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: try documentProfileStreamBody(
                summary: "DERIVED-PROFILE-HARBOR covers milestone ALPHA-71."
            )
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Grounded answer"},"done":true}

            """
        )
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let viewModel = try makeViewModel(
            root: root,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()

        await viewModel.importAttachments([source])
        let finished = expectation(description: "Profile-backed answer finished")
        observeCompletion(of: viewModel, fulfilling: finished)
        viewModel.composerText = "What follows privacy review?"
        viewModel.send()
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let prompt = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(prompt.contains("DERIVED-PROFILE-HARBOR"))
        XCTAssertTrue(prompt.contains("RAW-MARKER-ALPHA-71"))
        XCTAssertEqual(
            viewModel.currentSession?.messages.last?.contextReceipt?.documentProfiles,
            1
        )

        await viewModel.importAttachments([source])
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        await viewModel.shutdown()
    }

    func testAttachmentImportFinishesBeforeProfileAndSendReusesInFlightWork() async throws {
        let root = try makeTemporaryRoot(prefix: "BackgroundDocumentProfile")
        let source = root.appendingPathComponent("background-profile.md")
        try Data(
            "# Background profile\n\nRAW-BACKGROUND-MARKER-82".utf8
        ).write(to: source)
        let profileStarted = AsyncSignal()
        let releaseProfile = AsyncSignal()
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx","digest":"background-digest"}]}"#
        )
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: try documentProfileStreamBody(
                summary: "DERIVED-BACKGROUND-PROFILE-82"
            ),
            onStart: { Task { await profileStarted.signal() } },
            waitForFinish: { await releaseProfile.wait() },
            onStop: {}
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Background profile joined"},"done":true}

            """
        )
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let viewModel = try makeViewModel(
            root: root,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()
        var pendingSnapshots: [[PendingAttachmentImport]] = []
        viewModel.$pendingAttachmentImports
            .sink { pendingSnapshots.append($0) }
            .store(in: &cancellables)

        let importFinished = expectation(description: "Local attachment import finished")
        let importTask = Task {
            await viewModel.importAttachments([source])
            importFinished.fulfill()
        }
        await profileStarted.wait()
        await fulfillment(of: [importFinished], timeout: 0.5)
        XCTAssertTrue(pendingSnapshots.contains { snapshot in
            snapshot.contains { $0.displayName == source.lastPathComponent }
        })
        XCTAssertTrue(viewModel.pendingAttachmentImports.isEmpty)
        XCTAssertEqual(viewModel.draftAttachments.map(\.displayName), [source.lastPathComponent])
        XCTAssertFalse(viewModel.isImportingAttachments)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)

        let answerFinished = expectation(description: "Profile-backed answer finished")
        observeCompletion(of: viewModel, fulfilling: answerFinished)
        viewModel.composerText = "What is in this file?"
        viewModel.send()
        viewModel.selectedModel = "llama3.2:latest"
        viewModel.thinkingEnabled = true
        await Task.yield()
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        await releaseProfile.signal()
        await fulfillment(of: [answerFinished], timeout: 2)
        await importTask.value

        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let data = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(object["model"] as? String, "qwen3.8:27b-mlx")
        XCTAssertEqual(object["think"] as? Bool, false)
        XCTAssertTrue(body.contains("DERIVED-BACKGROUND-PROFILE-82"))
        XCTAssertTrue(body.contains("RAW-BACKGROUND-MARKER-82"))
        await attachmentStore.close()
    }

    func testMultipleAttachmentProfileWarmupsRunSerially() async throws {
        let root = try makeTemporaryRoot(prefix: "SerialDocumentProfiles")
        let firstSource = root.appendingPathComponent("first.md")
        let secondSource = root.appendingPathComponent("second.md")
        try Data("SERIAL-PROFILE-FIRST".utf8).write(to: firstSource)
        try Data("SERIAL-PROFILE-SECOND".utf8).write(to: secondSource)
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx","digest":"serial-digest"}]}"#
        )
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: try documentProfileStreamBody(summary: "FIRST-SERIAL-PROFILE"),
            onStart: { Task { await firstStarted.signal() } },
            waitForFinish: { await releaseFirst.wait() },
            onStop: {}
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: try documentProfileStreamBody(summary: "SECOND-SERIAL-PROFILE")
        )
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let viewModel = try makeViewModel(
            root: root,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()
        let profilesReady = expectation(description: "Both profile warmups finished")
        viewModel.$libraryProfiles
            .sink { profiles in
                if profiles.count == 2 { profilesReady.fulfill() }
            }
            .store(in: &cancellables)

        await viewModel.importAttachments([firstSource, secondSource])
        await firstStarted.wait()
        XCTAssertEqual(viewModel.draftAttachments.count, 2)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)

        await releaseFirst.signal()
        await fulfillment(of: [profilesReady], timeout: 2)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 4)
        XCTAssertEqual(viewModel.libraryProfiles.count, 2)
        await attachmentStore.close()
    }

    func testSendRequeuesDifferentActiveProfileWarmup() async throws {
        let root = try makeTemporaryRoot(prefix: "RequeuedDocumentProfile")
        let firstSource = root.appendingPathComponent("background-a.md")
        let secondSource = root.appendingPathComponent("question-b.md")
        try Data("BACKGROUND-A-RAW".utf8).write(to: firstSource)
        try Data("QUESTION-B-RAW".utf8).write(to: secondSource)
        let firstStarted = AsyncSignal()
        let firstStopped = AsyncSignal()
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx","digest":"requeue-digest"}]}"#
        )
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: try documentProfileStreamBody(summary: "INTERRUPTED-A"),
            onStart: { Task { await firstStarted.signal() } },
            waitForFinish: { await AsyncSignal().wait() },
            onStop: { Task { await firstStopped.signal() } }
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: try documentProfileStreamBody(summary: "FOREGROUND-B")
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Answered B"},"done":true}

            """
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: try documentProfileStreamBody(summary: "RESUMED-A")
        )
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let viewModel = try makeViewModel(
            root: root,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()
        let profilesReady = expectation(description: "Interrupted warmup resumed")
        viewModel.$libraryProfiles
            .sink { profiles in
                if profiles.count == 2 { profilesReady.fulfill() }
            }
            .store(in: &cancellables)

        await viewModel.importAttachments([firstSource, secondSource])
        await firstStarted.wait()
        let firstID = try XCTUnwrap(
            viewModel.draftAttachments.first(where: {
                $0.displayName == firstSource.lastPathComponent
            })?.id
        )
        viewModel.removeDraftAttachment(firstID)
        let answerFinished = expectation(description: "Question B answered")
        observeCompletion(of: viewModel, fulfilling: answerFinished)
        viewModel.composerText = "Answer from B"
        viewModel.send()

        await firstStopped.wait()
        await fulfillment(of: [answerFinished, profilesReady], timeout: 2)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 6)
        XCTAssertTrue(viewModel.libraryProfiles.values.contains {
            $0.summary == "FOREGROUND-B"
        })
        XCTAssertTrue(viewModel.libraryProfiles.values.contains {
            $0.summary == "RESUMED-A"
        })
        await viewModel.shutdown()
        await attachmentStore.close()
    }

    func testShutdownCancelsAndWaitsForPendingProfile() async throws {
        let root = try makeTemporaryRoot(prefix: "ProfileShutdown")
        let source = root.appendingPathComponent("shutdown.md")
        try Data("SHUTDOWN-PROFILE".utf8).write(to: source)
        let profileStarted = AsyncSignal()
        let profileStopped = AsyncSignal()
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx","digest":"shutdown-digest"}]}"#
        )
        ScriptedURLProtocol.enqueuePending(
            statusCode: 200,
            body: "",
            onStart: { Task { await profileStarted.signal() } },
            onStop: { Task { await profileStopped.signal() } }
        )
        let viewModel = try makeViewModel(root: root)
        try await viewModel.bootstrap()
        await viewModel.importAttachments([source])
        await profileStarted.wait()

        await viewModel.shutdown()
        await profileStopped.wait()

        XCTAssertFalse(viewModel.canSend)
        let attachmentCount = viewModel.draftAttachments.count
        await viewModel.importAttachments([source])
        XCTAssertEqual(viewModel.draftAttachments.count, attachmentCount)
    }

    func testUnsupportedScannedPDFBlocksSendWithoutParserNetworkRequest() async throws {
        let root = try makeTemporaryRoot(prefix: "Scanned")
        let pdfURL = root.appendingPathComponent("scan.pdf")
        try makePDF(at: pdfURL, pages: [""])
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(root: root)
        try await viewModel.bootstrap()

        await viewModel.importAttachments([pdfURL])
        viewModel.composerText = "Read this scan"

        XCTAssertEqual(viewModel.draftAttachments.first?.state, .advancedParserRequired)
        XCTAssertEqual(viewModel.draftAttachments.first?.issue?.code, .noExtractableText)
        XCTAssertFalse(viewModel.canSend)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
        viewModel.removeDraftAttachment(
            try XCTUnwrap(viewModel.draftAttachments.first?.id)
        )
        XCTAssertTrue(viewModel.canSend)
    }

    func testReadinessReportsMissingSupportedModelWithDiskSpace() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(statusCode: 200, body: #"{"models":[]}"#)

        let viewModel = try await makeViewModel(availableDiskBytes: { 42_000_000_000 })

        XCTAssertEqual(
            viewModel.ollamaReadiness,
            .modelMissing(availableDiskBytes: 42_000_000_000)
        )
        XCTAssertTrue(viewModel.selectedModel.isEmpty)
    }

    func testReadinessDistinguishesMissingAppFromStoppedService() async throws {
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: "",
            terminalError: URLError(.cannotConnectToHost)
        )
        let missing = try await makeViewModel(ollamaApplicationURL: { nil })
        XCTAssertEqual(missing.ollamaReadiness, .notInstalled)

        ScriptedURLProtocol.reset()
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: "",
            terminalError: URLError(.cannotConnectToHost)
        )
        let stopped = try await makeViewModel {
            URL(fileURLWithPath: "/Applications/Ollama.app")
        }
        XCTAssertEqual(stopped.ollamaReadiness, .serviceUnavailable)
    }

    func testReadinessRequiresMinimumOllamaVersion() async throws {
        enqueueVersion("0.31.9")

        let viewModel = try await makeViewModel()

        XCTAssertEqual(
            viewModel.ollamaReadiness,
            .updateRequired(installedVersion: "0.31.9")
        )
        XCTAssertEqual(viewModel.selectedModel, OllamaClient.recommendedModelName)
        XCTAssertTrue(viewModel.models.isEmpty)
        XCTAssertFalse(viewModel.canSend)
    }

    func testRecheckAfterExternalPullBecomesReadyWithoutLosingDraft() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(statusCode: 200, body: #"{"models":[]}"#)
        let viewModel = try await makeViewModel()
        viewModel.composerText = "Draft survives setup"

        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        await viewModel.refreshModels()

        XCTAssertEqual(viewModel.ollamaReadiness, .ready(version: "0.32.15"))
        XCTAssertEqual(viewModel.selectedModel, OllamaClient.recommendedModelName)
        XCTAssertEqual(viewModel.composerText, "Draft survives setup")
    }

    func testAnyInstalledOllamaModelCanBeSelectedAndSurvivesRefresh() async throws {
        let models = #"{"models":[{"name":"qwen3.8:27b-mlx"},{"name":"llama3.2:latest"}]}"#
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(statusCode: 200, body: models)
        let viewModel = try await makeViewModel()

        viewModel.selectedModel = "llama3.2:latest"
        viewModel.composerText = "Use my selected model"

        XCTAssertTrue(viewModel.canSend)

        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(statusCode: 200, body: models)
        await viewModel.refreshModels()

        XCTAssertEqual(viewModel.ollamaReadiness, .ready(version: "0.32.15"))
        XCTAssertEqual(viewModel.selectedModel, "llama3.2:latest")
        XCTAssertTrue(viewModel.canSend)
    }

    func testNonRecommendedModelAloneMakesOllamaReady() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"gemma3:latest"}]}"#
        )
        let viewModel = try await makeViewModel()
        viewModel.composerText = "Use the installed model"

        XCTAssertEqual(viewModel.ollamaReadiness, .ready(version: "0.32.15"))
        XCTAssertEqual(viewModel.selectedModel, "gemma3:latest")
        XCTAssertTrue(viewModel.canSend)
    }

    func testSemanticVersionComparison() {
        XCTAssertTrue(ChatViewModel.isVersion("0.32.15", atLeast: "0.32.12"))
        XCTAssertTrue(ChatViewModel.isVersion("1.0", atLeast: "0.32.12"))
        XCTAssertFalse(ChatViewModel.isVersion("0.32.9", atLeast: "0.32.12"))
    }

    func testRenameAndTitleSearchAreLocalAndDiacriticInsensitive() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try await makeViewModel()
        let firstID = try XCTUnwrap(viewModel.selectedSessionID)
        XCTAssertNil(viewModel.composerFocusRequestID)
        viewModel.renameSession(firstID, to: "  Résumé    Alpha  ")
        viewModel.newSession()
        let focusRequestID = try XCTUnwrap(viewModel.composerFocusRequestID)
        viewModel.acknowledgeComposerFocus(UUID())
        XCTAssertEqual(viewModel.composerFocusRequestID, focusRequestID)
        viewModel.acknowledgeComposerFocus(focusRequestID)
        XCTAssertNil(viewModel.composerFocusRequestID)
        let secondID = try XCTUnwrap(viewModel.selectedSessionID)
        viewModel.renameSession(
            secondID,
            to: String(repeating: "Long title ", count: 20)
        )

        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == firstID })?.title,
            "Résumé Alpha"
        )
        XCTAssertLessThanOrEqual(
            viewModel.sessions.first(where: { $0.id == secondID })?.title.count ?? 0,
            64
        )
        viewModel.sessionSearchText = "resume"
        XCTAssertEqual(viewModel.visibleSessions.map(\.id), [firstID])
        viewModel.sessionSearchText = ""
        XCTAssertEqual(viewModel.visibleSessions.count, 2)
        await viewModel.shutdown()
    }

    func testChatSearchFindsVisibleMessagesWithSnippetAndAnchorOnlyLocally() async throws {
        let root = try makeTemporaryRoot(prefix: "ChatContentSearch")
        let matchingUser = ChatMessage(
            role: .user,
            content: "Plan the Résumé launch for Ｐｒｉｖａｔｅ beta users. [raw](https://user-visible.example/USER-URL-SENTINEL)"
        )
        let matchingAssistant = ChatMessage(
            role: .assistant,
            content: "The launch checklist includes a **privacy review**. Read [OpenAI docs](https://hidden.example/HIDDEN-LINK-SENTINEL) and `visible-code`."
        )
        let hiddenAssistant = ChatMessage(
            role: .assistant,
            content: "Visible answer with algebra $$HIDDEN-MATH-SENTINEL$$ complete.",
            thinking: "HIDDEN-THINKING-SENTINEL"
        )
        let toolMessage = ChatMessage(
            role: .tool,
            content: "HIDDEN-TOOL-SENTINEL"
        )
        let matchingSession = ChatSession(
            title: "Launch notes",
            messages: [matchingUser, matchingAssistant, hiddenAssistant, toolMessage]
        )
        let otherSession = ChatSession(
            title: "Unrelated",
            messages: [ChatMessage(role: .user, content: "Grocery list")]
        )
        let sessionStore = try SessionStore(
            directory: root.appendingPathComponent("Sessions")
        )
        try await sessionStore.save(otherSession)
        try await sessionStore.save(matchingSession)
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            sessionStore: sessionStore
        )
        try await viewModel.bootstrap()
        let requestCountBeforeSearch = ScriptedURLProtocol.requestCount

        viewModel.sessionSearchText = "resume   launch for private"

        let userResult = try XCTUnwrap(viewModel.sessionSearchResults.first)
        XCTAssertEqual(viewModel.sessionSearchResults.count, 1)
        XCTAssertEqual(userResult.session.id, matchingSession.id)
        XCTAssertEqual(userResult.messageID, matchingUser.id)
        XCTAssertTrue(userResult.snippet?.hasPrefix("You: ") == true)
        XCTAssertTrue(userResult.snippet?.contains("Résumé launch") == true)
        viewModel.openSearchResult(userResult)
        XCTAssertEqual(viewModel.selectedSessionID, matchingSession.id)
        XCTAssertEqual(viewModel.requestedScrollMessageID, matchingUser.id)
        let firstScrollRequestID = try XCTUnwrap(viewModel.requestedScrollRequestID)
        viewModel.openSearchResult(userResult)
        XCTAssertEqual(viewModel.requestedScrollMessageID, matchingUser.id)
        XCTAssertNotEqual(viewModel.requestedScrollRequestID, firstScrollRequestID)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, requestCountBeforeSearch)

        viewModel.sessionSearchText = "USER-URL-SENTINEL"
        XCTAssertEqual(viewModel.sessionSearchResults.first?.messageID, matchingUser.id)

        viewModel.sessionSearchText = "privacy review"
        let assistantResult = try XCTUnwrap(viewModel.sessionSearchResults.first)
        XCTAssertEqual(assistantResult.messageID, matchingAssistant.id)
        XCTAssertTrue(assistantResult.snippet?.hasPrefix("PrivateAI: ") == true)
        XCTAssertTrue(assistantResult.snippet?.contains("privacy review") == true)

        viewModel.sessionSearchText = "OpenAI docs"
        XCTAssertEqual(viewModel.sessionSearchResults.first?.messageID, matchingAssistant.id)
        viewModel.sessionSearchText = "visible-code"
        XCTAssertEqual(viewModel.sessionSearchResults.first?.messageID, matchingAssistant.id)
        viewModel.sessionSearchText = "HIDDEN-LINK-SENTINEL"
        XCTAssertTrue(viewModel.sessionSearchResults.isEmpty)
        viewModel.sessionSearchText = "HIDDEN-MATH-SENTINEL"
        XCTAssertTrue(viewModel.sessionSearchResults.isEmpty)

        viewModel.sessionSearchText = "HIDDEN-THINKING-SENTINEL"
        XCTAssertTrue(viewModel.sessionSearchResults.isEmpty)
        viewModel.sessionSearchText = "HIDDEN-TOOL-SENTINEL"
        XCTAssertTrue(viewModel.sessionSearchResults.isEmpty)

        let searchScrollRequestID = viewModel.requestedScrollRequestID
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Follow-up answer"},"done":true}

            """
        )
        let sendFinished = expectation(description: "Search follow-up finished")
        observeCompletion(of: viewModel, fulfilling: sendFinished)
        viewModel.sessionSearchText = ""
        viewModel.composerText = "Follow up after search"
        viewModel.send()
        await fulfillment(of: [sendFinished], timeout: 2)
        XCTAssertNotEqual(viewModel.requestedScrollRequestID, searchScrollRequestID)
        XCTAssertNotEqual(viewModel.requestedScrollMessageID, matchingUser.id)

        viewModel.sessionSearchText = "privacy review"
        await viewModel.deleteSession(matchingSession.id)
        XCTAssertTrue(viewModel.sessionSearchResults.isEmpty)
        await viewModel.shutdown()
    }

    func testRestartRecoveryNormalizesOnlyInterruptedWork() {
        let completed = ChatMessage(
            role: .assistant,
            content: "Complete",
            responseState: .complete
        )
        let runningTool = ChatMessage(
            role: .tool,
            content: "",
            tool: ToolActivity(
                name: "web_search",
                inputSummary: "query",
                status: .running
            )
        )
        let sessions = [
            ChatSession(
                title: "Interrupted assistant",
                messages: [
                    ChatMessage(role: .user, content: "Question"),
                    ChatMessage(
                        role: .assistant,
                        content: "Partial",
                        responseState: .streaming
                    ),
                    runningTool
                ]
            ),
            ChatSession(
                title: "Trailing user",
                messages: [ChatMessage(role: .user, content: "No answer")]
            ),
            ChatSession(title: "Complete", messages: [completed])
        ]

        let recovery = ChatViewModel.recoverInterruptedSessions(sessions)

        XCTAssertEqual(recovery.changedSessionIDs.count, 2)
        let interrupted = recovery.sessions.first {
            $0.title == "Interrupted assistant"
        }
        XCTAssertEqual(
            interrupted?.messages.first(where: { $0.role == .assistant })?.responseState,
            .stopped
        )
        XCTAssertEqual(
            interrupted?.messages.first(where: { $0.role == .assistant })?.responseIssue?.code,
            .interruptedByRestart
        )
        XCTAssertEqual(
            interrupted?.messages.first(where: { $0.role == .tool })?.tool?.status,
            .failure
        )
        let trailing = recovery.sessions.first { $0.title == "Trailing user" }
        XCTAssertEqual(trailing?.messages.last?.responseState, .stopped)
        XCTAssertEqual(
            recovery.sessions.first { $0.title == "Complete" }?.messages,
            [completed]
        )
    }

    func testBootstrapPersistsRestartRecovery() async throws {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-Recovery-\(UUID().uuidString)")
        temporaryRoots.append(root)
        let sessionStore = try SessionStore(
            directory: root.appendingPathComponent("Sessions")
        )
        let session = ChatSession(
            title: "Interrupted",
            messages: [ChatMessage(role: .user, content: "Pending")]
        )
        try await sessionStore.save(session)
        let viewModel = try makeViewModel(
            root: root,
            sessionStore: sessionStore
        )

        try await viewModel.bootstrap()

        XCTAssertEqual(viewModel.currentSession?.messages.last?.responseState, .stopped)
        let reloaded = try await sessionStore.load()
        XCTAssertEqual(reloaded.first?.messages.last?.responseState, .stopped)
    }

    func testBootstrapFailsClosedForCorruptSessionData() async throws {
        let root = try makeTemporaryRoot(prefix: "CorruptSession")
        let sessions = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true
        )
        let corrupt = sessions.appendingPathComponent("corrupt.json")
        try Data("{not-json".utf8).write(to: corrupt)
        let viewModel = try makeViewModel(root: root)

        do {
            try await viewModel.bootstrap()
            XCTFail("Expected corrupt durable session data to block startup")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 0)
    }

    func testPartialTransportFailureStaysInOneFailedAssistantMessage() async throws {
        let viewModel = try await makeReadyViewModel(
            chatResponse: """
            {"message":{"content":"Partial answer"},"done":false}
            {not-json}

            """
        )
        let finished = expectation(description: "Generation failed")
        observeCompletion(of: viewModel, fulfilling: finished)

        viewModel.composerText = "Start an answer"
        viewModel.send()
        await fulfillment(of: [finished], timeout: 2)

        let assistantMessages = viewModel.currentSession?.messages.filter {
            $0.role == .assistant
        }
        XCTAssertEqual(assistantMessages?.count, 1)
        XCTAssertTrue(assistantMessages?.first?.content.contains("Partial answer") == true)
        XCTAssertFalse(assistantMessages?.first?.content.contains("Error:") == true)
        XCTAssertEqual(assistantMessages?.first?.responseState, .failed)
        XCTAssertEqual(assistantMessages?.first?.responseIssue?.code, .invalidStream)
        XCTAssertFalse(assistantMessages?.first?.responseIssue?.message.isEmpty == true)
        XCTAssertEqual(viewModel.statusMessage, "Request failed")
    }

    func testStopBlocksAnotherSendUntilPendingRequestIsCancelled() async throws {
        let started = AsyncSignal()
        let transportStopped = AsyncSignal()
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueuePending(
            statusCode: 200,
            body: """
            {"message":{"content":"Partial"},"done":false}

            """,
            onStart: { Task { await started.signal() } },
            onStop: { Task { await transportStopped.signal() } }
        )
        let viewModel = try await makeViewModel()
        let partialArrived = expectation(description: "Partial response arrived")
        observeMessage(in: viewModel, containing: "Partial", fulfilling: partialArrived)
        let finished = expectation(description: "Cancellation finished")
        observeCompletion(of: viewModel, fulfilling: finished)

        viewModel.composerText = "First request"
        viewModel.send()
        await started.wait()
        await fulfillment(of: [partialArrived], timeout: 2)
        let requestCountBeforeRecheck = ScriptedURLProtocol.requestCount
        let modelBeforeRecheck = viewModel.selectedModel
        let statusBeforeRecheck = viewModel.statusMessage

        await viewModel.refreshModels()

        XCTAssertEqual(ScriptedURLProtocol.requestCount, requestCountBeforeRecheck)
        XCTAssertEqual(viewModel.selectedModel, modelBeforeRecheck)
        XCTAssertEqual(viewModel.statusMessage, statusBeforeRecheck)
        XCTAssertTrue(viewModel.isStreaming)

        viewModel.stop()
        XCTAssertTrue(viewModel.isStreaming)
        XCTAssertEqual(viewModel.statusMessage, "Stopping…")
        viewModel.composerText = "Must not send yet"
        viewModel.send()
        XCTAssertEqual(
            viewModel.currentSession?.messages.filter { $0.role == .user }.count,
            1
        )

        await transportStopped.wait()
        await fulfillment(of: [finished], timeout: 2)
        let assistantMessages = viewModel.currentSession?.messages.filter {
            $0.role == .assistant
        }
        XCTAssertEqual(assistantMessages?.count, 1)
        XCTAssertEqual(assistantMessages?.first?.content, "Partial")
        XCTAssertEqual(assistantMessages?.first?.responseState, .stopped)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.statusMessage, "Stopped")
    }

    func testLargePartialResponseIsCheckpointedBeforeCompletion() async throws {
        let partial = String(repeating: "A", count: 1_200)
        let started = AsyncSignal()
        let stopped = AsyncSignal()
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueuePending(
            statusCode: 200,
            body: """
            {"message":{"content":"\(partial)"},"done":false}

            """,
            onStart: { Task { await started.signal() } },
            onStop: { Task { await stopped.signal() } }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-Checkpoint-\(UUID().uuidString)")
        temporaryRoots.append(root)
        let store = try SessionStore(directory: root.appendingPathComponent("Sessions"))
        let viewModel = try makeViewModel(root: root, sessionStore: store)
        try await viewModel.bootstrap()
        let partialArrived = expectation(description: "Large partial arrived")
        observeMessage(in: viewModel, containing: partial, fulfilling: partialArrived)

        viewModel.composerText = "Checkpoint"
        viewModel.send()
        await started.wait()
        await fulfillment(of: [partialArrived], timeout: 2)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var checkpointed = false
        while clock.now < deadline {
            if try await store.load().first?.messages.contains(where: {
                $0.role == .assistant && $0.content == partial
                    && $0.responseState == .streaming
            }) == true {
                checkpointed = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(checkpointed)

        viewModel.stop()
        await stopped.wait()
    }

    func testRegenerateCreatesNewSessionAndPreservesOriginal() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"Original answer"},"done":true}

        """)
        try await send("Original question", with: viewModel)
        let originalSession = try XCTUnwrap(viewModel.currentSession)
        let assistantID = try XCTUnwrap(
            originalSession.messages.last(where: { $0.role == .assistant })?.id
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Regenerated answer"},"done":true}

            """
        )
        let finished = expectation(description: "Regeneration finished")
        observeCompletion(of: viewModel, fulfilling: finished)

        viewModel.regenerateAssistant(assistantID)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(viewModel.sessions.count, 2)
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == originalSession.id }),
            originalSession
        )
        let branch = try XCTUnwrap(viewModel.currentSession)
        XCTAssertEqual(branch.fork?.parentSessionID, originalSession.id)
        XCTAssertEqual(branch.fork?.reason, .regenerate)
        XCTAssertEqual(
            branch.messages.filter { $0.role == .user }.map(\.content),
            ["Original question"]
        )
        XCTAssertEqual(
            branch.messages.last(where: { $0.role == .assistant })?.content,
            "Regenerated answer"
        )
    }

    func testRetryFailedResponseCreatesRetryBranch() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"Partial"},"done":false}
        {not-json}

        """)
        try await send("Retry this", with: viewModel)
        let originalSession = try XCTUnwrap(viewModel.currentSession)
        let failedID = try XCTUnwrap(
            originalSession.messages.last(where: { $0.role == .assistant })?.id
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Recovered"},"done":true}

            """
        )
        let finished = expectation(description: "Retry finished")
        observeCompletion(of: viewModel, fulfilling: finished)

        viewModel.retryAssistant(failedID)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == originalSession.id }),
            originalSession
        )
        XCTAssertEqual(viewModel.currentSession?.fork?.reason, .retry)
        XCTAssertEqual(
            viewModel.currentSession?.messages.last(where: { $0.role == .assistant })?.content,
            "Recovered"
        )
    }

    func testEditAndResendCreatesEditedBranchOnlyOnSend() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"First answer"},"done":true}

        """)
        try await send("Original wording", with: viewModel)
        let originalSession = try XCTUnwrap(viewModel.currentSession)
        let userID = try XCTUnwrap(
            originalSession.messages.first(where: { $0.role == .user })?.id
        )
        viewModel.composerText = "Unrelated draft"

        viewModel.beginEditAndResend(userID)

        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.composerText, "Original wording")
        viewModel.composerText = "Edited wording"
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"Edited answer"},"done":true}

            """
        )
        let finished = expectation(description: "Edited send finished")
        observeCompletion(of: viewModel, fulfilling: finished)
        viewModel.send()
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == originalSession.id }),
            originalSession
        )
        XCTAssertEqual(viewModel.currentSession?.fork?.reason, .editAndResend)
        XCTAssertEqual(
            viewModel.currentSession?.messages.filter { $0.role == .user }.map(\.content),
            ["Edited wording"]
        )
        XCTAssertNil(viewModel.editAndResendSource)
    }

    func testEditNormalizesLegacyAttachmentsToEightUniqueItems() async throws {
        let root = try makeTemporaryRoot(prefix: "LegacyAttachmentReplay")
        let uniqueAttachments = (0..<9).map { index in
            AttachmentReference(
                displayName: "legacy-\(index).md",
                kind: .text,
                contentTypeIdentifier: "public.plain-text",
                byteCount: 10,
                sha256: "legacy-sha-\(index)",
                state: .ready
            )
        }
        let legacyAttachments = [uniqueAttachments[0]] + uniqueAttachments
        let userMessage = ChatMessage(
            role: .user,
            content: "Legacy attachment question",
            attachments: legacyAttachments
        )
        let sessionStore = try SessionStore(
            directory: root.appendingPathComponent("Sessions")
        )
        try await sessionStore.save(
            ChatSession(title: "Legacy", messages: [userMessage])
        )
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            sessionStore: sessionStore
        )
        try await viewModel.bootstrap()

        viewModel.beginEditAndResend(userMessage.id)

        XCTAssertEqual(viewModel.draftAttachments.count, 8)
        XCTAssertEqual(Set(viewModel.draftAttachments.map(\.sha256)).count, 8)
        XCTAssertTrue(viewModel.canSend)
    }

    func testCancelEditAndResendRestoresPreviousDraft() async throws {
        let viewModel = try await makeReadyViewModel(chatResponse: """
        {"message":{"content":"Answer"},"done":true}

        """)
        try await send("Original", with: viewModel)
        let userID = try XCTUnwrap(
            viewModel.currentSession?.messages.first(where: { $0.role == .user })?.id
        )
        viewModel.composerText = "Saved draft"

        viewModel.beginEditAndResend(userID)
        viewModel.cancelEditAndResend()

        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.composerText, "Saved draft")
        XCTAssertNil(viewModel.editAndResendSource)
    }

    func testAttachmentDataPersistsAfterChatsUntilExplicitLibraryDelete() async throws {
        let root = try makeTemporaryRoot(prefix: "AttachmentGC")
        let source = root.appendingPathComponent("shared.md")
        try Data("# Shared local attachment".utf8).write(to: source)
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments")
        )
        let attachment = try await attachmentStore.importFile(at: source)
        let parent = ChatSession(
            title: "Parent",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Read shared",
                    attachments: [attachment]
                )
            ]
        )
        let branch = ChatSession(
            title: "Branch",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Read shared again",
                    attachments: [attachment]
                )
            ],
            fork: SessionFork(
                parentSessionID: parent.id,
                parentTitle: parent.title,
                sourceMessageID: parent.messages[0].id,
                reason: .retry
            )
        )
        let store = try SessionStore(directory: root.appendingPathComponent("Sessions"))
        try await store.save(parent)
        try await store.save(branch)
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            sessionStore: store,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()

        await viewModel.deleteSession(parent.id)
        await Task.yield()
        let existsAfterParentDeletion = await attachmentStore.hasLocalData(
            for: attachment.id
        )
        XCTAssertTrue(existsAfterParentDeletion)

        await viewModel.deleteSession(branch.id)
        let existsAfterBranchDeletion = await attachmentStore.hasLocalData(
            for: attachment.id
        )
        XCTAssertTrue(existsAfterBranchDeletion)

        try await attachmentStore.deleteFromLibrary(id: attachment.id)
        let existsAfterExplicitDelete = await attachmentStore.hasLocalData(
            for: attachment.id
        )
        XCTAssertFalse(existsAfterExplicitDelete)
        await attachmentStore.close()
    }

    func testLibraryDocumentCanBeReusedThenExplicitlyDeleted() async throws {
        let root = try makeTemporaryRoot(prefix: "LibraryActions")
        let source = root.appendingPathComponent("library-item.md")
        try Data("LIBRARY-REUSE-FACT-22".utf8).write(to: source)
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await attachmentStore.importFile(at: source)
        let assistantID = UUID()
        let sessionStore = try SessionStore(
            directory: root.appendingPathComponent("Sessions", isDirectory: true)
        )
        let session = ChatSession(
            title: "Library history",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Read this",
                    attachments: [attachment]
                ),
                ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: "Read locally",
                    responseState: .complete
                )
            ]
        )
        try await sessionStore.save(session)
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            sessionStore: sessionStore,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()

        await viewModel.reloadLibrary(matching: "REUSE-FACT")
        let document = try XCTUnwrap(viewModel.libraryDocuments.first)
        XCTAssertEqual(document.id, attachment.id)

        await viewModel.addLibraryDocumentToDraft(document)
        await viewModel.addLibraryDocumentToDraft(document)
        XCTAssertEqual(viewModel.draftAttachments.map(\.id), [attachment.id])

        await viewModel.deleteDocumentFromLibrary(document)
        XCTAssertTrue(viewModel.libraryDocuments.isEmpty)
        XCTAssertTrue(viewModel.draftAttachments.isEmpty)
        let blobExists = await attachmentStore.hasLocalData(for: attachment.id)
        XCTAssertFalse(blobExists)
        let persisted = try await sessionStore.load()
        let persistedAttachment = persisted.first?.messages.first?.attachments?.first
        XCTAssertEqual(persistedAttachment?.state, .failed)
        XCTAssertEqual(persistedAttachment?.issue?.code, .deletedFromLibrary)
        let sessionCount = viewModel.sessions.count
        viewModel.regenerateAssistant(assistantID)
        XCTAssertEqual(viewModel.sessions.count, sessionCount)
        XCTAssertEqual(
            viewModel.statusMessage,
            "Deleted from the local Document Library."
        )
        await attachmentStore.close()
    }

    func testConcurrentLibraryAdditionsPreserveDeduplicationAndDraftLimit() async throws {
        let root = try makeTemporaryRoot(prefix: "ConcurrentLibraryAdds")
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        for index in 0..<9 {
            let source = root.appendingPathComponent("library-\(index).md")
            try Data("UNIQUE-LIBRARY-CONTENT-\(index)".utf8).write(to: source)
            _ = try await attachmentStore.importFile(at: source)
        }
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()
        await viewModel.reloadLibrary()
        let documents = viewModel.libraryDocuments
        XCTAssertEqual(documents.count, 9)

        for document in documents.prefix(7) {
            await viewModel.addLibraryDocumentToDraft(document)
        }
        let duplicateCandidate = documents[7]
        async let firstDuplicate: Void = viewModel.addLibraryDocumentToDraft(
            duplicateCandidate
        )
        async let secondDuplicate: Void = viewModel.addLibraryDocumentToDraft(
            duplicateCandidate
        )
        _ = await (firstDuplicate, secondDuplicate)
        XCTAssertEqual(viewModel.draftAttachments.count, 8)
        XCTAssertEqual(Set(viewModel.draftAttachments.map(\.sha256)).count, 8)

        viewModel.removeDraftAttachment(duplicateCandidate.id)
        async let firstAtLimit: Void = viewModel.addLibraryDocumentToDraft(
            documents[7]
        )
        async let secondAtLimit: Void = viewModel.addLibraryDocumentToDraft(
            documents[8]
        )
        _ = await (firstAtLimit, secondAtLimit)
        XCTAssertEqual(viewModel.draftAttachments.count, 8)
        XCTAssertEqual(Set(viewModel.draftAttachments.map(\.sha256)).count, 8)
        await attachmentStore.close()
    }

    func testQueuedImportsPreserveEarlierErrorsWhenLaterBatchSucceeds() async throws {
        let root = try makeTemporaryRoot(prefix: "QueuedImportErrors")
        let unsupported = root.appendingPathComponent("unsupported.bin")
        let valid = root.appendingPathComponent("valid.md")
        try Data([0x00, 0x01, 0x02]).write(to: unsupported)
        try Data("VALID-QUEUED-IMPORT".utf8).write(to: valid)
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try await makeViewModel()

        let unsupportedTask = Task {
            await viewModel.importAttachments([unsupported])
        }
        let validTask = Task {
            await viewModel.importAttachments([valid])
        }
        await unsupportedTask.value
        await validTask.value

        XCTAssertEqual(viewModel.draftAttachments.map(\.displayName), ["valid.md"])
        XCTAssertTrue(
            viewModel.attachmentErrorMessage?.contains("unsupported.bin") == true
        )
        XCTAssertTrue(viewModel.pendingAttachmentImports.isEmpty)
        XCTAssertFalse(viewModel.isImportingAttachments)
    }

    func testBootstrapRepairsHistoryAfterLibraryDeleteCrashWindow() async throws {
        let root = try makeTemporaryRoot(prefix: "DeletedHistoryRecovery")
        let source = root.appendingPathComponent("deleted-history.md")
        try Data("DELETED-HISTORY-FACT-44".utf8).write(to: source)
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await attachmentStore.importFile(at: source)
        let sessionStore = try SessionStore(
            directory: root.appendingPathComponent("Sessions", isDirectory: true)
        )
        let session = ChatSession(
            title: "Historical reference",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Read the file",
                    attachments: [attachment]
                )
            ]
        )
        try await sessionStore.save(session)
        try await attachmentStore.deleteFromLibrary(id: attachment.id)
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            sessionStore: sessionStore,
            attachmentStore: attachmentStore
        )

        try await viewModel.bootstrap()

        let recovered = viewModel.currentSession?.messages.first?
            .attachments?.first
        XCTAssertEqual(recovered?.state, .failed)
        XCTAssertEqual(recovered?.issue?.code, .deletedFromLibrary)
        let persisted = try await sessionStore.load().first?.messages.first?
            .attachments?.first
        XCTAssertEqual(persisted?.state, .failed)
        XCTAssertEqual(persisted?.issue?.code, .deletedFromLibrary)
        await attachmentStore.close()
    }

    func testImportMoreThanEightFilesReportsTheLimit() async throws {
        let root = try makeTemporaryRoot(prefix: "AttachmentLimit")
        let attachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        var urls: [URL] = []
        for index in 0..<9 {
            let url = root.appendingPathComponent("file-\(index).md")
            try Data("FILE-\(index)-UNIQUE-CONTENT".utf8).write(to: url)
            urls.append(url)
        }
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        let viewModel = try makeViewModel(
            root: root,
            attachmentStore: attachmentStore
        )
        try await viewModel.bootstrap()

        await viewModel.importAttachments(Array(urls.prefix(4)))
        await viewModel.importAttachments([urls[0]] + Array(urls.dropFirst(4)))

        XCTAssertEqual(viewModel.draftAttachments.count, 8)
        XCTAssertTrue(
            viewModel.attachmentErrorMessage?.contains(
                "A chat can include up to 8 files"
            ) == true
        )
        await attachmentStore.close()
    }

    private func makeReadyViewModel(
        chatResponse: String,
        terminalError: URLError? = nil,
        root: URL? = nil
    ) async throws -> ChatViewModel {
        enqueueVersion("0.32.15")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"models":[{"name":"qwen3.8:27b-mlx"}]}"#
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: chatResponse,
            terminalError: terminalError
        )
        if let root {
            let viewModel = try makeViewModel(root: root)
            try await viewModel.bootstrap()
            return viewModel
        }
        return try await makeViewModel()
    }

    private func makeViewModel(
        ollamaApplicationURL: (() -> URL?)? = nil,
        availableDiskBytes: (() -> Int64?)? = nil
    ) async throws -> ChatViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-ViewModel-\(UUID().uuidString)")
        temporaryRoots.append(root)
        let viewModel = try makeViewModel(
            root: root,
            ollamaApplicationURL: ollamaApplicationURL,
            availableDiskBytes: availableDiskBytes
        )
        try await viewModel.bootstrap()
        return viewModel
    }

    private func makeViewModel(
        root: URL,
        sessionStore: SessionStore? = nil,
        attachmentStore: AttachmentStore? = nil,
        webTools: WebToolExecutor = WebToolExecutor(),
        ollamaApplicationURL: (() -> URL?)? = nil,
        availableDiskBytes: (() -> Int64?)? = nil
    ) throws -> ChatViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let baseURL = URL(string: "http://127.0.0.1:11434")!
        let makeClient = {
            OllamaClient(
                baseURL: baseURL,
                sessionConfiguration: configuration,
                retryDelay: .zero
            )
        }
        return ChatViewModel(
            baseURL: "http://127.0.0.1:11434",
            selectedModel: "qwen3.8:27b-mlx",
            thinkingEnabled: false,
            sessionStore: try sessionStore ?? SessionStore(
                directory: root.appendingPathComponent("Sessions")
            ),
            memoryStore: try MemoryStore(
                directory: root.appendingPathComponent("Memories")
            ),
            logger: try EventLogger(
                directory: root.appendingPathComponent("Logs")
            ),
            ollamaClient: makeClient(),
            profileOllamaClient: makeClient(),
            memoryOllamaClient: makeClient(),
            webTools: webTools,
            attachmentStore: try attachmentStore ?? AttachmentStore(
                directory: root.appendingPathComponent("Attachments")
            ),
            memoryProcessingEnabled: false,
            ollamaApplicationURL: ollamaApplicationURL,
            availableDiskBytes: availableDiskBytes
        )
    }

    private func enqueueVersion(_ version: String) {
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: #"{"version":"\#(version)"}"#
        )
    }

    private func observeCompletion(
        of viewModel: ChatViewModel,
        fulfilling expectation: XCTestExpectation
    ) {
        viewModel.$isStreaming
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
    }

    private func observeMessage(
        in viewModel: ChatViewModel,
        containing text: String,
        fulfilling expectation: XCTestExpectation
    ) {
        viewModel.$transcriptRevision
            .filter { _ in
                viewModel.currentSession?.messages.contains {
                    $0.role == .assistant && $0.content.contains(text)
                } == true
            }
            .prefix(1)
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
    }

    private func send(_ prompt: String, with viewModel: ChatViewModel) async throws {
        let finished = expectation(description: "Initial generation finished")
        observeCompletion(of: viewModel, fulfilling: finished)
        viewModel.composerText = prompt
        viewModel.send()
        await fulfillment(of: [finished], timeout: 2)
    }

    private func makeTemporaryRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func lastRequestJSONObject() throws -> [String: Any] {
        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
    }

    private func documentProfileStreamBody(summary: String) throws -> String {
        let profile = try JSONSerialization.data(
            withJSONObject: [
                "summary": summary,
                "outline": ["Privacy review", "Milestone ALPHA-71"],
                "keywords": ["Harbor", "ALPHA-71"]
            ],
            options: [.sortedKeys]
        )
        let chunk = try JSONSerialization.data(
            withJSONObject: [
                "message": ["content": String(decoding: profile, as: UTF8.self)],
                "done": true
            ],
            options: [.sortedKeys]
        )
        return String(decoding: chunk, as: UTF8.self) + "\n"
    }

    private func makePDF(at url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: text,
                        attributes: [.font: NSFont.systemFont(ofSize: 18)]
                    )
                )
                context.textPosition = CGPoint(x: 54, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func makeRedImage(at url: URL) throws {
        let width = 320
        let height = 180
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.coderInvalidValue) }
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              )
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let continuations = waiters
        waiters = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor LocalSearchStub: LocalSearching {
    struct Call: Sendable {
        let query: String
        let radiusKilometers: Double
        let maximumResults: Int
    }

    enum Outcome: Sendable {
        case success(ToolResult)
        case failure(LocalContextError)
    }

    private(set) var calls: [Call] = []
    private let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func search(
        query: String,
        radiusKilometers: Double,
        maximumResults: Int,
        usesChineseLabels: Bool
    ) async throws -> ToolResult {
        calls.append(
            Call(
                query: query,
                radiusKilometers: radiusKilometers,
                maximumResults: maximumResults
            )
        )
        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
