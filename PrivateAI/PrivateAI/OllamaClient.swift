import Foundation

public struct OllamaModel: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let digest: String?
    public let size: Int64?

    public init(name: String, digest: String? = nil, size: Int64? = nil) {
        self.name = name
        self.digest = digest
        self.size = size
    }
}

public struct OllamaToolCall: Codable, Hashable, Sendable {
    public struct Function: Codable, Hashable, Sendable {
        public let name: String
        public let arguments: [String: JSONValue]

        public init(name: String, arguments: [String: JSONValue]) {
            self.name = name
            self.arguments = arguments
        }
    }

    public let id: String?
    public let function: Function

    public init(id: String? = nil, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.function = Function(name: name, arguments: arguments)
    }
}

public struct OllamaMessage: Codable, Hashable, Sendable {
    public let role: ChatRole
    public let content: String
    public let toolCalls: [OllamaToolCall]?
    public let images: [String]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case images
    }

    public init(
        role: ChatRole,
        content: String,
        toolCalls: [OllamaToolCall]? = nil,
        images: [String]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.images = images
    }
}

public struct ToolCallDelta: Equatable, Sendable {
    public let index: Int
    public let id: String?
    public let nameFragment: String
    public let argumentsFragment: String

    public init(
        index: Int,
        id: String? = nil,
        nameFragment: String = "",
        argumentsFragment: String = ""
    ) {
        self.index = index
        self.id = id
        self.nameFragment = nameFragment
        self.argumentsFragment = argumentsFragment
    }
}

public struct ToolCallAccumulator: Sendable {
    private struct Partial: Sendable {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: Partial] = [:]

    public init() {}

    public mutating func append(_ delta: ToolCallDelta) {
        var partial = partials[delta.index] ?? Partial()
        if partial.id == nil { partial.id = delta.id }
        if !delta.nameFragment.isEmpty {
            if partial.name.isEmpty {
                partial.name = delta.nameFragment
            } else if partial.name != delta.nameFragment {
                partial.name += delta.nameFragment
            }
        }
        if !delta.argumentsFragment.isEmpty {
            if delta.argumentsFragment.first == "{", delta.argumentsFragment.last == "}" {
                partial.arguments = delta.argumentsFragment
            } else {
                partial.arguments += delta.argumentsFragment
            }
        }
        partials[delta.index] = partial
    }

    public func invocations() -> [ToolInvocation] {
        partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            let arguments: [String: JSONValue]
            if let data = partial.arguments.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                arguments = decoded
            } else {
                arguments = [:]
            }
            return ToolInvocation(
                id: partial.id ?? "call-\(index)",
                name: partial.name,
                arguments: arguments
            )
        }
    }
}

public enum OllamaStreamEvent: Equatable, Sendable {
    case content(String)
    case replaceContent(String)
    case thinking(String)
}

public enum OllamaContentNormalizer {
    public static func visibleContent(_ content: String, thinkingEnabled: Bool) -> String {
        guard !thinkingEnabled else { return content }
        let markers = ["</think>", "</antThinking>", "</analysis>"]
        let withoutTaggedThinking: String
        if let marker = markers.compactMap({
            content.range(of: $0, options: [.caseInsensitive, .backwards])
        }).max(by: { $0.upperBound < $1.upperBound }) {
            withoutTaggedThinking = String(content[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutTaggedThinking = content
        }
        return removingPlanningPreamble(from: withoutTaggedThinking)
    }

    private static func removingPlanningPreamble(from content: String) -> String {
        let paragraphs = content.components(separatedBy: "\n\n")
        guard let first = paragraphs.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !first.isEmpty else { return content }

        let analysisStarts = [
            "the user is asking", "the user asks", "the user wants", "the user needs",
            "用户在问", "用户想", "用户需要"
        ]
        if analysisStarts.contains(where: { $0.hasPrefix(first) }) {
            return ""
        }
        let toolNarrationStarts = [
            "let me call", "let me use", "i should call", "i should use",
            "i need to call", "i need to use", "i'll call", "i'll use",
            "让我调用", "我需要调用", "我应该调用", "接下来调用"
        ]
        if toolNarrationStarts.contains(where: { $0.hasPrefix(first) }) {
            return ""
        }
        let isAnalysis = analysisStarts.contains(where: first.hasPrefix)
        let isToolNarration = toolNarrationStarts.contains(where: first.hasPrefix)
        guard isAnalysis || isToolNarration else { return content }

        let planningPrefixes = [
            "the user ", "i should ", "i need to ", "i will ", "i'll ",
            "let me ", "we need to ", "用户", "我应该", "我需要", "让我", "接下来"
        ]
        let visible = paragraphs.drop { paragraph in
            let normalized = paragraph
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return planningPrefixes.contains(where: normalized.hasPrefix)
        }.joined(separator: "\n\n")
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OllamaStreamResult: Sendable {
    public let content: String
    public let thinking: String
    public let toolCalls: [ToolInvocation]
    public let promptTokens: Int
    public let outputTokens: Int
    public let evaluationDurationNanoseconds: UInt64

    public init(
        content: String,
        thinking: String,
        toolCalls: [ToolInvocation],
        promptTokens: Int,
        outputTokens: Int,
        evaluationDurationNanoseconds: UInt64
    ) {
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.evaluationDurationNanoseconds = evaluationDurationNanoseconds
    }
}

public enum OllamaError: LocalizedError, Sendable {
    case invalidBaseURL
    case invalidResponse
    case incompleteStream
    case stream(message: String)
    case server(status: Int, message: String)
    case noModels

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: String(localized: "The Ollama URL is invalid.")
        case .invalidResponse: String(localized: "Ollama returned an invalid response.")
        case .incompleteStream: String(localized: "The Ollama response ended before it completed.")
        case .stream(let message): String(localized: "Ollama stream error: \(message)")
        case .server(let status, let message): String(localized: "Ollama HTTP \(status): \(message)")
        case .noModels: String(localized: "No local Ollama models are installed.")
        }
    }
}

public actor OllamaClient {
    public static let localBaseURL = URL(string: "http://127.0.0.1:11434")!
    public static let minimumVersion = "0.32.12"
    public static let recommendedModelName = "qwen3.8:27b-mlx"
    public static let recommendedModelSizeBytes: Int64 = 18_174_721_847
    public static let pullCommand = "ollama pull qwen3.8:27b-mlx"
    public static let downloadPage = URL(string: "https://ollama.com/download/mac")!
    public static let modelPage = URL(
        string: "https://ollama.com/library/qwen3.8:27b-mlx"
    )!

    private var baseURL: URL
    private let sessionConfiguration: URLSessionConfiguration
    private let retryDelay: Duration
    private var activeSession: URLSession?

    public init(baseURL: URL = OllamaClient.localBaseURL) {
        self.baseURL = baseURL
        self.sessionConfiguration = .ephemeral
        self.retryDelay = .milliseconds(300)
    }

    init(
        baseURL: URL,
        sessionConfiguration: URLSessionConfiguration,
        retryDelay: Duration = .milliseconds(300)
    ) {
        self.baseURL = baseURL
        self.sessionConfiguration = sessionConfiguration
        self.retryDelay = retryDelay
    }

    public func setBaseURL(_ rawValue: String) throws {
        guard let value = URL(string: rawValue),
              value.scheme == "http",
              let host = value.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1"
        else { throw OllamaError.invalidBaseURL }
        baseURL = value
    }

    public func models() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { throw OllamaError.invalidResponse }
        return try JSONDecoder().decode(ModelList.self, from: data).models
    }

    public func version() async throws -> String {
        let url = baseURL.appendingPathComponent("api/version")
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { throw OllamaError.invalidResponse }
        return try JSONDecoder().decode(VersionResponse.self, from: data).version
    }

    public static func preferredModel(from models: [OllamaModel]) -> OllamaModel? {
        models.first { $0.name == recommendedModelName }
    }

    public func streamChat(
        model: String,
        messages: [OllamaMessage],
        thinking: Bool,
        toolsEnabled: Bool,
        utilityToolsEnabled: Bool = true,
        localContextToolsEnabled: Bool = false,
        allowedToolNames: Set<String>? = nil,
        jsonFormat: Bool = false,
        contextWindow: Int = ContextPlanner.defaultContextWindow,
        maximumOutputTokens: Int = ContextPlanner.fastOutputReserve,
        onEvent: @escaping @Sendable (OllamaStreamEvent) async -> Void
    ) async throws -> OllamaStreamResult {
        do {
            return try await streamChatOnce(
                model: model,
                messages: messages,
                thinking: thinking,
                toolsEnabled: toolsEnabled,
                utilityToolsEnabled: utilityToolsEnabled,
                localContextToolsEnabled: localContextToolsEnabled,
                allowedToolNames: allowedToolNames,
                jsonFormat: jsonFormat,
                contextWindow: contextWindow,
                maximumOutputTokens: maximumOutputTokens,
                onEvent: onEvent
            )
        } catch OllamaError.server(let status, _) where status >= 500 {
            try await Task.sleep(for: retryDelay)
            return try await streamChatOnce(
                model: model,
                messages: messages,
                thinking: thinking,
                toolsEnabled: toolsEnabled,
                utilityToolsEnabled: utilityToolsEnabled,
                localContextToolsEnabled: localContextToolsEnabled,
                allowedToolNames: allowedToolNames,
                jsonFormat: jsonFormat,
                contextWindow: contextWindow,
                maximumOutputTokens: maximumOutputTokens,
                onEvent: onEvent
            )
        }
    }

    private func streamChatOnce(
        model: String,
        messages: [OllamaMessage],
        thinking: Bool,
        toolsEnabled: Bool,
        utilityToolsEnabled: Bool,
        localContextToolsEnabled: Bool,
        allowedToolNames: Set<String>?,
        jsonFormat: Bool,
        contextWindow: Int,
        maximumOutputTokens: Int,
        onEvent: @escaping @Sendable (OllamaStreamEvent) async -> Void
    ) async throws -> OllamaStreamResult {
        let endpoint = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ChatRequest(
            model: model,
            messages: messages,
            stream: true,
            think: thinking,
            tools: Self.toolDefinitions(
                informationToolsEnabled: toolsEnabled,
                utilityToolsEnabled: utilityToolsEnabled,
                localContextToolsEnabled: localContextToolsEnabled,
                allowedToolNames: allowedToolNames
            ),
            format: jsonFormat ? "json" : nil,
            options: [
                "num_ctx": .number(Double(contextWindow)),
                "num_predict": .number(Double(maximumOutputTokens)),
                "temperature": .number(0.2)
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        activeSession?.invalidateAndCancel()
        activeSession = session
        defer {
            session.finishTasksAndInvalidate()
            if activeSession === session { activeSession = nil }
        }

        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in bytes.prefix(16_000) { body.append(byte) }
            throw OllamaError.server(
                status: response.statusCode,
                message: String(decoding: body, as: UTF8.self)
            )
        }

        var decoder = OllamaStreamDecoder()
        var incoming = Data()

        for try await byte in bytes {
            try Task.checkCancellation()
            incoming.append(byte)
            if byte == 0x0A || incoming.count >= 4_096 {
                for event in try decoder.ingest(incoming) {
                    await onEvent(event)
                }
                incoming.removeAll(keepingCapacity: true)
            }
        }
        if !incoming.isEmpty {
            for event in try decoder.ingest(incoming) {
                await onEvent(event)
            }
        }
        let final = try decoder.finish(thinkingEnabled: thinking)
        for event in final.events {
            await onEvent(event)
        }
        return final.result
    }

    public func cancel() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    private func makeSession() -> URLSession {
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        return URLSession(configuration: configuration)
    }

    private static func toolDefinitions(
        informationToolsEnabled: Bool,
        utilityToolsEnabled: Bool,
        localContextToolsEnabled: Bool,
        allowedToolNames: Set<String>?
    ) -> [ToolDefinition]? {
        var tools: [ToolDefinition] = []
        if localContextToolsEnabled { tools.append(localContextTool) }
        if utilityToolsEnabled { tools.append(codeInterpreterTool) }
        if informationToolsEnabled { tools.append(contentsOf: webTools) }
        if let allowedToolNames {
            tools.removeAll {
                !allowedToolNames.contains($0.function.name)
            }
        }
        return tools.isEmpty ? nil : tools
    }

    private static let localContextTool = ToolDefinition(
        name: "local_context",
        description: """
        Read current information from this Mac only when it is relevant. Request the minimum fields. \
        time, locale, device, power, storage, and local_network are local reads. location uses macOS \
        Core Location, may request system permission, and may use Apple system reverse geocoding for \
        city/region/country without returning a street address. public_ip makes a keyless external \
        lookup that sends no conversation content.
        """,
        properties: [
            "fields": Property(
                type: "array",
                description: "One or more local context fields.",
                itemEnum: LocalContextField.allCases.map(\.rawValue)
            )
        ],
        required: ["fields"]
    )

    private static let codeInterpreterTool = ToolDefinition(
        name: "code_interpreter",
        description: """
        Evaluate one bounded JavaScript expression locally with no file, network, shell, loops, \
        functions, or mutation. Use only when deterministic computation is necessary: numeric \
        arithmetic, JSON operations, array statistics, sorting, or deduplication. Never use this \
        tool for prose, drafting, rewriting, translation, summarization, or ordinary string replacement; \
        answer those requests directly. Never pass a plain string, completed answer, quoted sentence, \
        or a chain of string replacements as the expression. Helpers include sum, mean, median, min, max, \
        sort, unique, and count.
        """,
        properties: [
            "expression": Property(
                type: "string",
                description: "A numeric or structured-data JavaScript expression, such as sum([1,2,3]); never a string literal, prose, rewriting, or translation."
            )
        ],
        required: ["expression"]
    )

    private static var webTools: [ToolDefinition] {
        var tools = [
            ToolDefinition(
            name: "local_search",
            description: """
            Search nearby places with Apple Maps using the Mac's current Core Location. Use for \
            restaurants, cafes, shops, pharmacies, hotels, parks, and other nearby businesses.
            """,
            properties: [
                "query": Property(
                    type: "string",
                    description: "Natural-language place query, such as restaurants or coffee"
                ),
                "radius_km": Property(
                    type: "number",
                    description: "Search radius in kilometers, 0.5 through 50"
                ),
                "max_results": Property(
                    type: "integer",
                    description: "Maximum places to return, 1 through 12"
                )
            ],
            required: ["query"]
            ),
            ToolDefinition(
            name: "web_search",
            description: "Search the public web. Use for current or sourced information.",
            properties: [
                "query": Property(type: "string", description: "Search query"),
                "max_results": Property(type: "integer", description: "Number of results, 1 through 8")
            ],
            required: ["query"]
            ),
            ToolDefinition(
            name: "fetch_url",
            description: "Fetch bounded readable text directly from a public HTTP(S) URL.",
            properties: ["url": Property(type: "string", description: "Public HTTP(S) URL")],
            required: ["url"]
            )
        ]
        #if !APP_STORE
        tools.append(ToolDefinition(
            name: "browser_snapshot",
            description: "Open a public page in system Chrome and return bounded visible text and links.",
            properties: ["url": Property(type: "string", description: "Public HTTP(S) URL")],
            required: ["url"]
        ))
        tools.append(ToolDefinition(
            name: "browser_extract",
            description: "Open a public page and return bounded inner text for one CSS selector.",
            properties: [
                "url": Property(type: "string", description: "Public HTTP(S) URL"),
                "selector": Property(type: "string", description: "CSS selector")
            ],
            required: ["url", "selector"]
        ))
        #endif
        return tools
    }
}

private struct ModelList: Decodable {
    let models: [OllamaModel]
}

private struct VersionResponse: Decodable {
    let version: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
    let tools: [ToolDefinition]?
    let format: String?
    let options: [String: JSONValue]
}

private struct ToolDefinition: Encodable {
    struct Function: Encodable {
        struct Parameters: Encodable {
            let type = "object"
            let properties: [String: Property]
            let required: [String]
        }

        let name: String
        let description: String
        let parameters: Parameters
    }

    let type = "function"
    let function: Function

    init(name: String, description: String, properties: [String: Property], required: [String]) {
        self.function = Function(
            name: name,
            description: description,
            parameters: Function.Parameters(properties: properties, required: required)
        )
    }
}

private struct Property: Encodable {
    struct Items: Encodable {
        let type = "string"
        let values: [String]

        enum CodingKeys: String, CodingKey {
            case type
            case values = "enum"
        }
    }

    let type: String
    let description: String
    let items: Items?

    init(type: String, description: String, itemEnum: [String]? = nil) {
        self.type = type
        self.description = description
        self.items = itemEnum.map(Items.init(values:))
    }
}

struct OllamaStreamDecoder: Sendable {
    private var line = Data()
    private var content = ""
    private var thinking = ""
    private var accumulator = ToolCallAccumulator()
    private var promptTokens = 0
    private var outputTokens = 0
    private var evaluationDuration: UInt64 = 0
    private var completed = false

    mutating func ingest(_ data: Data) throws -> [OllamaStreamEvent] {
        var events: [OllamaStreamEvent] = []
        for byte in data {
            if byte == 0x0A {
                if !line.isEmpty {
                    events.append(contentsOf: try processLine())
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                if line.count > 1_000_000 { throw OllamaError.invalidResponse }
            }
        }
        return events
    }

    mutating func finish(
        thinkingEnabled: Bool
    ) throws -> (events: [OllamaStreamEvent], result: OllamaStreamResult) {
        var events: [OllamaStreamEvent] = []
        if !line.isEmpty {
            events.append(contentsOf: try processLine())
            line.removeAll(keepingCapacity: true)
        }
        guard completed else { throw OllamaError.incompleteStream }

        let visibleContent = OllamaContentNormalizer.visibleContent(
            content,
            thinkingEnabled: thinkingEnabled
        )
        if visibleContent != content {
            events.append(.replaceContent(visibleContent))
        }
        return (
            events,
            OllamaStreamResult(
                content: visibleContent,
                thinking: thinking,
                toolCalls: accumulator.invocations(),
                promptTokens: promptTokens,
                outputTokens: outputTokens,
                evaluationDurationNanoseconds: evaluationDuration
            )
        )
    }

    private mutating func processLine() throws -> [OllamaStreamEvent] {
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: line) else {
            throw OllamaError.invalidResponse
        }
        if let message = chunk.error, !message.isEmpty {
            throw OllamaError.stream(message: message)
        }

        var events: [OllamaStreamEvent] = []
        if let value = chunk.message?.content, !value.isEmpty {
            content += value
            events.append(.content(value))
        }
        if let value = chunk.message?.thinking, !value.isEmpty {
            thinking += value
            events.append(.thinking(value))
        }
        for (offset, call) in (chunk.message?.toolCalls ?? []).enumerated() {
            accumulator.append(
                ToolCallDelta(
                    index: call.index ?? offset,
                    id: call.id,
                    nameFragment: call.function?.name ?? "",
                    argumentsFragment: call.function?.arguments.jsonFragment ?? ""
                )
            )
        }
        promptTokens = chunk.promptEvalCount ?? promptTokens
        outputTokens = chunk.evalCount ?? outputTokens
        evaluationDuration = chunk.evalDuration ?? evaluationDuration
        completed = completed || chunk.done == true
        return events
    }
}

private struct StreamChunk: Decodable {
    struct Message: Decodable {
        let content: String?
        let thinking: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case thinking
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: Arguments
        }

        let index: Int?
        let id: String?
        let function: Function?
    }

    enum Arguments: Decodable {
        case string(String)
        case value(JSONValue)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
            } else {
                self = .value(try container.decode(JSONValue.self))
            }
        }

        var jsonFragment: String {
            switch self {
            case .string(let value): value
            case .value(let value): value.jsonString()
            }
        }
    }

    let message: Message?
    let done: Bool?
    let error: String?
    let promptEvalCount: Int?
    let evalCount: Int?
    let evalDuration: UInt64?

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case error
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}
