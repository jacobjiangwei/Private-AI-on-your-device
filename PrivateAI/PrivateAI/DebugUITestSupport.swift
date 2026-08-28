#if DEBUG
import Foundation

@MainActor private var didPrepareUITestRoot = false
@MainActor private var didInjectStartupFailure = false

private enum DebugStartupError: LocalizedError {
    case simulated

    var errorDescription: String? {
        "The local document library could not be opened."
    }
}

extension ChatViewModel {
    static func configuredForLaunch() async throws -> ChatViewModel {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(where: { $0.hasPrefix("--privateai-ui-test") }) else {
            return try await productionForLaunch()
        }
        if arguments.contains("--privateai-ui-test-startup-failure-once"),
           !didInjectStartupFailure {
            didInjectStartupFailure = true
            throw DebugStartupError.simulated
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrivateAI-UITests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        if !didPrepareUITestRoot {
            try? FileManager.default.removeItem(at: root)
            didPrepareUITestRoot = true
        }
        DebugUITestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugUITestURLProtocol.self]
        let baseURL = URL(string: "http://127.0.0.1:11434")!
        let applicationURL: (() -> URL?)? = arguments.contains(
            "--privateai-ui-test-missing-ollama"
        ) ? { nil } : nil
        let diskBytes: (() -> Int64?)? = arguments.contains(
            "--privateai-ui-test-missing-model"
        ) ? { 42_000_000_000 } : nil
        let stores = try await Task.detached(priority: .userInitiated) {
            try LocalChatStores(root: root)
        }.value
        if arguments.contains("--privateai-ui-test-store-assets") {
            try await prepareStoreAssetFixtures(stores: stores, root: root)
        }
        if arguments.contains("--privateai-ui-test-library") {
            let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
            try FileManager.default.createDirectory(
                at: fixtures,
                withIntermediateDirectories: true
            )
            let document = fixtures.appendingPathComponent("library-fixture.md")
            try Data(
                "# Library fixture\n\nLIBRARY-UI-SEARCH-73".utf8
            ).write(to: document, options: .atomic)
            _ = try await stores.attachments.importFile(at: document)
        }
        let makeClient = {
            OllamaClient(
                baseURL: baseURL,
                sessionConfiguration: configuration,
                retryDelay: .zero
            )
        }
        return ChatViewModel(
            baseURL: baseURL.absoluteString,
            selectedModel: "qwen3.8:27b-mlx",
            thinkingEnabled: false,
            sessionStore: stores.sessions,
            memoryStore: stores.memories,
            logger: stores.logger,
            ollamaClient: makeClient(),
            profileOllamaClient: makeClient(),
            memoryOllamaClient: makeClient(),
            attachmentStore: stores.attachments,
            memoryProcessingEnabled: false,
            ollamaApplicationURL: applicationURL,
            availableDiskBytes: diskBytes
        )
    }

    private static func prepareStoreAssetFixtures(
        stores: LocalChatStores,
        root: URL
    ) async throws {
        let usesSimplifiedChinese = Locale.preferredLanguages.first?
            .hasPrefix("zh") == true
        let fixtures = root.appendingPathComponent("StoreAssets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtures,
            withIntermediateDirectories: true
        )
        let document = fixtures.appendingPathComponent("product-brief.md")
                let documentText = usesSimplifiedChinese
                        ? """
                            # PrivateAI 产品简介

                            PrivateAI 将模型推理、对话和文档分析保留在这台 Mac 上。用户明确选择文件，并可从资料库中移除保留的文档数据。
                            """
                        : """
                            # PrivateAI Product Brief

                            PrivateAI keeps model inference, conversations, and document analysis on this Mac. Users explicitly choose files and can remove retained document data from the Library.
                            """
                try Data(documentText.utf8).write(to: document, options: .atomic)
        let attachment = try await stores.attachments.importFile(at: document)
                let title = usesSimplifiedChinese ? "本地文档分析" : "Local document analysis"
                let prompt = usesSimplifiedChinese
                        ? "总结这份产品简介，并指出它的隐私承诺。"
                        : "Summarize the product brief and identify its privacy promise."
                let answer = usesSimplifiedChinese
                        ? """
                            ## PrivateAI 概览

                            PrivateAI 是一款**本地优先的 Mac 助手**。对话、文档提取和模型推理都通过 Ollama 保留在这台 Mac 上。

                            - 仅在获得明确的 macOS 授权后添加文件。
                            - 导入的文档会保留在本地资料库中并可搜索。
                            - 随时可以永久删除已保存的文档数据。

                            核心承诺是：为敏感工作提供实用的 AI，同时不需要云端模型账户、订阅或按 token 付费。
                            """
                        : """
                            ## PrivateAI at a glance

                            PrivateAI is a **local-first Mac assistant**. Conversations, document extraction, and model inference stay on this Mac through Ollama.

                            - Files are added only after explicit macOS authorization.
                            - Imported documents remain searchable in the local Library.
                            - Stored document data can be permanently removed at any time.

                            The core promise is useful AI for sensitive work without a cloud-model account, subscription, or per-token fee.
                            """
        let session = ChatSession(
                        title: title,
            createdAt: Date(timeIntervalSince1970: 1_787_874_400),
            updatedAt: Date(timeIntervalSince1970: 1_787_874_460),
            messages: [
                ChatMessage(
                    role: .user,
                    content: prompt,
                    attachments: [attachment]
                ),
                ChatMessage(
                    role: .assistant,
                    content: answer,
                    responseState: .complete
                )
            ]
        )
        try await stores.sessions.save(session, revision: 1)
    }
}

private final class DebugUITestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chatRequestCount = 0

    static func reset() {
        lock.withLock { chatRequestCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        let contentType: String
        let arguments = ProcessInfo.processInfo.arguments
        switch url.path {
        case "/api/version":
            if arguments.contains("--privateai-ui-test-missing-ollama") {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            body = Data(#"{"version":"0.32.15"}"#.utf8)
            contentType = "application/json"
        case "/api/tags":
            body = arguments.contains("--privateai-ui-test-missing-model")
                ? Data(#"{"models":[]}"#.utf8)
                : Data(#"{"models":[{"name":"qwen3.8:27b-mlx"},{"name":"llama3.2:latest"}]}"#.utf8)
            contentType = "application/json"
        case "/api/chat":
            let requestNumber = Self.lock.withLock { () -> Int in
                Self.chatRequestCount += 1
                return Self.chatRequestCount
            }
            if arguments.contains("--privateai-ui-test-failed-chat"),
               requestNumber == 1 {
                body = Data("""
                {"message":{"content":"Partial fixture"},"done":false}
                {not-json}

                """.utf8)
            } else if arguments.contains("--privateai-ui-test-failed-chat") {
                body = Data("""
                {"message":{"content":"Recovered fixture"},"done":true,"prompt_eval_count":5,"eval_count":4,"eval_duration":400000000}

                """.utf8)
            } else {
                body = Data("""
                {"message":{"content":"Hello from local Qwen fixture"},"done":true,"prompt_eval_count":4,"eval_count":6,"eval_duration":500000000}

                """.utf8)
            }
            contentType = "application/x-ndjson"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#else
extension ChatViewModel {
    static func configuredForLaunch() async throws -> ChatViewModel {
        try await productionForLaunch()
    }
}
#endif