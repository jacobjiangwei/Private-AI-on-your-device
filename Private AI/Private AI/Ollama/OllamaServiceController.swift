import AppKit
import Foundation
import Observation

enum OllamaConnectionState: Equatable {
    case checking
    case ready(version: String)
    case notInstalled
    case notRunning
    case starting
    case failed(String)

    var label: String {
        switch self {
        case .checking: "Checking Ollama"
        case .ready(let version): "Ollama \(version)"
        case .notInstalled: "Ollama is not installed"
        case .notRunning: "Ollama is not running"
        case .starting: "Starting Ollama"
        case .failed(let message): message
        }
    }

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

@MainActor
@Observable
final class OllamaServiceController {
    private(set) var state: OllamaConnectionState = .checking
    private(set) var models: [String] = []
    var selectedModel = ""

    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession
    private let log: RuntimeLog
    private let locateApplication: () -> URL?

    init(
        log: RuntimeLog,
        session: URLSession? = nil,
        locateApplication: (() -> URL?)? = nil
    ) {
        self.log = log
        self.locateApplication = locateApplication ?? Self.applicationURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func refresh() async {
        state = .checking
        await log.record("ollama.refresh.started")
        do {
            async let version = loadVersion()
            async let installedModels = loadModels()
            let (resolvedVersion, resolvedModels) = try await (version, installedModels)
            models = resolvedModels
            if selectedModel.isEmpty || !models.contains(selectedModel) {
                selectedModel = models.first ?? ""
            }
            state = .ready(version: resolvedVersion)
            await log.record("ollama.refresh.ready", fields: [
                "model_count": String(models.count),
                "selected_model": selectedModel,
                "version": resolvedVersion
            ])
        } catch {
            models = []
            state = locateApplication() == nil ? .notInstalled : .notRunning
            await log.record("ollama.refresh.failed", fields: [
                "error": String(describing: error),
                "state": state.label
            ])
        }
    }

    func openOllama() async {
        state = .starting
        let workspace = NSWorkspace.shared
        guard let applicationURL = locateApplication() else {
            state = .notInstalled
            return
        }

        do {
            _ = try await workspace.openApplication(
                at: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(500))
                await refresh()
                if state.isReady { return }
            }
            state = .failed("Ollama started but did not become ready.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openInstallationGuide() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!)
    }

    private func loadVersion() async throws -> String {
        let (data, response) = try await session.data(from: baseURL.appending(path: "api/version"))
        try validate(response)
        return try JSONDecoder().decode(VersionResponse.self, from: data).version
    }

    private func loadModels() async throws -> [String] {
        let (data, response) = try await session.data(from: baseURL.appending(path: "api/tags"))
        try validate(response)
        return try JSONDecoder().decode(TagsResponse.self, from: data).models
            .map(\.name)
            .sorted()
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func applicationURL() -> URL? {
        let workspace = NSWorkspace.shared
        let candidates = [
            workspace.urlForApplication(withBundleIdentifier: "com.electron.ollama"),
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/Ollama.app", directoryHint: .isDirectory)
        ].compactMap { $0 }
        return candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }
}

private struct VersionResponse: Decodable {
    let version: String
}

private struct TagsResponse: Decodable {
    let models: [InstalledModel]
}

private struct InstalledModel: Decodable {
    let name: String
}