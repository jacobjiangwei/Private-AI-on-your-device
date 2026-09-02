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
    let artifactStore: ManagedArtifactStore

    init() throws {
        runtimeDirectory = try ManagedRuntimeDirectory()
        try RuntimeLog.preparePrivacyMigration(
            logsDirectory: runtimeDirectory.logs,
            stateDirectory: runtimeDirectory.state
        )
        runtimeLog = try RuntimeLog(directory: runtimeDirectory)
        artifactStore = try ManagedArtifactStore(root: runtimeDirectory.artifacts)
        let schema = Schema(versionedSchema: PrivateAISchemaV2.self)
        container = try ModelContainer(
            for: schema,
            migrationPlan: PrivateAISchemaMigrationPlan.self
        )
        database = ConversationDatabase(container: container)
        ollama = OllamaServiceController(log: runtimeLog)
        agent = try ChatAgent(
            log: runtimeLog,
            localResourcesRoot: runtimeDirectory.artifacts,
            jobsRoot: runtimeDirectory.jobs
        )
        try database.sanitizeLegacyLocalResourceMessages()
        try database.markInterruptedMessages()
        Task {
            await runtimeLog.record("app.initialized", fields: [
                "managed_root": runtimeDirectory.root.path
            ])
            do {
                let referencedPaths = try database.referencedArtifactPaths()
                let result = try await artifactStore.reconcile(
                    referencedRelativePaths: referencedPaths
                )
                try database.removeUnreferencedArtifactBlobs()
                await runtimeLog.record("artifacts.reconciled", fields: [
                    "missing_references": String(result.missingReferencedPaths.count),
                    "removed_orphans": String(result.removedOrphanFiles),
                    "removed_staging": String(result.removedStagingFiles)
                ])
            } catch {
                await runtimeLog.record("artifacts.reconciliation_failed", fields: [
                    "error": String(describing: error)
                ])
            }
        }
    }
}