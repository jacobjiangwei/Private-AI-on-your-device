import CryptoKit
import Foundation
import PrivateAITools
import UniformTypeIdentifiers

nonisolated struct ImportedArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let storageKey: String
    let contentHash: String
    let relativePath: String
    let format: LocalDocumentFormat
    let contentTypeIdentifier: String
    let byteCount: Int64

    nonisolated init(
        id: UUID = UUID(),
        displayName: String,
        storageKey: String,
        contentHash: String,
        relativePath: String,
        format: LocalDocumentFormat,
        contentTypeIdentifier: String,
        byteCount: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.storageKey = storageKey
        self.contentHash = contentHash
        self.relativePath = relativePath
        self.format = format
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
    }
}

nonisolated enum ManagedArtifactStoreError: Error, Equatable, LocalizedError, Sendable {
    case tooManyFiles(Int)
    case notRegularFile(String)
    case unsupportedFormat(String)
    case fileTooLarge(Int)
    case coordinatedReadFailed(String)
    case corruptExistingArtifact(String)
    case invalidManagedPath(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles(let limit):
            "You can attach up to \(limit) documents at once."
        case .notRegularFile(let name):
            "'\(name)' is not a regular file."
        case .unsupportedFormat(let name):
            "'\(name)' is not a supported document format."
        case .fileTooLarge(let limit):
            "The document exceeds the \(limit)-byte attachment limit."
        case .coordinatedReadFailed(let reason):
            "The document could not be imported: \(reason)"
        case .corruptExistingArtifact(let path):
            "The managed artifact at '\(path)' failed its integrity check."
        case .invalidManagedPath(let path):
            "The managed artifact path '\(path)' is invalid."
        }
    }
}

nonisolated struct ArtifactReconciliationResult: Equatable, Sendable {
    let removedStagingFiles: Int
    let removedOrphanFiles: Int
    let missingReferencedPaths: [String]
}

actor ManagedArtifactStore {
    static let maximumFilesPerImport = 8
    static let maximumFileBytes = 20 * 1_024 * 1_024

    let root: URL
    private let blobsDirectory: URL
    private let stagingDirectory: URL
    private let fileManager: FileManager
    private let maximumFilesPerImport: Int
    private let maximumFileBytes: Int
    private var sessionImportLeases: [String: Int] = [:]

    init(
        root: URL,
        maximumFilesPerImport: Int = ManagedArtifactStore.maximumFilesPerImport,
        maximumFileBytes: Int = ManagedArtifactStore.maximumFileBytes,
        fileManager: FileManager = .default
    ) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        blobsDirectory = self.root.appending(path: "blobs", directoryHint: .isDirectory)
        stagingDirectory = self.root.appending(path: "staging", directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.maximumFilesPerImport = maximumFilesPerImport
        self.maximumFileBytes = maximumFileBytes
        try Self.createPrivateDirectory(self.root, fileManager: fileManager)
        try Self.createPrivateDirectory(blobsDirectory, fileManager: fileManager)
        try Self.createPrivateDirectory(stagingDirectory, fileManager: fileManager)
    }

    func importFiles(from urls: [URL]) throws -> [ImportedArtifact] {
        guard urls.count <= maximumFilesPerImport else {
            throw ManagedArtifactStoreError.tooManyFiles(maximumFilesPerImport)
        }
        var imported: [ImportedArtifact] = []
        do {
            for url in urls {
                imported.append(try importFile(from: url))
            }
            return imported
        } catch {
            release(imported)
            throw error
        }
    }

    func importFile(from sourceURL: URL) throws -> ImportedArtifact {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<ImportedArtifact, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try importCoordinatedFile(from: coordinatedURL)
            }
        }
        if let result {
            return try result.get()
        }
        throw ManagedArtifactStoreError.coordinatedReadFailed(
            coordinationError?.localizedDescription ?? "File coordination did not provide a readable URL."
        )
    }

    func resolve(relativePath: String) throws -> URL {
        let candidate = root.appending(path: relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard contains(candidate, root: root) else {
            throw ManagedArtifactStoreError.invalidManagedPath(relativePath)
        }
        return candidate
    }

    func release(_ artifacts: [ImportedArtifact]) {
        for artifact in artifacts {
            guard let count = sessionImportLeases[artifact.relativePath] else { continue }
            if count <= 1 {
                sessionImportLeases.removeValue(forKey: artifact.relativePath)
            } else {
                sessionImportLeases[artifact.relativePath] = count - 1
            }
        }
    }

    func reconcile(referencedRelativePaths: Set<String>) throws -> ArtifactReconciliationResult {
        let staged = try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        )
        for url in staged {
            try fileManager.removeItem(at: url)
        }

        let missing = referencedRelativePaths.filter { relativePath in
            guard let url = try? resolve(relativePath: relativePath) else { return true }
            return !fileManager.fileExists(atPath: url.path)
        }.sorted()
        let protectedPaths = referencedRelativePaths.union(sessionImportLeases.keys)
        let subpaths = try fileManager.subpathsOfDirectory(atPath: blobsDirectory.path)
        var removedOrphans = 0
        for subpath in subpaths {
            let url = blobsDirectory.appending(path: subpath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let relativePath = relativePath(for: url),
                  !protectedPaths.contains(relativePath)
            else {
                continue
            }
            try fileManager.removeItem(at: url)
            removedOrphans += 1
            try removeEmptyAncestors(startingAt: url.deletingLastPathComponent())
        }
        return ArtifactReconciliationResult(
            removedStagingFiles: staged.count,
            removedOrphanFiles: removedOrphans,
            missingReferencedPaths: missing
        )
    }

    private func importCoordinatedFile(from sourceURL: URL) throws -> ImportedArtifact {
        let resolvedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try resolvedSource.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentTypeKey
        ])
        guard values.isRegularFile == true else {
            throw ManagedArtifactStoreError.notRegularFile(sourceURL.lastPathComponent)
        }
        guard (values.fileSize ?? 0) <= maximumFileBytes else {
            throw ManagedArtifactStoreError.fileTooLarge(maximumFileBytes)
        }

        let format = LocalDocumentFormat.detect(url: resolvedSource)
        guard format.isSupported else {
            throw ManagedArtifactStoreError.unsupportedFormat(sourceURL.lastPathComponent)
        }

        let stagingURL = stagingDirectory.appending(path: UUID().uuidString)
        guard fileManager.createFile(
            atPath: stagingURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let digest = try copyAndHash(from: resolvedSource, to: stagingURL)
            let originalExtension = resolvedSource.pathExtension.lowercased()
            let storedExtension = originalExtension.isEmpty
                ? (format.preferredFilenameExtension ?? "txt")
                : originalExtension
            let storageKey = "\(digest).\(storedExtension)"
            let relativePath = "blobs/\(String(digest.prefix(2)))/\(digest)/content.\(storedExtension)"
            let destination = root.appending(path: relativePath)
            try Self.createPrivateDirectory(
                destination.deletingLastPathComponent(),
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard try hashFile(at: destination) == digest else {
                    throw ManagedArtifactStoreError.corruptExistingArtifact(relativePath)
                }
                try fileManager.removeItem(at: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destination)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            }
            sessionImportLeases[relativePath, default: 0] += 1
            let destinationValues = try destination.resourceValues(forKeys: [.fileSizeKey])
            return ImportedArtifact(
                displayName: sourceURL.lastPathComponent,
                storageKey: storageKey,
                contentHash: digest,
                relativePath: relativePath,
                format: format,
                contentTypeIdentifier: values.contentType?.identifier ?? "application/octet-stream",
                byteCount: Int64(destinationValues.fileSize ?? 0)
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func copyAndHash(from source: URL, to destination: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var hasher = SHA256()
        var byteCount = 0
        while let data = try input.read(upToCount: 64 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            byteCount += data.count
            guard byteCount <= maximumFileBytes else {
                throw ManagedArtifactStoreError.fileTooLarge(maximumFileBytes)
            }
            hasher.update(data: data)
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        return hexString(hasher.finalize())
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hexString(hasher.finalize())
    }

    private func hexString(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = digest.flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func contains(_ resource: URL, root: URL) -> Bool {
        let resourceComponents = resource.pathComponents
        let rootComponents = root.pathComponents
        return resourceComponents.count >= rootComponents.count
            && Array(resourceComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func relativePath(for url: URL) -> String? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return nil }
        return String(url.path.dropFirst(rootPath.count))
    }

    private func removeEmptyAncestors(startingAt directory: URL) throws {
        var candidate = directory
        while candidate != blobsDirectory, contains(candidate, root: blobsDirectory) {
            guard try fileManager.contentsOfDirectory(atPath: candidate.path).isEmpty else { return }
            try fileManager.removeItem(at: candidate)
            candidate = candidate.deletingLastPathComponent()
        }
    }

    private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}