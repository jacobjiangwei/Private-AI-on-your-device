import Foundation
import XCTest
@testable import PrivateAI

final class OllamaClientContractTests: XCTestCase {
    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func testIncrementalDecoderStreamsContentThinkingAndToolCalls() throws {
        let payload = """
        {"message":{"thinking":"checking "},"done":false}
        {"message":{"content":"Hello ","tool_calls":[{"index":0,"id":"weather-1","function":{"name":"web_search","arguments":{"query":"Suzhou weather"}}}]},"done":false}
        {"message":{"content":"world"},"done":true,"prompt_eval_count":21,"eval_count":5,"eval_duration":1000000000}
        """
        let bytes = Data(payload.utf8)
        let splitOffsets = [7, 43, 111, bytes.count]
        var decoder = OllamaStreamDecoder()
        var events: [OllamaStreamEvent] = []
        var start = 0

        for end in splitOffsets {
            events += try decoder.ingest(bytes[start..<end])
            start = end
        }
        let final = try decoder.finish(thinkingEnabled: true)
        events += final.events

        XCTAssertEqual(
            events,
            [.thinking("checking "), .content("Hello "), .content("world")]
        )
        XCTAssertEqual(final.result.content, "Hello world")
        XCTAssertEqual(final.result.thinking, "checking ")
        XCTAssertEqual(final.result.promptTokens, 21)
        XCTAssertEqual(final.result.outputTokens, 5)
        XCTAssertEqual(final.result.evaluationDurationNanoseconds, 1_000_000_000)
        XCTAssertEqual(
            final.result.toolCalls,
            [
                ToolInvocation(
                    id: "weather-1",
                    name: "web_search",
                    arguments: ["query": .string("Suzhou weather")]
                )
            ]
        )
    }

    func testClientAcceptsOnlyLoopbackOllamaURLs() async throws {
        let client = OllamaClient()

        try await client.setBaseURL("http://localhost:11434")
        try await client.setBaseURL("http://[::1]:11434")
        do {
            try await client.setBaseURL("https://ollama.example.com")
            XCTFail("Expected a non-loopback endpoint to be rejected")
        } catch OllamaError.invalidBaseURL {
        }
    }

    func testPreferredModelRequiresExactSupportedTag() {
        XCTAssertNil(
            OllamaClient.preferredModel(
                from: [OllamaModel(name: "qwen3:8b"), OllamaModel(name: "other")]
            )
        )
        XCTAssertEqual(
            OllamaClient.preferredModel(
                from: [
                    OllamaModel(name: "qwen3:8b"),
                    OllamaModel(name: OllamaClient.recommendedModelName)
                ]
            )?.name,
            OllamaClient.recommendedModelName
        )
    }

    func testIncrementalDecoderSurfacesStreamError() throws {
        var decoder = OllamaStreamDecoder()

        XCTAssertThrowsError(
            try decoder.ingest(Data("""
            {"error":"model runner stopped"}

            """.utf8))
        ) { error in
            guard case OllamaError.stream(let message) = error else {
                return XCTFail("Expected a stream error, got \(error)")
            }
            XCTAssertEqual(message, "model runner stopped")
        }
    }

    func testIncrementalDecoderRejectsMalformedJSON() throws {
        var decoder = OllamaStreamDecoder()

        XCTAssertThrowsError(
            try decoder.ingest(Data("{not-json}\n".utf8))
        ) { error in
            guard case OllamaError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testIncrementalDecoderRejectsEOFBeforeDone() throws {
        var decoder = OllamaStreamDecoder()
        let events = try decoder.ingest(
            Data(#"{"message":{"content":"partial"},"done":false}"#.utf8)
        )

        XCTAssertTrue(events.isEmpty)
        XCTAssertThrowsError(try decoder.finish(thinkingEnabled: false)) { error in
            guard case OllamaError.incompleteStream = error else {
                return XCTFail("Expected incompleteStream, got \(error)")
            }
        }
    }

    func testClientStreamsACompleteScriptedHTTPResponse() async throws {
        ScriptedURLProtocol.enqueue(statusCode: 200, body: """
        {"message":{"thinking":"plan"},"done":false}
        {"message":{"content":"answer"},"done":true,"prompt_eval_count":4,"eval_count":2,"eval_duration":500000000}

        """)
        let client = makeClient()
        let recorder = EventRecorder()

        let result = try await client.streamChat(
            model: "qwen3.8:27b-mlx",
            messages: [OllamaMessage(role: .user, content: "Hello")],
            thinking: true,
            toolsEnabled: false,
            utilityToolsEnabled: false,
            onEvent: { event in
                await recorder.append(event)
            }
        )

        let events = await recorder.events
        XCTAssertEqual(events, [.thinking("plan"), .content("answer")])
        XCTAssertEqual(result.content, "answer")
        XCTAssertEqual(result.thinking, "plan")
        XCTAssertEqual(result.promptTokens, 4)
        XCTAssertEqual(result.outputTokens, 2)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/chat")
        let requestData = try XCTUnwrap(request.httpBody)
        let requestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["model"] as? String, "qwen3.8:27b-mlx")
        XCTAssertEqual(requestJSON["stream"] as? Bool, true)
        let options = try XCTUnwrap(requestJSON["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 32_768)
        XCTAssertEqual(options["num_predict"] as? Int, 4_096)
    }

    func testClientRetriesOneServerFailure() async throws {
        ScriptedURLProtocol.enqueue(statusCode: 503, body: "runner unavailable")
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"recovered"},"done":true}

            """
        )
        let client = makeClient()

        let result = try await client.streamChat(
            model: "qwen3.8:27b-mlx",
            messages: [OllamaMessage(role: .user, content: "Retry")],
            thinking: false,
            toolsEnabled: false,
            utilityToolsEnabled: false,
            onEvent: { _ in }
        )

        XCTAssertEqual(result.content, "recovered")
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
    }

    func testClientSurfacesTimeoutWithoutRetry() async throws {
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: "",
            terminalError: URLError(.timedOut)
        )
        let client = makeClient()

        do {
            _ = try await client.streamChat(
                model: "qwen3.8:27b-mlx",
                messages: [OllamaMessage(role: .user, content: "Timeout")],
                thinking: false,
                toolsEnabled: false,
                utilityToolsEnabled: false,
                onEvent: { _ in }
            )
            XCTFail("Expected the scripted timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testClientEncodesVisionWithToolsAndThinking() async throws {
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"red"},"done":true}

            """
        )
        let client = makeClient()

        _ = try await client.streamChat(
            model: OllamaClient.recommendedModelName,
            messages: [
                OllamaMessage(
                    role: .user,
                    content: "What color?",
                    images: [Data("image".utf8).base64EncodedString()]
                )
            ],
            thinking: true,
            toolsEnabled: true,
            utilityToolsEnabled: true,
            localContextToolsEnabled: true,
            jsonFormat: false,
            contextWindow: 32_768,
            maximumOutputTokens: 8_192,
            onEvent: { _ in }
        )

        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["think"] as? Bool, true)
        XCTAssertFalse((object["tools"] as? [[String: Any]])?.isEmpty == true)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["images"] as? [String], ["aW1hZ2U="])
        let options = try XCTUnwrap(object["options"] as? [String: Any])
        XCTAssertEqual(options["num_predict"] as? Int, 8_192)
    }

    func testClientEncodesOnlyExplicitlyAllowedTools() async throws {
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"ok"},"done":true}

            """
        )
        let client = makeClient()

        _ = try await client.streamChat(
            model: OllamaClient.recommendedModelName,
            messages: [OllamaMessage(role: .user, content: "Where am I?")],
            thinking: false,
            toolsEnabled: true,
            utilityToolsEnabled: true,
            localContextToolsEnabled: true,
            allowedToolNames: ["local_context"],
            onEvent: { _ in }
        )

        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let names = tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["local_context"])
    }

    func testIndependentClientsDoNotCancelEachOthersStreams() async throws {
        let firstStarted = ContractSignal()
        let releaseFirst = ContractSignal()
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: """
            {"message":{"content":"first"},"done":true}

            """,
            onStart: { Task { await firstStarted.signal() } },
            waitForFinish: { await releaseFirst.wait() },
            onStop: {}
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: """
            {"message":{"content":"second"},"done":true}

            """
        )
        let firstClient = makeClient()
        let secondClient = makeClient()
        let firstTask = Task {
            try await firstClient.streamChat(
                model: "model-a",
                messages: [OllamaMessage(role: .user, content: "first")],
                thinking: false,
                toolsEnabled: false,
                onEvent: { _ in }
            )
        }
        await firstStarted.wait()

        let secondResult = try await secondClient.streamChat(
            model: "model-a",
            messages: [OllamaMessage(role: .user, content: "second")],
            thinking: false,
            toolsEnabled: false,
            onEvent: { _ in }
        )
        XCTAssertEqual(secondResult.content, "second")

        await releaseFirst.signal()
        let firstResult = try await firstTask.value
        XCTAssertEqual(firstResult.content, "first")
    }

    private func makeClient() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        return OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            sessionConfiguration: configuration,
            retryDelay: .zero
        )
    }
}

private actor EventRecorder {
    private(set) var events: [OllamaStreamEvent] = []

    func append(_ event: OllamaStreamEvent) {
        events.append(event)
    }
}

private actor ContractSignal {
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
        continuations.forEach { $0.resume() }
    }
}

final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    private enum Terminal {
        case finish
        case failure(URLError)
        case pending(
            onStart: @Sendable () -> Void,
            onStop: @Sendable () -> Void
        )
        case controlled(
            onStart: @Sendable () -> Void,
            waitForFinish: @Sendable () async -> Void,
            onStop: @Sendable () -> Void
        )
    }

    private struct Response {
        let statusCode: Int
        let body: Data
        let terminal: Terminal
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Response] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    private let pendingLock = NSLock()
    private var pendingStop: (@Sendable () -> Void)?
    private var controlledTask: Task<Void, Never>?

    static var requestCount: Int {
        lock.withLock { recordedRequests.count }
    }

    static var lastRequest: URLRequest? {
        lock.withLock { recordedRequests.last }
    }

    static func enqueue(
        statusCode: Int,
        body: String,
        terminalError: URLError? = nil
    ) {
        lock.withLock {
            responses.append(
                Response(
                    statusCode: statusCode,
                    body: Data(body.utf8),
                    terminal: terminalError.map(Terminal.failure) ?? .finish
                )
            )
        }
    }

    static func enqueuePending(
        statusCode: Int,
        body: String,
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            responses.append(
                Response(
                    statusCode: statusCode,
                    body: Data(body.utf8),
                    terminal: .pending(onStart: onStart, onStop: onStop)
                )
            )
        }
    }

    static func enqueueControlled(
        statusCode: Int,
        body: String,
        onStart: @escaping @Sendable () -> Void,
        waitForFinish: @escaping @Sendable () async -> Void,
        onStop: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            responses.append(
                Response(
                    statusCode: statusCode,
                    body: Data(body.utf8),
                    terminal: .controlled(
                        onStart: onStart,
                        waitForFinish: waitForFinish,
                        onStop: onStop
                    )
                )
            )
        }
    }

    static func reset() {
        lock.withLock {
            responses = []
            recordedRequests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.lock.withLock { () -> Response? in
            Self.recordedRequests.append(Self.capturingBody(of: request))
            guard !Self.responses.isEmpty else { return nil }
            return Self.responses.removeFirst()
        }
        guard let response,
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/x-ndjson"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        switch response.terminal {
        case .finish:
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .pending(let onStart, let onStop):
            pendingLock.withLock { pendingStop = onStop }
            onStart()
        case .controlled(let onStart, let waitForFinish, let onStop):
            pendingLock.withLock { pendingStop = onStop }
            onStart()
            let completion = URLProtocolCompletion(self)
            controlledTask = Task {
                await waitForFinish()
                guard !Task.isCancelled else { return }
                completion.finish()
            }
        }
    }

    override func stopLoading() {
        controlledTask?.cancel()
        controlledTask = nil
        let onStop = pendingLock.withLock { () -> (@Sendable () -> Void)? in
            defer { pendingStop = nil }
            return pendingStop
        }
        onStop?()
    }

    private static func capturingBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        var captured = request
        captured.httpBody = data
        return captured
    }
}

private final class URLProtocolCompletion: @unchecked Sendable {
    private weak var protocolInstance: ScriptedURLProtocol?

    init(_ protocolInstance: ScriptedURLProtocol) {
        self.protocolInstance = protocolInstance
    }

    func finish() {
        guard let protocolInstance else { return }
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }
}