import Foundation
import LLMCore
import PrivateAITools

actor ChatAgent {
    private let provider: OllamaProvider
    private let localResources: LocalResourcesTool
    private let generalToolRuntime: ToolRuntime
    private let localResourcesRoot: URL
    private let documentSummariesRoot: URL
    private let log: RuntimeLog
    private var runtimes: [RuntimeKey: AgentRuntime] = [:]
    private var documentToolRuntimes: [String: ToolRuntime] = [:]

    init(log: RuntimeLog, localResourcesRoot: URL, jobsRoot: URL) throws {
        provider = try OllamaProvider()
        self.localResourcesRoot = localResourcesRoot
        documentSummariesRoot = jobsRoot.appending(
            path: "document-summaries",
            directoryHint: .isDirectory
        )
        localResources = LocalResourcesTool(
            access: .restricted([localResourcesRoot]),
            maximumTextCharacters: 2_000
        )
        generalToolRuntime = try ToolRuntime(tools: [
            AppleServicesTool(),
            localResources,
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
        documentPrivacyMode: Bool,
        onEvent: @escaping AgentRuntime.EventHandler
    ) async throws -> AgentResult {
        await log.record("agent.request.started", fields: [
            "history_messages": String(history.count),
            "model": model
        ])
        let runtime = try runtime(for: model, documentPrivacyMode: documentPrivacyMode)
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
                if let progress = self.progressEvent(for: diagnostic) {
                    await onEvent(progress)
                }
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
        let runtime = try runtime(for: model, documentPrivacyMode: false)
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

    func availableToolNames(
        documentPrivacyMode: Bool,
        model: String = "fixture"
    ) async throws -> [String] {
        let runtime = try toolRuntime(for: model, documentPrivacyMode: documentPrivacyMode)
        return await runtime.definitions.map { $0.function.name }
    }

    private func runtime(
        for model: String,
        documentPrivacyMode: Bool
    ) throws -> AgentRuntime {
        let key = RuntimeKey(model: model, documentPrivacyMode: documentPrivacyMode)
        if let runtime = runtimes[key] {
            return runtime
        }
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try toolRuntime(
                for: model,
                documentPrivacyMode: documentPrivacyMode
            ),
            configuration: AgentConfiguration(
                model: model,
                keepAlive: "-1",
                options: ModelOptions(numContext: 8_192, temperature: 0.2, numPredict: 2_048),
                think: true
            )
        )
        runtimes[key] = runtime
        return runtime
    }

    private func toolRuntime(
        for model: String,
        documentPrivacyMode: Bool
    ) throws -> ToolRuntime {
        guard documentPrivacyMode else { return generalToolRuntime }
        if let runtime = documentToolRuntimes[model] {
            return runtime
        }
        let documentAnalysis = try HierarchicalDocumentTool(
            provider: provider,
            model: model,
            authorizedRoot: localResourcesRoot,
            jobsRoot: documentSummariesRoot
        )
        let runtime = try ToolRuntime(tools: [localResources, documentAnalysis])
        documentToolRuntimes[model] = runtime
        return runtime
    }

    private nonisolated func progressEvent(for diagnostic: ToolDiagnostic) -> AgentEvent? {
        switch diagnostic.event {
        case "document.summary.started":
            let units = diagnostic.data["source_units"] ?? "?"
            return .toolProgress(
                name: "document_analysis",
                detail: "Summarizing \(units) document sections"
            )
        case "document.summary.checkpoint":
            let level = diagnostic.data["level"] ?? "?"
            let count = diagnostic.data["checkpoint_count"] ?? "?"
            return .toolProgress(
                name: "document_analysis",
                detail: "Saved checkpoint \(count) at level \(level)"
            )
        case "hierarchical.summary.request.started":
            let count = diagnostic.data["input_count"] ?? "?"
            let detail = diagnostic.data["phase"] == "leaf"
                ? "Analyzing \(count) document sections"
                : "Combining \(count) summaries"
            return .toolProgress(name: "document_analysis", detail: detail)
        case "hierarchical.summary.request.finished":
            let outputTokens = Double(diagnostic.data["output_tokens"] ?? "") ?? 0
            let outputNanoseconds = Double(
                diagnostic.data["output_duration_nanoseconds"] ?? ""
            ) ?? 0
            let rate = outputNanoseconds > 0
                ? outputTokens / (outputNanoseconds / 1_000_000_000)
                : 0
            return .toolProgress(
                name: "document_analysis",
                detail: rate > 0
                    ? "Completed model batch · \(String(format: "%.1f", rate)) tok/s"
                    : "Completed model batch"
            )
        case "document.summary.finished":
            return .toolProgress(
                name: "document_analysis",
                detail: "Combining document summary"
            )
        default:
            return nil
        }
    }
}

nonisolated private struct RuntimeKey: Hashable {
    let model: String
    let documentPrivacyMode: Bool
}