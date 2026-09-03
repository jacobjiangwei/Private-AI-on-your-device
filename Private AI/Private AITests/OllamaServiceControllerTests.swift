import Foundation
import Testing
@testable import Private_AI

@Suite("Ollama Service Controller")
@MainActor
struct OllamaServiceControllerTests {
    @Test("reports not installed when the service and app are unavailable")
    func reportsNotInstalled() async throws {
        let controller = try makeController(locateApplication: { nil })

        await controller.refresh()

        #expect(controller.state == .notInstalled)
    }

    @Test("reports not running when the app is installed")
    func reportsNotRunning() async throws {
        let controller = try makeController {
            URL(fileURLWithPath: "/Applications/Ollama.app")
        }

        await controller.refresh()

        #expect(controller.state == .notRunning)
    }

    private func makeController(
        locateApplication: @escaping () -> URL?
    ) throws -> OllamaServiceController {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnavailableOllamaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let log = try RuntimeLog(fileURL: root.appending(path: "app.jsonl"))
        return OllamaServiceController(
            log: log,
            session: session,
            locateApplication: locateApplication
        )
    }
}

private final class UnavailableOllamaURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}