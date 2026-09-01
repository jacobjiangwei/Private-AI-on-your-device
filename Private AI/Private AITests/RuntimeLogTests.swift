import Foundation
import Testing
@testable import Private_AI

@Suite("Runtime Log")
struct RuntimeLogTests {
    @Test("preserves ordered diagnostics while redacting credentials")
    func orderedRedactedTrace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "app.jsonl")
        let log = try RuntimeLog(fileURL: fileURL)
        let runID = UUID()

        await log.record(
            "model.request.finished",
            category: "model",
            runID: runID,
            data: [
                "output_token_count": 42,
                "password": "do-not-log",
                "access_token": "do-not-log"
            ]
        )
        await log.record(
            "run.finished",
            category: "agent",
            runID: runID,
            data: ["tokens_per_second": 21.5]
        )

        let runFileURL = await log.runFileURL(for: runID)
        let records = try String(contentsOf: runFileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                try #require(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
            }
        #expect(records.count == 2)
        #expect(records[0]["sequence"] as? Int == 1)
        #expect(records[1]["sequence"] as? Int == 2)
        #expect(records[0]["run_id"] as? String == runID.uuidString)
        let firstData = try #require(records[0]["data"] as? [String: Any])
        #expect(firstData["output_token_count"] as? Int == 42)
        #expect(firstData["password"] as? String == "[REDACTED]")
        #expect(firstData["access_token"] as? String == "[REDACTED]")
        #expect(!String(data: try Data(contentsOf: runFileURL), encoding: .utf8)!.contains("do-not-log"))
        #expect(try Data(contentsOf: fileURL).isEmpty)
    }

    @Test("writes each run to a separate file")
    func separateRunFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try RuntimeLog(fileURL: root.appending(path: "app.jsonl"))
        let firstRun = UUID()
        let secondRun = UUID()

        await log.record("run.started", runID: firstRun)
        await log.record("run.started", runID: secondRun)

        let firstFile = await log.runFileURL(for: firstRun)
        let secondFile = await log.runFileURL(for: secondRun)
        #expect(firstFile != secondFile)
        #expect(FileManager.default.fileExists(atPath: firstFile.path))
        #expect(FileManager.default.fileExists(atPath: secondFile.path))
        #expect(try String(contentsOf: firstFile, encoding: .utf8).contains(firstRun.uuidString))
        #expect(try String(contentsOf: secondFile, encoding: .utf8).contains(secondRun.uuidString))
    }
}