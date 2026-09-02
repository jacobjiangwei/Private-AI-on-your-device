import Foundation
import Testing
@testable import Private_AI

@Suite("Document Privacy Policy")
struct DocumentPrivacyPolicyTests {
    @Test("attachment conversations expose only the local document tool")
    func localOnlyToolCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = try RuntimeLog(fileURL: root.appending(path: "app.jsonl"))
        let agent = try ChatAgent(
            log: log,
            localResourcesRoot: root,
            jobsRoot: root.appending(path: "jobs")
        )

        let privateNames = try await agent.availableToolNames(documentPrivacyMode: true)
        let generalNames = try await agent.availableToolNames(documentPrivacyMode: false)

        #expect(privateNames == ["document_analysis", "local_resources"])
        #expect(generalNames.contains("local_resources"))
        #expect(generalNames.contains("web"))
        #expect(generalNames.contains("apple_services"))
    }
}