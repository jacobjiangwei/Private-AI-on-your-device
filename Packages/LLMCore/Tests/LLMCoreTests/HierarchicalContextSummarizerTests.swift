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
        #expect(await store.savedKeys.contains("document-level-3-group-0"))
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
}

private actor InMemorySummaryStore: HierarchicalSummaryStore {
    private var summaries: [String: (inputDigest: String, summary: String)] = [:]
    private(set) var savedKeys: Set<String> = []

    func loadSummary(for metadata: SummaryArtifactMetadata) async throws -> String? {
        guard summaries[metadata.key]?.inputDigest == metadata.inputDigest else {
            return nil
        }
        return summaries[metadata.key]?.summary
    }

    func saveSummary(_ summary: String, metadata: SummaryArtifactMetadata) async throws {
        summaries[metadata.key] = (metadata.inputDigest, summary)
        savedKeys.insert(metadata.key)
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
        let input = request.messages.last?.content ?? ""
        let regex = try NSRegularExpression(pattern: #"FACT-\d+"#)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var facts: [String] = []
        for match in regex.matches(in: input, range: range) {
            guard let matchRange = Range(match.range, in: input) else { continue }
            let fact = String(input[matchRange])
            if !facts.contains(fact) {
                facts.append(fact)
            }
        }
        let output = facts.isEmpty ? "COVERED" : facts.sorted().joined(separator: " ")
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
        let input = request.messages.last?.content ?? ""
        let regex = try NSRegularExpression(pattern: #"FACT-\d+"#)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let facts = regex.matches(in: input, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: input) else { return nil }
            return String(input[matchRange])
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(Array(Set(facts)).sorted().joined(separator: " ")))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
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