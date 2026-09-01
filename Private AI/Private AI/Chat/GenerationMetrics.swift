import Foundation
import LLMCore

struct GenerationMetrics: Equatable {
    private(set) var startedAt: Date?
    private(set) var firstTextAt: Date?
    private(set) var streamedCharacterCount = 0
    private(set) var ttftSeconds: Double?
    private(set) var liveTokensPerSecond: Double?
    private(set) var finalTokensPerSecond: Double?
    private(set) var endedAt: Date?

    var statusText: String {
        statusText(at: Date())
    }

    func statusText(at date: Date) -> String {
        guard let startedAt else { return "TTFT — · — tok/s" }
        let displayedTTFT = ttftSeconds ?? max(0, (endedAt ?? date).timeIntervalSince(startedAt))
        var parts = [String(format: "TTFT %.2fs", displayedTTFT)]
        if let finalTokensPerSecond {
            parts.append(String(format: "%.1f tok/s", finalTokensPerSecond))
        } else if let liveTokensPerSecond {
            parts.append(String(format: "~%.1f tok/s", liveTokensPerSecond))
        } else {
            parts.append("— tok/s")
        }
        return parts.joined(separator: " · ")
    }

    mutating func start(at date: Date = Date()) {
        self = GenerationMetrics(startedAt: date)
    }

    mutating func recordText(_ text: String, at date: Date = Date()) {
        guard let startedAt else { return }
        if firstTextAt == nil {
            firstTextAt = date
            ttftSeconds = max(0, date.timeIntervalSince(startedAt))
        }
        streamedCharacterCount += text.count
        guard let firstTextAt else { return }
        let elapsed = max(0.25, date.timeIntervalSince(firstTextAt))
        liveTokensPerSecond = (Double(streamedCharacterCount) / 4) / elapsed
    }

    mutating func finish(performance: AgentPerformance) {
        endedAt = Date()
        if ttftSeconds == nil {
            ttftSeconds = performance.timeToFirstTextSeconds
        }
        let usage = performance.modelUsage.reduce(into: (tokens: 0, nanoseconds: UInt64(0))) {
            $0.tokens += $1.outputTokenCount ?? 0
            $0.nanoseconds += $1.outputDurationNanoseconds ?? 0
        }
        if usage.tokens > 0, usage.nanoseconds > 0 {
            finalTokensPerSecond = Double(usage.tokens) / (Double(usage.nanoseconds) / 1_000_000_000)
        }
    }

    mutating func stop(at date: Date = Date()) {
        endedAt = date
        if ttftSeconds == nil, let startedAt {
            ttftSeconds = max(0, date.timeIntervalSince(startedAt))
        }
    }
}