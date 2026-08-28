import Foundation
import XCTest
@testable import PrivateAI

final class OllamaEvaluationTests: XCTestCase {
    func testEvaluationFixtureSchemaIsValid() throws {
        let suite = try loadSuite()

        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertEqual(suite.model, "qwen3.8:27b-mlx")
        XCTAssertEqual(Set(suite.tasks.map(\.id)).count, suite.tasks.count)
        XCTAssertFalse(suite.tasks.isEmpty)
        XCTAssertTrue(suite.tasks.allSatisfy { !$0.prompt.isEmpty && !$0.assertion.values.isEmpty })
    }

    func testLiveQwenEvaluationBaseline() async throws {
        guard ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Run the PrivateAI-Tests scheme to record the Qwen baseline.")
        }

        let suite = try loadSuite()
        let client = OllamaClient()
        let ollamaVersion = try await client.version()
        let availableModels = try await client.models()
        let model = try XCTUnwrap(
            availableModels.first { $0.name == suite.model },
            "Install the exact recommended Qwen model before recording the baseline."
        )
        var taskResults: [EvaluationTaskResult] = []

        for task in suite.tasks {
            let probe = EvaluationProbe()
            let startedAt = Date()
            let result = try await client.streamChat(
                model: suite.model,
                messages: [OllamaMessage(role: .user, content: task.prompt)],
                thinking: false,
                toolsEnabled: false,
                utilityToolsEnabled: false,
                localContextToolsEnabled: false,
                jsonFormat: task.assertion.type == .jsonObject,
                onEvent: { event in
                    await probe.record(event, startedAt: startedAt)
                }
            )
            let finishedAt = Date()
            let firstTokenSeconds = await probe.firstTokenSeconds
            taskResults.append(
                EvaluationTaskResult(
                    id: task.id,
                    passed: task.assertion.matches(result.content),
                    firstTokenSeconds: firstTokenSeconds,
                    totalSeconds: finishedAt.timeIntervalSince(startedAt),
                    promptTokens: result.promptTokens,
                    outputTokens: result.outputTokens,
                    tokensPerSecond: result.evaluationDurationNanoseconds > 0
                        ? Double(result.outputTokens)
                            / (Double(result.evaluationDurationNanoseconds) / 1_000_000_000)
                        : 0
                )
            )
        }

        let artifact = EvaluationArtifact(
            recordedAtUTC: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            ollamaVersion: ollamaVersion,
            model: model.name,
            modelDigest: model.digest,
            modelSizeBytes: model.size,
            thinking: false,
            temperature: 0.2,
            contextTokens: 32_768,
            results: taskResults
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-Qwen-Evaluation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let output = outputDirectory.appendingPathComponent("latest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: output, options: .atomic)

        let failed = taskResults.filter { !$0.passed }.map(\.id)
        XCTAssertTrue(
            failed.isEmpty,
            "Failed evaluation tasks: \(failed.joined(separator: ", ")). Artifact: \(output.path)"
        )
    }

    func testActionRoutingFixtureSchemaIsValid() throws {
        let suite = try loadActionRoutingSuite()

        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertEqual(suite.model, "qwen3.8:27b-mlx")
        XCTAssertEqual(Set(suite.tasks.map(\.id)).count, suite.tasks.count)
        XCTAssertGreaterThanOrEqual(suite.tasks.count, 10)
        XCTAssertTrue(suite.tasks.allSatisfy {
            !$0.prompt.isEmpty
                && [
                    "direct", "local_search", "local_context",
                    "web_search", "fetch_url", "code_interpreter"
                ].contains($0.expectedAction)
        })
    }

    func testLiveQwenActionRoutingEvaluation() async throws {
        guard ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip(
                "Run the PrivateAI-Tests scheme to evaluate native action selection."
            )
        }
        executionTimeAllowance = 240

        let suite = try loadActionRoutingSuite()
        let client = OllamaClient()
        let ollamaVersion = try await client.version()
        let availableModels = try await client.models()
        let model = try XCTUnwrap(
            availableModels.first { $0.name == suite.model },
            "Install the exact recommended Qwen baseline before running action evaluation."
        )
        var results: [ActionRoutingEvaluationResult] = []
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-Action-Routing-Evaluation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let output = outputDirectory.appendingPathComponent("latest.json")

        for task in suite.tasks {
            let startedAt = Date()
            let firstResult = try await client.streamChat(
                model: suite.model,
                messages: [
                    LocalChatPrompt.systemMessage(),
                    OllamaMessage(role: .user, content: task.prompt)
                ],
                thinking: false,
                toolsEnabled: true,
                utilityToolsEnabled: true,
                localContextToolsEnabled: true,
                allowedToolNames: ToolPolicy.modelActionToolNames,
                jsonFormat: false,
                contextWindow: 8_192,
                maximumOutputTokens: 128,
                onEvent: { _ in }
            )
            let first = assessAction(firstResult, for: task)
            var final = first
            var recovered = false
            var promptTokens = firstResult.promptTokens
            var outputTokens = firstResult.outputTokens

            if !first.passed,
               !firstResult.toolCalls.isEmpty,
               (!first.argumentsAreValid || firstResult.toolCalls.count > 1) {
                let rejectedCalls = firstResult.toolCalls.map {
                    OllamaToolCall(
                        id: $0.id,
                        name: $0.name,
                        arguments: $0.arguments
                    )
                }
                let feedback = """
                Action rejected by the application because its arguments or purpose were invalid. \
                The action was not executed. Re-read the user's request and either answer directly \
                or select one different valid action. Do not repeat the rejected action.
                """
                var correctionMessages = [
                    LocalChatPrompt.systemMessage(),
                    OllamaMessage(role: .user, content: task.prompt),
                    OllamaMessage(
                        role: .assistant,
                        content: "",
                        toolCalls: rejectedCalls
                    )
                ]
                correctionMessages.append(contentsOf: rejectedCalls.map { _ in
                    OllamaMessage(role: .tool, content: feedback)
                })
                let correctedResult = try await client.streamChat(
                    model: suite.model,
                    messages: correctionMessages,
                    thinking: false,
                    toolsEnabled: true,
                    utilityToolsEnabled: true,
                    localContextToolsEnabled: true,
                    allowedToolNames: ToolPolicy.modelActionToolNames,
                    jsonFormat: false,
                    contextWindow: 8_192,
                    maximumOutputTokens: 128,
                    onEvent: { _ in }
                )
                final = assessAction(correctedResult, for: task)
                recovered = final.passed
                promptTokens += correctedResult.promptTokens
                outputTokens += correctedResult.outputTokens
            }
            results.append(
                ActionRoutingEvaluationResult(
                    id: task.id,
                    expectedAction: task.expectedAction,
                    initialAction: first.action,
                    actualAction: final.action,
                    initialPassed: first.passed,
                    recovered: recovered,
                    passed: final.passed,
                    totalSeconds: Date().timeIntervalSince(startedAt),
                    promptTokens: promptTokens,
                    outputTokens: outputTokens,
                    initialArgumentSummary: String(first.argumentText.prefix(200)),
                    argumentSummary: String(final.argumentText.prefix(200))
                )
            )
            try writeActionRoutingArtifact(
                results: results,
                ollamaVersion: ollamaVersion,
                model: model,
                to: output
            )
        }

        let failed = results.filter { !$0.passed }.map {
            "\($0.id): expected \($0.expectedAction), got \($0.actualAction)"
        }
        XCTAssertTrue(
            failed.isEmpty,
            "Failed action routes: \(failed.joined(separator: "; ")). Artifact: \(output.path)"
        )
    }

    private func assessAction(
        _ result: OllamaStreamResult,
        for task: ActionRoutingEvaluationTask
    ) -> ActionAssessment {
        let invocation = result.toolCalls.first
        let action = invocation?.name ?? "direct"
        let argumentText = invocation?.arguments
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.stringValue ?? value.jsonString())"
            }
            .joined(separator: " ") ?? ""
        let argumentsAreValid: Bool
        if let invocation {
            argumentsAreValid = (try? ToolPolicy.validateModelInvocation(
                invocation,
                for: task.prompt
            )) != nil
        } else {
            argumentsAreValid = true
        }
        let passed = action == task.expectedAction
            && task.expectedValues.allSatisfy {
                argumentText.localizedCaseInsensitiveContains($0)
            }
            && result.toolCalls.count <= 1
            && argumentsAreValid
        return ActionAssessment(
            action: action,
            argumentText: argumentText,
            argumentsAreValid: argumentsAreValid,
            passed: passed
        )
    }

    private func writeActionRoutingArtifact(
        results: [ActionRoutingEvaluationResult],
        ollamaVersion: String,
        model: OllamaModel,
        to output: URL
    ) throws {
        let artifact = ActionRoutingEvaluationArtifact(
            recordedAtUTC: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            ollamaVersion: ollamaVersion,
            model: model.name,
            modelDigest: model.digest,
            thinking: false,
            contextTokens: 8_192,
            maximumOutputTokens: 128,
            results: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: output, options: .atomic)
    }

    private func loadSuite() throws -> EvaluationSuite {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "qwen-evaluation",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? bundle.url(forResource: "qwen-evaluation", withExtension: "json")
        )
        return try JSONDecoder().decode(
            EvaluationSuite.self,
            from: Data(contentsOf: url)
        )
    }

    private func loadActionRoutingSuite() throws -> ActionRoutingEvaluationSuite {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "qwen-action-routing-evaluation",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? bundle.url(
                forResource: "qwen-action-routing-evaluation",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            ActionRoutingEvaluationSuite.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct ActionRoutingEvaluationSuite: Decodable {
    let schemaVersion: Int
    let model: String
    let tasks: [ActionRoutingEvaluationTask]
}

private struct ActionRoutingEvaluationTask: Decodable {
    let id: String
    let prompt: String
    let expectedAction: String
    let expectedValues: [String]
}

private struct ActionAssessment {
    let action: String
    let argumentText: String
    let argumentsAreValid: Bool
    let passed: Bool
}

private struct ActionRoutingEvaluationResult: Codable {
    let id: String
    let expectedAction: String
    let initialAction: String
    let actualAction: String
    let initialPassed: Bool
    let recovered: Bool
    let passed: Bool
    let totalSeconds: Double
    let promptTokens: Int
    let outputTokens: Int
    let initialArgumentSummary: String
    let argumentSummary: String
}

private struct ActionRoutingEvaluationArtifact: Codable {
    let recordedAtUTC: String
    let operatingSystem: String
    let ollamaVersion: String
    let model: String
    let modelDigest: String?
    let thinking: Bool
    let contextTokens: Int
    let maximumOutputTokens: Int
    let results: [ActionRoutingEvaluationResult]
}

private struct EvaluationSuite: Decodable {
    let schemaVersion: Int
    let model: String
    let tasks: [EvaluationTask]
}

private struct EvaluationTask: Decodable {
    let id: String
    let prompt: String
    let assertion: EvaluationAssertion
}

private struct EvaluationAssertion: Decodable {
    enum Kind: String, Decodable {
        case exact
        case containsAll
        case jsonObject
    }

    let type: Kind
    let values: [String]

    func matches(_ rawOutput: String) -> Bool {
        let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .exact:
            return values.contains(output)
        case .containsAll:
            return values.allSatisfy {
                output.localizedCaseInsensitiveContains($0)
            }
        case .jsonObject:
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return values.allSatisfy { expectation in
                let parts = expectation.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let value = object[parts[0]] else { return false }
                if parts[1] == "true" || parts[1] == "false" {
                    guard let boolean = value as? Bool else { return false }
                    return boolean == (parts[1] == "true")
                }
                return String(describing: value).localizedCaseInsensitiveCompare(parts[1]) == .orderedSame
            }
        }
    }
}

private actor EvaluationProbe {
    private(set) var firstTokenSeconds: Double?

    func record(_ event: OllamaStreamEvent, startedAt: Date) {
        guard firstTokenSeconds == nil else { return }
        switch event {
        case .content(let text) where !text.isEmpty:
            firstTokenSeconds = Date().timeIntervalSince(startedAt)
        case .thinking(let text) where !text.isEmpty:
            firstTokenSeconds = Date().timeIntervalSince(startedAt)
        case .content, .thinking, .replaceContent:
            break
        }
    }
}

private struct EvaluationTaskResult: Codable {
    let id: String
    let passed: Bool
    let firstTokenSeconds: Double?
    let totalSeconds: Double
    let promptTokens: Int
    let outputTokens: Int
    let tokensPerSecond: Double
}

private struct EvaluationArtifact: Codable {
    let recordedAtUTC: String
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let ollamaVersion: String
    let model: String
    let modelDigest: String?
    let modelSizeBytes: Int64?
    let thinking: Bool
    let temperature: Double
    let contextTokens: Int
    let results: [EvaluationTaskResult]
}