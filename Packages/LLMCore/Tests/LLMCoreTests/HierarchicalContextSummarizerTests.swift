import Foundation
import Testing
@testable import LLMCore

@Suite("Hierarchical Context Summarizer")
struct HierarchicalContextSummarizerTests {
    @Test("reduces many materials recursively and reuses local checkpoints")
    func recursiveReductionAndResume() async throws {
        let provider = FactPreservingProvider()
        let store = InMemorySummaryStore()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 1,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300,
                maximumReductionLevels: 8,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let materials = (1...8).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let first = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: store
        )
        let requestsAfterFirstRun = await provider.requestCount
        let second = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: store
        )

        for fact in 1...8 {
            #expect(first.summary.contains("FACT-\(fact)"))
        }
        #expect(first.materialCount == 8)
        #expect(first.reductionLevels == 3)
        #expect(first.modelRequestCount == 15)
        #expect(requestsAfterFirstRun == 15)
        #expect(second.summary == first.summary)
        #expect(second.modelRequestCount == 0)
        #expect(second.reusedSummaryCount >= 15)
        #expect(await provider.requestCount == requestsAfterFirstRun)
        #expect(await store.savedKeys.contains {
            $0.hasSuffix("-document-level-3-group-0")
        })
    }

    @Test("resumes from completed checkpoints after an intermediate provider failure")
    func resumesAfterFailure() async throws {
        let provider = FailOnceFactProvider(failingRequest: 4)
        let store = InMemorySummaryStore()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 1,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300,
                maximumReductionLevels: 8,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let materials = (1...8).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        await #expect(throws: SummaryFixtureError.interrupted) {
            try await summarizer.summarize(
                materials: materials,
                task: "Preserve every fact code.",
                store: store
            )
        }
        let resumed = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: store
        )

        #expect(resumed.reusedSummaryCount >= 3)
        #expect(resumed.modelRequestCount == 12)
        #expect(await provider.requestCount == 16)
        for fact in 1...8 {
            #expect(resumed.summary.contains("FACT-\(fact)"))
        }
    }

    @Test("checkpoints a completed concurrent batch before its sibling fails")
    func checkpointsCompletedConcurrentBatch() async throws {
        let provider = DelayedSiblingFailureProvider()
        let store = InMemorySummaryStore()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 2,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let materials = [
            ContextMaterial(id: "page-1", title: "Page 1", text: "FACT-1"),
            ContextMaterial(id: "page-2", title: "Page 2", text: "FACT-2")
        ]

        await #expect(throws: SummaryFixtureError.interrupted) {
            try await summarizer.summarize(
                materials: materials,
                task: "Preserve every fact code.",
                store: store
            )
        }
        #expect(await store.savedKeys.count == 1)

        let resumed = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: store
        )

        #expect(resumed.reusedSummaryCount >= 1)
        #expect(resumed.modelRequestCount == 2)
        #expect(resumed.summary.contains("FACT-1"))
        #expect(resumed.summary.contains("FACT-2"))
    }

    @Test("checkpoints a successful batch while its sibling is still running")
    func checkpointsBeforeSiblingCompletes() async throws {
        let provider = BlockingSiblingProvider()
        let store = InMemorySummaryStore()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 2,
                maximumItemsPerGroup: 2
            )
        )
        let materials = [
            ContextMaterial(id: "page-1", title: "Page 1", text: "FACT-1"),
            ContextMaterial(id: "page-2", title: "Page 2", text: "FACT-2")
        ]

        let run = Task {
            try await summarizer.summarize(
                materials: materials,
                task: "Preserve every fact code.",
                store: store
            )
        }
        await provider.waitUntilBlocked()
        await store.waitUntilSaved(count: 1)
        #expect(await store.savedKeys.count == 1)
        #expect(await provider.isWaiting)

        await provider.failBlockedRequest()
        await #expect(throws: SummaryFixtureError.interrupted) {
            try await run.value
        }
        #expect(await store.savedKeys.count == 1)
    }

    @Test("splits recoverable leaf failures from four units down to single units")
    func adaptivelySplitsLeafBatches() async throws {
        let provider = MultiUnitRejectingProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumLeafItemsPerRequest: 4,
                maximumConcurrentLeafRequests: 2,
                maximumItemsPerGroup: 4
            )
        )
        let materials = (1...4).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: InMemorySummaryStore()
        )
        let batchSizes = await provider.leafBatchSizes

        #expect(batchSizes.filter { $0 == 4 }.count == 1)
        #expect(batchSizes.filter { $0 == 2 }.count == 2)
        #expect(batchSizes.filter { $0 == 1 }.count == 4)
        #expect(result.modelRequestCount == 8)
        for fact in 1...4 {
            #expect(result.summary.contains("FACT-\(fact)"))
        }
    }

    @Test("retries a recoverable singleton leaf failure only once")
    func retriesSingletonLeafOnce() async throws {
        let provider = FailFirstSingletonProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 1
            )
        )

        let result = try await summarizer.summarize(
            materials: [ContextMaterial(id: "page-1", title: "Page 1", text: "FACT-1")],
            task: "Preserve FACT-1.",
            store: InMemorySummaryStore()
        )

        #expect(await provider.requestCount == 2)
        #expect(result.modelRequestCount == 2)
        #expect(result.summary.contains("FACT-1"))
    }

    @Test("recursively compacts an over-target reduction summary")
    func compactsOverTargetReduction() async throws {
        let provider = OverlongFirstReductionProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumLeafItemsPerRequest: 4,
                maximumConcurrentLeafRequests: 1,
                maximumItemsPerGroup: 4,
                maximumSummaryCharacters: 40
            )
        )
        let materials = (1...4).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: InMemorySummaryStore()
        )

        #expect(result.modelRequestCount == 3)
        #expect(result.reductionLevels == 2)
        #expect(result.summary.count <= 40)
        for fact in 1...4 {
            #expect(result.summary.contains("FACT-\(fact)"))
        }
    }

    @Test("does not checkpoint a model summary truncated by the provider")
    func rejectsLengthTruncation() async throws {
        let provider = LengthLimitedProvider()
        let store = InMemorySummaryStore()
        let summarizer = HierarchicalContextSummarizer(provider: provider, model: "fixture")

        await #expect(
            throws: HierarchicalContextSummarizerError.incompleteModelSummary("length")
        ) {
            try await summarizer.summarize(
                materials: [ContextMaterial(id: "page-1", title: "Page 1", text: "FACT-1")],
                task: "Preserve FACT-1.",
                store: store
            )
        }
        #expect(await store.savedKeys.isEmpty)
    }

    @Test("splits multibyte material by byte budget and preserves edge facts")
    func multibyteByteBudget() async throws {
        let provider = FactPreservingProvider()
        let store = InMemorySummaryStore()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 60,
                maximumReductionInputBytes: 500,
                maximumItemsPerGroup: 4,
                maximumSummaryCharacters: 300,
                maximumTotalInputBytes: 2_000,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let text = "FACT-1 " + String(repeating: "文", count: 300) + " FACT-2"

        let result = try await summarizer.summarize(
            materials: [ContextMaterial(id: "page-1", title: "Page 1", text: text)],
            task: "Preserve both fact codes.",
            store: store
        )

        #expect(result.modelRequestCount > 2)
        #expect(result.summary.contains("FACT-1"))
        #expect(result.summary.contains("FACT-2"))
    }

    @Test("bounds leaf batches by encoded JSON bytes")
    func encodedLeafByteBudget() async throws {
        let provider = EncodedPayloadProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 180,
                maximumLeafItemsPerRequest: 4,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 80
            )
        )
        let escaped = "FACT-1 " + String(repeating: "\\\"\n\t", count: 80)

        let result = try await summarizer.summarize(
            materials: [ContextMaterial(id: "page-1", title: "Page 1", text: escaped)],
            task: "Preserve FACT-1.",
            store: InMemorySummaryStore()
        )
        let payloadBytes = await provider.encodedLeafPayloadBytes

        #expect(payloadBytes.count > 1)
        #expect(payloadBytes.allSatisfy { $0 <= 180 })
        #expect(result.summary.contains("FACT-1"))
    }

    @Test("continues reduction when a short summary exceeds its JSON byte budget")
    func finalSummaryByteBudget() async throws {
        let provider = WideFirstReductionProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumReductionInputBytes: 200,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 100,
                maximumSummaryOutputBytes: 40
            )
        )
        let materials = (1...2).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve both facts.",
            store: InMemorySummaryStore()
        )

        #expect(result.modelRequestCount == 3)
        #expect(result.reductionLevels == 2)
        #expect(try JSONEncoder().encode(result.summary).count <= 40)
        #expect(result.summary.contains("FACT-1"))
        #expect(result.summary.contains("FACT-2"))
    }

    @Test("enforces total input, segment, and nested request budgets")
    func resourceBudgets() async throws {
        let provider = FactPreservingProvider()

        let inputLimited = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 50,
                maximumReductionInputBytes: 100,
                maximumSummaryCharacters: 20,
                maximumTotalInputBytes: 100
            )
        )
        await #expect(throws: HierarchicalContextSummarizerError.inputTooLarge(100)) {
            try await inputLimited.summarize(
                materials: [ContextMaterial(
                    id: "large",
                    title: "Large",
                    text: String(repeating: "x", count: 101)
                )],
                task: "Summarize.",
                store: InMemorySummaryStore()
            )
        }

        let segmentLimited = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 10,
                maximumReductionInputBytes: 100,
                maximumSummaryCharacters: 20,
                maximumTotalInputBytes: 100,
                maximumSegmentCount: 2
            )
        )
        await #expect(throws: HierarchicalContextSummarizerError.tooManySegments(2)) {
            try await segmentLimited.summarize(
                materials: [ContextMaterial(
                    id: "segments",
                    title: "Segments",
                    text: String(repeating: "x", count: 30)
                )],
                task: "Summarize.",
                store: InMemorySummaryStore()
            )
        }

        let requestLimited = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 100,
                maximumReductionInputBytes: 200,
                maximumLeafItemsPerRequest: 1,
                maximumConcurrentLeafRequests: 1,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 50,
                maximumTotalInputBytes: 1_000,
                maximumModelRequests: 2
            )
        )
        await #expect(
            throws: HierarchicalContextSummarizerError.modelRequestBudgetExceeded(2)
        ) {
            try await requestLimited.summarize(
                materials: (1...3).map {
                    ContextMaterial(id: "p\($0)", title: "P\($0)", text: "FACT-\($0)")
                },
                task: "Summarize.",
                store: InMemorySummaryStore()
            )
        }
    }

    @Test("global deadline preempts a longer per-request timeout")
    func globalDeadline() async throws {
        let summarizer = HierarchicalContextSummarizer(
            provider: SlowProvider(),
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumWallClockSeconds: 0.05,
                maximumRequestSeconds: 1
            )
        )
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: HierarchicalContextSummarizerError.self) {
            try await summarizer.summarize(
                materials: [ContextMaterial(id: "p1", title: "P1", text: "FACT-1")],
                task: "Summarize.",
                store: InMemorySummaryStore()
            )
        }
        let elapsed = start.duration(to: clock.now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        #expect(elapsedSeconds < 0.5)
    }

    @Test("batches a 119-unit document and preserves every unit fact")
    func batchesLargeDocument() async throws {
        let provider = ConcurrentFactProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture"
        )
        let materials = (1...119).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every page fact.",
            store: InMemorySummaryStore()
        )

        #expect(result.materialCount == 119)
        #expect(result.modelRequestCount == 71)
        #expect(await provider.maximumConcurrency == 2)
        for fact in 1...119 {
            #expect(result.summary.contains("FACT-\(fact)"))
        }
    }

    @Test("scales the task graph to one thousand source units")
    func scalesToOneThousandUnits() async throws {
        let provider = FactPreservingProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumReductionInputBytes: 20_000,
                maximumSummaryCharacters: 12_000,
                maximumSummaryOutputBytes: 24_000
            )
        )
        let materials = (1...1_000).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: InMemorySummaryStore()
        )

        #expect(result.materialCount == 1_000)
        #expect(result.modelRequestCount == 584)
        for fact in 1...1_000 {
            #expect(result.summary.contains("FACT-\(fact)"))
        }
    }

    @Test("runs independent reduction groups with bounded concurrency")
    func reducesGroupsConcurrently() async throws {
        let provider = ReductionConcurrencyProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture",
            configuration: HierarchicalSummaryConfiguration(
                maximumLeafItemsPerRequest: 8,
                maximumConcurrentLeafRequests: 2,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300
            )
        )
        let materials = (1...8).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: InMemorySummaryStore()
        )

        #expect(await provider.maximumReductionConcurrency == 2)
        for fact in 1...8 {
            #expect(result.summary.contains("FACT-\(fact)"))
        }
    }

    @Test("splits recoverable reduction failures from four nodes to single nodes")
    func adaptivelySplitsReductionGroups() async throws {
        let provider = ReductionFallbackProvider()
        let summarizer = HierarchicalContextSummarizer(
            provider: provider,
            model: "fixture"
        )
        let materials = (1...4).map {
            ContextMaterial(id: "page-\($0)", title: "Page \($0)", text: "FACT-\($0)")
        }

        let result = try await summarizer.summarize(
            materials: materials,
            task: "Preserve every fact code.",
            store: InMemorySummaryStore()
        )
        let groupSizes = await provider.reductionGroupSizes

        #expect(groupSizes.filter { $0 == 4 }.count == 2)
        #expect(groupSizes.filter { $0 == 2 }.count == 2)
        #expect(groupSizes.filter { $0 == 1 }.count == 4)
        #expect(result.modelRequestCount == 9)
        for fact in 1...4 {
            #expect(result.summary.contains("FACT-\(fact)"))
        }
    }
}

private actor InMemorySummaryStore: HierarchicalSummaryStore {
    private var summaries: [String: (inputDigest: String, summary: String)] = [:]
    private(set) var savedKeys: Set<String> = []
    private var saveWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func loadSummary(for metadata: SummaryArtifactMetadata) async throws -> String? {
        guard summaries[metadata.key]?.inputDigest == metadata.inputDigest else {
            return nil
        }
        return summaries[metadata.key]?.summary
    }

    func saveSummary(_ summary: String, metadata: SummaryArtifactMetadata) async throws {
        summaries[metadata.key] = (metadata.inputDigest, summary)
        savedKeys.insert(metadata.key)
        let ready = saveWaiters.filter { savedKeys.count >= $0.count }
        saveWaiters.removeAll { savedKeys.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitUntilSaved(count: Int) async {
        if savedKeys.count >= count { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append((count: count, continuation: continuation))
        }
    }
}

private actor FactPreservingProvider: ModelProvider {
    private(set) var requestCount = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        requestCount += 1
        let output = try fixtureOutput(for: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(output))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private enum SummaryFixtureError: Error {
    case interrupted
}

private actor FailOnceFactProvider: ModelProvider {
    private let failingRequest: Int
    private var hasFailed = false
    private(set) var requestCount = 0

    init(failingRequest: Int) {
        self.failingRequest = failingRequest
    }

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        requestCount += 1
        if requestCount == failingRequest, !hasFailed {
            hasFailed = true
            throw SummaryFixtureError.interrupted
        }
        let output = try fixtureOutput(for: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(output))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private actor DelayedSiblingFailureProvider: ModelProvider {
    private var hasFailed = false

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let input = request.messages.last?.content ?? ""
        if input.contains("FACT-2"), !hasFailed {
            hasFailed = true
            throw SummaryFixtureError.interrupted
        }
        if input.contains("FACT-1") {
            try await ContinuousClock().sleep(for: .milliseconds(25))
        }
        let output = try fixtureOutput(for: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(output))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private actor BlockingSiblingProvider: ModelProvider {
    private var blockedContinuation: CheckedContinuation<Void, any Error>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isWaiting = false

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let input = request.messages.last?.content ?? ""
        if input.contains("FACT-2") {
            isWaiting = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                blockedContinuation = continuation
            }
        }
        return completedStream(try fixtureOutput(for: request))
    }

    func waitUntilBlocked() async {
        if isWaiting { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func failBlockedRequest() {
        isWaiting = false
        blockedContinuation?.resume(throwing: SummaryFixtureError.interrupted)
        blockedContinuation = nil
    }
}

private actor MultiUnitRejectingProvider: ModelProvider {
    private(set) var leafBatchSizes: [Int] = []

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let input = request.messages.last?.content ?? ""
        let output: String
        if isLeafRequest(request), let start = input.firstIndex(of: "[") {
            let units = try JSONDecoder().decode(
                [LeafFixtureInput].self,
                from: Data(input[start...].utf8)
            )
            leafBatchSizes.append(units.count)
            output = units.count > 1 ? "{}" : try fixtureOutput(for: request)
        } else {
            output = try reductionFixtureOutput(factSummary(in: input))
        }
        return completedStream(output)
    }
}

private actor FailFirstSingletonProvider: ModelProvider {
    private(set) var requestCount = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        requestCount += 1
        return completedStream(requestCount == 1 ? "{}" : try fixtureOutput(for: request))
    }
}

private actor OverlongFirstReductionProvider: ModelProvider {
    private var reductionRequestCount = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let output: String
        if isLeafRequest(request) {
            output = try fixtureOutput(for: request)
        } else {
            reductionRequestCount += 1
            let facts = factSummary(in: request.messages.last?.content ?? "")
            let summary = reductionRequestCount == 1
                ? facts + " " + String(repeating: "detail ", count: 20)
                : facts
            output = try reductionFixtureOutput(summary)
        }
        return completedStream(output)
    }
}

private actor EncodedPayloadProvider: ModelProvider {
    private(set) var encodedLeafPayloadBytes: [Int] = []

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        if isLeafRequest(request),
           let input = request.messages.last?.content,
           let start = input.firstIndex(of: "[") {
            let units = try JSONDecoder().decode(
                [LeafFixtureInput].self,
                from: Data(input[start...].utf8)
            )
            encodedLeafPayloadBytes.append(try JSONEncoder().encode(units).count)
        }
        return completedStream(try fixtureOutput(for: request))
    }
}

private actor WideFirstReductionProvider: ModelProvider {
    private var reductionRequestCount = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        let output: String
        if isLeafRequest(request) {
            output = try fixtureOutput(for: request)
        } else {
            reductionRequestCount += 1
            let facts = factSummary(in: request.messages.last?.content ?? "")
            let summary = reductionRequestCount == 1
                ? facts + String(repeating: "界", count: 20)
                : facts
            output = try reductionFixtureOutput(summary)
        }
        return completedStream(output)
    }
}

private func completedStream(
    _ output: String
) -> AsyncThrowingStream<ModelStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.text(output))
        continuation.yield(.completed(ModelUsage()))
        continuation.finish()
    }
}

private actor LengthLimitedProvider: ModelProvider {
    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("Partial summary"))
            continuation.yield(.completed(ModelUsage(finishReason: "length")))
            continuation.finish()
        }
    }
}

private actor SlowProvider: ModelProvider {
    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        try await ContinuousClock().sleep(for: .seconds(2))
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("late"))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private actor ConcurrentFactProvider: ModelProvider {
    private var activeCount = 0
    private(set) var maximumConcurrency = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        try await ContinuousClock().sleep(for: .milliseconds(5))
        activeCount -= 1
        let output = try fixtureOutput(for: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(output))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private actor ReductionConcurrencyProvider: ModelProvider {
    private var activeReductionCount = 0
    private(set) var maximumReductionConcurrency = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        if isReductionRequest(request) {
            activeReductionCount += 1
            maximumReductionConcurrency = max(
                maximumReductionConcurrency,
                activeReductionCount
            )
            try await ContinuousClock().sleep(for: .milliseconds(10))
            activeReductionCount -= 1
        }
        return completedStream(try fixtureOutput(for: request))
    }
}

private actor ReductionFallbackProvider: ModelProvider {
    private(set) var reductionGroupSizes: [Int] = []
    private var completedSingletons = 0

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        if isLeafRequest(request) {
            return completedStream(try fixtureOutput(for: request))
        }
        let input = request.messages.last?.content ?? ""
        let groupSize = input.components(separatedBy: "[Summary ").count - 1
        reductionGroupSizes.append(groupSize)
        if completedSingletons < 4, groupSize > 1 {
            throw HierarchicalContextSummarizerError.timedOut(1)
        }
        if groupSize == 1 {
            completedSingletons += 1
        }
        return completedStream(try reductionFixtureOutput(factSummary(in: input)))
    }
}

private struct LeafFixtureInput: Codable {
    let index: Int
    let text: String
}

private struct LeafFixtureOutput: Encodable {
    let summaries: [LeafFixtureSummary]
}

private struct LeafFixtureSummary: Encodable {
    let index: Int
    let summary: String
}

private func fixtureOutput(for request: ModelRequest) throws -> String {
    let input = request.messages.last?.content ?? ""
    if isLeafRequest(request) {
        guard let start = input.firstIndex(of: "[") else { return "{}" }
        let units = try JSONDecoder().decode(
            [LeafFixtureInput].self,
            from: Data(input[start...].utf8)
        )
        let output = LeafFixtureOutput(summaries: units.map { unit in
            LeafFixtureSummary(index: unit.index, summary: factSummary(in: unit.text))
        })
        return String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    }
    let output = ReductionFixtureOutput(summary: factSummary(in: input))
    return String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
}

private func isLeafRequest(_ request: ModelRequest) -> Bool {
    request.messages.last?.content.contains("JSON array below") == true
}

private func isReductionRequest(_ request: ModelRequest) -> Bool {
    request.messages.last?.content.contains("Material scope:") == true
}

private struct ReductionFixtureOutput: Encodable {
    let summary: String
}

private func reductionFixtureOutput(_ summary: String) throws -> String {
    String(
        decoding: try JSONEncoder().encode(ReductionFixtureOutput(summary: summary)),
        as: UTF8.self
    )
}

private func factSummary(in input: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"FACT-\d+"#)
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    let facts = regex.matches(in: input, range: range).compactMap { match -> String? in
        guard let matchRange = Range(match.range, in: input) else { return nil }
        return String(input[matchRange])
    }
    let uniqueFacts = Array(Set(facts)).sorted()
    return uniqueFacts.isEmpty ? "COVERED" : uniqueFacts.joined(separator: " ")
}