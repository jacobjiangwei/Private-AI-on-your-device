import Foundation
import LLMCore
import PrivateAITools

actor ChatAgent {
    private let provider: OllamaProvider
    private let toolRuntime: ToolRuntime
    private let log: RuntimeLog
    private var runtimes: [String: AgentRuntime] = [:]

    init(log: RuntimeLog) throws {
        provider = try OllamaProvider()
        toolRuntime = try ToolRuntime(tools: [
            AppleServicesTool(),
            LocalResourcesTool(authorizedRoots: []),
            WebTool()
        ])
        self.log = log
    }

    func respond(
        prompt: String,
        history: [ChatMessage],
        model: String,
        runID: UUID,
        conversationID: UUID,
        onEvent: @escaping AgentRuntime.EventHandler
    ) async throws -> AgentResult {
        await log.record("agent.request.started", fields: [
            "history_messages": String(history.count),
            "model": model
        ])
        let runtime = runtime(for: model)
        do {
            let result = try await ToolDiagnostics.$handler.withValue({ diagnostic in
                await self.log.record(
                    diagnostic.event,
                    level: diagnostic.level,
                    category: "tool",
                    runID: runID,
                    conversationID: conversationID,
                    data: diagnostic.data
                )
            }) {
                try await runtime.run(prompt: prompt, history: history, onEvent: onEvent)
            }
            await log.record("agent.request.finished", fields: [
                "model": model,
                "model_requests": String(result.performance.modelRequestCount),
                "tool_calls": String(result.performance.toolCallCount),
                "total_seconds": String(result.performance.totalSeconds)
            ])
            return result
        } catch {
            await log.record("agent.request.failed", fields: [
                "error": String(describing: error),
                "model": model
            ])
            throw error
        }
    }

    func warmUp(model: String) async throws -> WarmupMetrics {
        let runtime = runtime(for: model)
        await log.record("agent.warmup.started", fields: ["model": model])
        do {
            let metrics = try await runtime.warmUp()
            await log.record("agent.warmup.finished", fields: [
                "elapsed_seconds": String(metrics.elapsedSeconds),
                "model": model,
                "prefix_tokens": String(metrics.prefixPromptTokenCount ?? 0)
            ])
            return metrics
        } catch {
            await log.record("agent.warmup.failed", fields: [
                "error": String(describing: error),
                "model": model
            ])
            throw error
        }
    }

    private func runtime(for model: String) -> AgentRuntime {
        if let runtime = runtimes[model] {
            return runtime
        }
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: toolRuntime,
            configuration: AgentConfiguration(
                model: model,
                keepAlive: "-1",
                options: ModelOptions(numContext: 8_192, temperature: 0.2, numPredict: 2_048),
                think: true
            )
        )
        runtimes[model] = runtime
        return runtime
    }
}