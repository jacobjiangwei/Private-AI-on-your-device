import Foundation
import LLMCore
import Testing
@testable import Private_AI

@Suite("Generation Metrics")
struct GenerationMetricsTests {
    @Test("shows a stable placeholder before generation")
    func idleMetrics() {
        #expect(GenerationMetrics().statusText == "TTFT — · — tok/s")
    }

    @Test("shows a ticking TTFT before the first token")
    func waitingForFirstToken() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()

        metrics.start(at: start)

        #expect(
            metrics.statusText(at: start.addingTimeInterval(1.25))
                == "TTFT 1.25s · — tok/s"
        )
    }

    @Test("stops TTFT when a run fails before producing text")
    func failedBeforeFirstToken() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()

        metrics.start(at: start)
        metrics.stop(at: start.addingTimeInterval(5))

        #expect(metrics.statusText(at: start.addingTimeInterval(30)) == "TTFT 5.00s · — tok/s")
    }

    @Test("shows user-perceived TTFT and estimated live token speed")
    func liveMetrics() {
        let start = Date(timeIntervalSince1970: 1_000)
        var metrics = GenerationMetrics()

        metrics.start(at: start)
        metrics.recordText("12345678", at: start.addingTimeInterval(2))
        metrics.recordText("12345678", at: start.addingTimeInterval(3))

        #expect(metrics.ttftSeconds == 2)
        #expect(metrics.statusText == "TTFT 2.00s · ~4.0 tok/s")
    }

    @Test("replaces the live estimate with Ollama evaluation speed")
    func finalMetrics() {
        var metrics = GenerationMetrics()
        metrics.start(at: Date(timeIntervalSince1970: 1_000))
        metrics.recordText("response", at: Date(timeIntervalSince1970: 1_001))
        metrics.finish(performance: AgentPerformance(
            timeToFirstEventSeconds: 0.5,
            timeToFirstTextSeconds: 1,
            totalSeconds: 3,
            modelRequestCount: 1,
            toolCallCount: 0,
            modelUsage: [ModelUsage(
                outputTokenCount: 40,
                outputDurationNanoseconds: 2_000_000_000
            )]
        ))

        #expect(metrics.statusText == "TTFT 1.00s · 20.0 tok/s")
    }
}