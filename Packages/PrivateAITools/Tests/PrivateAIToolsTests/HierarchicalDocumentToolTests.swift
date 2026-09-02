import CoreGraphics
import CoreText
import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Hierarchical Document Tool", .serialized)
struct HierarchicalDocumentToolTests {
    @Test("summarizes every PDF page, reduces recursively, and resumes from files")
    func summarizePDFAndResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "large.pdf")
        try createSummaryPDF(at: pdf, pages: (1...8).map { "FACT-\($0)" })
        let provider = DocumentFactProvider()
        let tool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs,
            summarizerConfiguration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 300,
                maximumReductionLevels: 8,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let arguments: [String: JSONValue] = [
            "action": .string("summarize"),
            "path": .string("large.pdf"),
            "task": .string("Preserve every fact code.")
        ]

        let first = try decodeObject(await tool.execute(arguments: arguments))
        let requestsAfterFirstRun = await provider.requestCount
        let second = try decodeObject(await tool.execute(arguments: arguments))
        let jobID = try #require(first["checkpoint_job_id"]?.stringValue)
        let jobDirectory = jobs.appending(path: jobID)

        for fact in 1...8 {
            #expect(first["summary"]?.stringValue?.contains("FACT-\(fact)") == true)
        }
        #expect(first["coverage"] == .string("all_extractable_pdf_pages"))
        #expect(first["source_unit_count"] == .number(8))
        #expect(first["model_request_count"] == .number(15))
        #expect(second["model_request_count"] == .number(0))
        #expect(await provider.requestCount == requestsAfterFirstRun)
        for page in 0..<8 {
            #expect(FileManager.default.fileExists(
                atPath: jobDirectory.appending(path: "unit-\(page).json").path
            ))
        }
        #expect(FileManager.default.fileExists(
            atPath: jobDirectory.appending(path: "document-level-3-group-0.json").path
        ))
        #expect(try permissions(at: jobDirectory) == 0o700)
        #expect(try permissions(at: jobDirectory.appending(path: "unit-0.json")) == 0o600)

        let corruptURL = jobDirectory.appending(path: "unit-0-segment-0.json")
        try Data("corrupt".utf8).write(to: corruptURL, options: .atomic)
        _ = try decodeObject(await tool.execute(arguments: arguments))
        #expect(await provider.requestCount == requestsAfterFirstRun + 1)

        let changedTool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs,
            summarizerConfiguration: HierarchicalSummaryConfiguration(
                maximumMaterialBytes: 1_000,
                maximumReductionInputBytes: 1_000,
                maximumItemsPerGroup: 2,
                maximumSummaryCharacters: 301,
                maximumReductionLevels: 8,
                options: ModelOptions(numContext: 2_048, temperature: 0, numPredict: 128)
            )
        )
        let changed = try decodeObject(await changedTool.execute(arguments: arguments))
        #expect(changed["checkpoint_job_id"] != first["checkpoint_job_id"])
        #expect((changed["model_request_count"]?.integerValue ?? 0) > 0)
    }

    @Test("model uses hierarchical analysis and includes every page fact in its final answer")
    func modelDrivenWholeDocumentSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "whole-document.pdf")
        let factCodes = ["ALPHA-11", "BRAVO-22", "CHARLIE-33", "DELTA-44"]
        try createSummaryPDF(at: pdf, pages: factCodes.enumerated().map { index, code in
            "Page \(index + 1) contains one required verification code: \(code). Preserve it exactly in every summary."
        })
        let provider = try OllamaProvider()
        let model = "qwen3.8:latest"
        let documentTool = try HierarchicalDocumentTool(
            provider: provider,
            model: model,
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [
                LocalResourcesTool(
                    access: .restricted([artifacts]),
                    maximumTextCharacters: 2_000
                ),
                documentTool
            ]),
            configuration: AgentConfiguration(
                model: model,
                keepAlive: "30m",
                options: ModelOptions(numContext: 8_192, temperature: 0, numPredict: 256),
                think: false,
                maximumToolCallsPerRound: 2,
                maximumToolCallsTotal: 2
            )
        )

        _ = try await runtime.warmUp()
        let result = try await runtime.run(
            prompt: "Summarize the entire attached PDF at \(pdf.path). The final answer must list the exact verification code from every page."
        )
        let calls = result.messages.flatMap { $0.toolCalls ?? [] }
        let toolMessages = result.messages.filter { $0.role == .tool }

        #expect(calls.contains { $0.function.name == "document_analysis" })
        #expect(result.performance.toolCallCount <= 2)
        #expect(result.performance.modelRequestCount <= 3)
        #expect(toolMessages.contains { message in
            factCodes.allSatisfy(message.content.contains)
        })
        for code in factCodes {
            #expect(result.text.contains(code))
        }
    }

    @Test("rejects checkpoint directory and file symlink escapes")
    func rejectsCheckpointSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifacts = root.appending(path: "artifacts", directoryHint: .isDirectory)
        let jobs = root.appending(path: "jobs", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = artifacts.appending(path: "symlink.pdf")
        try createSummaryPDF(at: pdf, pages: ["FACT-1"])
        let provider = DocumentFactProvider()
        let baseTool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )
        let arguments: [String: JSONValue] = [
            "action": .string("summarize"),
            "path": .string("symlink.pdf"),
            "task": .string("Preserve FACT-1.")
        ]
        let baseline = try decodeObject(await baseTool.execute(arguments: arguments))
        let jobID = try #require(baseline["checkpoint_job_id"]?.stringValue)
        let job = jobs.appending(path: jobID)

        try FileManager.default.removeItem(at: job)
        try FileManager.default.createSymbolicLink(at: job, withDestinationURL: outside)
        let directoryEscapeTool = try HierarchicalDocumentTool(
            provider: provider,
            model: "fixture",
            authorizedRoot: artifacts,
            jobsRoot: jobs
        )
        await #expect(throws: HierarchicalDocumentToolError.self) {
            try await directoryEscapeTool.execute(arguments: arguments)
        }

        try FileManager.default.removeItem(at: job)
        _ = try decodeObject(await baseTool.execute(arguments: arguments))
        let checkpoint = job.appending(path: "unit-0-segment-0.json")
        try FileManager.default.removeItem(at: checkpoint)
        let externalFile = outside.appending(path: "external.json")
        try Data("outside".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: checkpoint,
            withDestinationURL: externalFile
        )
        await #expect(throws: HierarchicalDocumentToolError.self) {
            try await baseTool.execute(arguments: arguments)
        }
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "outside")
    }
}

private actor DocumentFactProvider: ModelProvider, ModelIdentityProviding {
    private(set) var requestCount = 0

    func immutableModelIdentity(for model: String) async throws -> String {
        "fixture-model-digest"
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
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(facts.sorted().joined(separator: " ")))
            continuation.yield(.completed(ModelUsage()))
            continuation.finish()
        }
    }
}

private func decodeObject(_ content: String) throws -> [String: JSONValue] {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
    return try #require(value.objectValue)
}

private func createSummaryPDF(at url: URL, pages: [String]) throws {
    guard let consumer = CGDataConsumer(url: url as CFURL) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    for text in pages {
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}