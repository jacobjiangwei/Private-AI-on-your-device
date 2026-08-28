import AppKit
import CoreGraphics
import CoreText
import Darwin
import Foundation
import XCTest
@testable import PrivateAI

final class AttachmentBenchmarkTests: XCTestCase {
    func testPDFKitThreeHundredPageBaseline() async throws {
        guard ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Run the PrivateAI-Tests scheme to record the 300-page PDF baseline.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-PDF-Benchmark", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("generated-300-pages.pdf")
        try makePDF(at: source, pageCount: 300)
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true)
        )
        let residentBefore = residentBytes()
        let started = ContinuousClock.now

        let attachment = try await store.importFile(at: source)

        let elapsed = started.duration(to: .now)
        let seconds = durationSeconds(elapsed)
        let chunks = try await store.extractedChunks(for: attachment.id)
        let residentAfter = residentBytes()
        let ordered = chunks.enumerated().allSatisfy { offset, chunk in
            chunk.page == offset + 1
                && chunk.text.contains(String(format: "PRIVATEAI-PAGE-%03d", offset + 1))
        }
        let artifact = PDFBenchmarkArtifact(
            recordedAtUTC: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            parserID: attachment.artifact?.parserID ?? "unknown",
            pageCount: attachment.artifact?.pageCount ?? 0,
            chunkCount: attachment.artifact?.chunkCount ?? 0,
            characterCount: attachment.artifact?.characterCount ?? 0,
            sourceBytes: attachment.byteCount,
            wallSeconds: seconds,
            pagesPerSecond: seconds > 0 ? 300 / seconds : 0,
            residentBytesBefore: residentBefore,
            residentBytesAfter: residentAfter,
            orderedSentinelPages: ordered ? 300 : 0
        )
        let output = root.appendingPathComponent("latest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: output, options: .atomic)

        XCTAssertEqual(attachment.state, .ready)
        XCTAssertEqual(attachment.artifact?.parserID, "pdfkit-text")
        XCTAssertEqual(attachment.artifact?.pageCount, 300)
        XCTAssertEqual(chunks.count, 300)
        XCTAssertTrue(ordered, "Generated page sentinels were missing or out of order")
        XCTAssertGreaterThan(artifact.pagesPerSecond, 0)
    }

    private func makePDF(at url: URL, pageCount: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 1...pageCount {
            context.beginPDFPage(nil)
            let sentinel = String(format: "PRIVATEAI-PAGE-%03d", page)
            let text = "\(sentinel) Local PDF benchmark text with table-like values \(page), \(page * 2), \(page * 3)."
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 14)]
                )
            )
            context.textPosition = CGPoint(x: 48, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct PDFBenchmarkArtifact: Codable {
    let recordedAtUTC: String
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let parserID: String
    let pageCount: Int
    let chunkCount: Int
    let characterCount: Int
    let sourceBytes: Int64
    let wallSeconds: Double
    let pagesPerSecond: Double
    let residentBytesBefore: UInt64
    let residentBytesAfter: UInt64
    let orderedSentinelPages: Int
}
