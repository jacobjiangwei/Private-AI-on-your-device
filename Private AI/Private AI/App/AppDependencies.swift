import Foundation
import SwiftData

@MainActor
final class AppDependencies {
    let container: ModelContainer
    let database: ConversationDatabase
    let ollama: OllamaServiceController
    let agent: ChatAgent
    let runtimeDirectory: ManagedRuntimeDirectory
    let runtimeLog: RuntimeLog

    init() throws {
        runtimeDirectory = try ManagedRuntimeDirectory()
        runtimeLog = try RuntimeLog(directory: runtimeDirectory)
        let schema = Schema([
            ConversationRecord.self,
            MessageRecord.self
        ])
        container = try ModelContainer(for: schema)
        database = ConversationDatabase(container: container)
        ollama = OllamaServiceController(log: runtimeLog)
        agent = try ChatAgent(log: runtimeLog)
        try database.markInterruptedMessages()
        Task {
            await runtimeLog.record("app.initialized", fields: [
                "managed_root": runtimeDirectory.root.path
            ])
        }
    }
}