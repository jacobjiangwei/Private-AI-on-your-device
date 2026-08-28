import Foundation
import XCTest
@testable import PrivateAI

final class DocumentAnalyzerTests: XCTestCase {
    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func testProfileIsGeneratedOnceCachedAndInvalidatedByModelDigest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-DocumentAnalyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("brief.md")
        try Data(
            "# Harbor Plan\n\nMilestone ALPHA-71 ships after privacy review.".utf8
        ).write(to: source)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await store.importFile(at: source)
        let client = makeClient()
        let analyzer = DocumentAnalyzer(
            attachmentStore: store,
            ollamaClient: client
        )
        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: try streamBody(
                summary: "Harbor Plan tracks milestone ALPHA-71.",
                outline: ["Privacy review", "Milestone ALPHA-71"],
                keywords: ["Harbor", "ALPHA-71"],
                fenced: true
            )
        )

        let first = try await analyzer.profile(
            for: attachment,
            modelName: OllamaClient.recommendedModelName,
            modelDigest: "digest-v1"
        )
        let cached = try await analyzer.profile(
            for: attachment,
            modelName: OllamaClient.recommendedModelName,
            modelDigest: "digest-v1"
        )

        XCTAssertEqual(first, cached)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(ScriptedURLProtocol.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["format"] as? String, "json")
        XCTAssertNil(object["tools"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertTrue(
            (messages.last?["content"] as? String)?
                .contains("ALPHA-71") == true
        )

        let context = try await store.context(
            for: [attachment],
            query: "What ships after privacy review?",
            profiles: [attachment.id: first]
        )
        XCTAssertEqual(context.profileCount, 1)
        XCTAssertTrue(context.text.contains("derived navigation only"))
        XCTAssertTrue(context.text.contains("Harbor Plan tracks milestone ALPHA-71"))
        XCTAssertTrue(context.text.contains("Milestone ALPHA-71 ships after privacy review"))

        ScriptedURLProtocol.enqueue(
            statusCode: 200,
            body: try streamBody(
                summary: "Updated model profile.",
                outline: ["Updated"],
                keywords: ["revision"]
            )
        )
        let changedModel = try await analyzer.profile(
            for: attachment,
            modelName: OllamaClient.recommendedModelName,
            modelDigest: "digest-v2"
        )

        XCTAssertEqual(changedModel.summary, "Updated model profile.")
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 2)
        await store.close()
    }

    func testLiveInstalledQwenCreatesAndCachesDocumentProfile() async throws {
        guard ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip(
                "Run the PrivateAI-Tests scheme to exercise local Qwen document analysis."
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-TestsDocumentAnalyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("launch-note.md")
        try Data(
            "# Launch Note\n\nProject codename is CEDAR-91. Privacy review completes before launch.".utf8
        ).write(to: source)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await store.importFile(at: source)
        let client = OllamaClient()
        let models = try await client.models()
        let model = try XCTUnwrap(
            models.first {
                $0.name == OllamaClient.recommendedModelName
            }
        )
        let digest = try XCTUnwrap(model.digest)
        let analyzer = DocumentAnalyzer(
            attachmentStore: store,
            ollamaClient: client
        )

        let generated = try await analyzer.profile(
            for: attachment,
            modelName: model.name,
            modelDigest: digest
        )
        let cached = try await analyzer.profile(
            for: attachment,
            modelName: model.name,
            modelDigest: digest
        )

        XCTAssertFalse(generated.summary.isEmpty)
        XCTAssertEqual(generated, cached)
        let stored = try await store.cachedAnalysis(
            for: DocumentAnalyzer.key(for: attachment, modelDigest: digest)
        )
        XCTAssertNotNil(stored)
        await store.close()
    }

    func testDeletingDocumentInvalidatesInFlightProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-AnalysisDelete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("delete-during-analysis.md")
        try Data("DELETE-WHILE-ANALYZING-51".utf8).write(to: source)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await store.importFile(at: source)
        let client = makeClient()
        let analyzer = DocumentAnalyzer(
            attachmentStore: store,
            ollamaClient: client
        )
        let started = AnalyzerSignal()
        let finish = AnalyzerSignal()
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: try streamBody(
                summary: "This must never be persisted.",
                outline: ["Deleted"],
                keywords: ["private"]
            ),
            onStart: { Task { await started.signal() } },
            waitForFinish: { await finish.wait() },
            onStop: {}
        )
        let analysisTask = Task {
            try await analyzer.profile(
                for: attachment,
                modelName: OllamaClient.recommendedModelName,
                modelDigest: "delete-race-digest"
            )
        }
        await started.wait()

        await analyzer.invalidate(documentSHA256: attachment.sha256)
        try await store.deleteFromLibrary(id: attachment.id)
        await finish.signal()

        do {
            _ = try await analysisTask.value
            XCTFail("Expected the stale analysis generation to be invalidated")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let cached = try await store.cachedAnalysis(
            for: DocumentAnalyzer.key(
                for: attachment,
                modelDigest: "delete-race-digest"
            )
        )
        XCTAssertNil(cached)
        await store.close()
    }

    func testConcurrentIdenticalProfilesUseOneQwenRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-AnalysisSingleFlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("single-flight.md")
        try Data("SINGLE-FLIGHT-QWEN-84".utf8).write(to: source)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await store.importFile(at: source)
        let analyzer = DocumentAnalyzer(
            attachmentStore: store,
            ollamaClient: makeClient()
        )
        let started = AnalyzerSignal()
        let finish = AnalyzerSignal()
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: try streamBody(
                summary: "One shared profile.",
                outline: ["Single flight"],
                keywords: ["Qwen"]
            ),
            onStart: { Task { await started.signal() } },
            waitForFinish: { await finish.wait() },
            onStop: {}
        )
        let first = Task {
            try await analyzer.profile(
                for: attachment,
                modelName: OllamaClient.recommendedModelName,
                modelDigest: "single-flight-digest"
            )
        }
        await started.wait()
        let second = Task {
            try await analyzer.profile(
                for: attachment,
                modelName: OllamaClient.recommendedModelName,
                modelDigest: "single-flight-digest"
            )
        }
        await Task.yield()
        await finish.signal()

        let firstProfile = try await first.value
        let secondProfile = try await second.value
        XCTAssertEqual(firstProfile, secondProfile)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        await store.close()
    }

    func testCancellingProfileStopsTransportAndSkipsCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-AnalysisCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cancel-profile.md")
        try Data("CANCEL-PROFILE-27".utf8).write(to: source)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await store.importFile(at: source)
        let analyzer = DocumentAnalyzer(
            attachmentStore: store,
            ollamaClient: makeClient()
        )
        let started = AnalyzerSignal()
        let stopped = AnalyzerSignal()
        ScriptedURLProtocol.enqueuePending(
            statusCode: 200,
            body: try streamBody(
                summary: "Cancelled profile.",
                outline: ["Cancel"],
                keywords: ["stop"]
            ),
            onStart: { Task { await started.signal() } },
            onStop: { Task { await stopped.signal() } }
        )
        let task = Task {
            try await analyzer.profile(
                for: attachment,
                modelName: OllamaClient.recommendedModelName,
                modelDigest: "cancel-profile-digest"
            )
        }
        await started.wait()

        task.cancel()
        await stopped.wait()

        do {
            _ = try await task.value
            XCTFail("Expected profile generation to stop")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        let cached = try await store.cachedAnalysis(
            for: DocumentAnalyzer.key(
                for: attachment,
                modelDigest: "cancel-profile-digest"
            )
        )
        XCTAssertNil(cached)
        await store.close()
    }

    func testCancellingOneWaiterKeepsSharedProfileRunning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-AnalysisWaiters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("shared-waiters.md")
        try Data("SHARED-WAITER-19".utf8).write(to: source)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let attachment = try await store.importFile(at: source)
        let analyzer = DocumentAnalyzer(
            attachmentStore: store,
            ollamaClient: makeClient()
        )
        let started = AnalyzerSignal()
        let finish = AnalyzerSignal()
        let transport = AnalyzerTransportState()
        ScriptedURLProtocol.enqueueControlled(
            statusCode: 200,
            body: try streamBody(
                summary: "Shared waiter profile.",
                outline: ["Shared"],
                keywords: ["waiter"]
            ),
            onStart: { Task { await started.signal() } },
            waitForFinish: { await finish.wait() },
            onStop: { Task { await transport.markStopped() } }
        )
        let key = DocumentAnalyzer.key(
            for: attachment,
            modelDigest: "shared-waiter-digest"
        )
        let first = Task {
            try await analyzer.profile(
                for: attachment,
                modelName: OllamaClient.recommendedModelName,
                modelDigest: key.modelDigest
            )
        }
        await started.wait()
        let second = Task {
            try await analyzer.profile(
                for: attachment,
                modelName: OllamaClient.recommendedModelName,
                modelDigest: key.modelDigest
            )
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline,
              await analyzer.inFlightWaiterCount(for: key) < 2 {
            await Task.yield()
        }
        let initialWaiterCount = await analyzer.inFlightWaiterCount(for: key)
        XCTAssertEqual(initialWaiterCount, 2)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected the first waiter to cancel")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let stoppedAfterFirstCancellation = await transport.isStopped
        let remainingWaiterCount = await analyzer.inFlightWaiterCount(for: key)
        XCTAssertFalse(stoppedAfterFirstCancellation)
        XCTAssertEqual(remainingWaiterCount, 1)

        await finish.signal()
        let profile = try await second.value
        XCTAssertEqual(profile.summary, "Shared waiter profile.")
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        await store.close()
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

    private func streamBody(
        summary: String,
        outline: [String],
        keywords: [String],
        fenced: Bool = false
    ) throws -> String {
        let profile = try JSONSerialization.data(
            withJSONObject: [
                "summary": summary,
                "outline": outline,
                "keywords": keywords
            ],
            options: [.sortedKeys]
        )
        let rawProfile = String(decoding: profile, as: UTF8.self)
        let content = fenced ? "```json\n\(rawProfile)\n```" : rawProfile
        let chunk = try JSONSerialization.data(
            withJSONObject: [
            "message": ["content": content],
                "done": true,
                "prompt_eval_count": 20,
                "eval_count": 12
            ],
            options: [.sortedKeys]
        )
        return String(decoding: chunk, as: UTF8.self) + "\n"
    }
}

private actor AnalyzerSignal {
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

private actor AnalyzerTransportState {
    private(set) var isStopped = false

    func markStopped() {
        isStopped = true
    }
}