import Foundation

public struct ToolDiagnostic: Sendable {
    public let event: String
    public let level: String
    public let data: [String: String]

    public init(event: String, level: String = "info", data: [String: String] = [:]) {
        self.event = event
        self.level = level
        self.data = data
    }
}

public enum ToolDiagnostics {
    public typealias Handler = @Sendable (ToolDiagnostic) async -> Void

    @TaskLocal public static var handler: Handler?

    public static func record(
        _ event: String,
        level: String = "info",
        data: [String: String] = [:]
    ) async {
        await handler?(ToolDiagnostic(event: event, level: level, data: data))
    }
}