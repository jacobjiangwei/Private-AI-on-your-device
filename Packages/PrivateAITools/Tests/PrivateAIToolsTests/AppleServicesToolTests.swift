import Foundation
import LLMCore
import Testing
@testable import PrivateAITools

@Suite("Non-Protected Apple Services Integration and Contracts", .serialized)
struct AppleServicesToolTests {
    @Test("reads device information")
    func deviceInfo() async throws {
        try await verifyInformationAction("device_info")
    }

    @Test("reads locale information")
    func localeInfo() async throws {
        try await verifyInformationAction("locale_info")
    }

    @Test("reads time-zone information")
    func timeZone() async throws {
        try await verifyInformationAction("time_zone")
    }

    @Test("reads storage information")
    func storageInfo() async throws {
        try await verifyInformationAction("storage_info")
    }

    @Test("reads power and thermal state")
    func powerStatus() async throws {
        try await verifyInformationAction("power_status")
    }

    @Test("reads network path status")
    func networkStatus() async throws {
        try await verifyInformationAction("network_status")
    }

    private func verifyInformationAction(_ action: String) async throws {
        let tool = AppleServicesTool()
        let object = try await executeObject(tool, arguments: [
            "action": .string(action)
        ])

        #expect(!object.isEmpty)
        if action == "device_info" {
            #expect(object["platform"] == .string("macOS"))
        }
        let requiredKey: String = switch action {
        case "device_info": "operating_system"
        case "locale_info": "identifier"
        case "time_zone": "seconds_from_gmt"
        case "storage_info": "total_bytes"
        case "power_status": "thermal_state"
        case "network_status": "status"
        default: ""
        }
        #expect(object[requiredKey] != nil)
    }

    @Test("rejects incomplete MapKit coordinates")
    func coordinatePair() async {
        let tool = AppleServicesTool()

        await #expect(
            throws: CapabilityToolError.invalidArgument("latitude/longitude")
        ) {
            try await tool.execute(arguments: [
                "action": .string("search_places"),
                "query": .string("Apple Park"),
                "latitude": .number(37.3349)
            ])
        }
    }

    @Test("defaults side-effecting native actions to serial execution")
    func concurrencyPolicy() async {
        let tool = AppleServicesTool()

        #expect(!tool.isConcurrencySafe(arguments: [
            "action": .string("current_location")
        ]))
        #expect(!tool.isConcurrencySafe(arguments: [
            "action": .string("open_url")
        ]))
        #expect(tool.isConcurrencySafe(arguments: [
            "action": .string("device_info")
        ]))
        #expect(tool.isConcurrencySafe(arguments: [
            "action": .string("search_places")
        ]))
    }

}

private func executeObject(
    _ tool: AppleServicesTool,
    arguments: [String: JSONValue]
) async throws -> [String: JSONValue] {
    let content = try await tool.execute(arguments: arguments)
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
    return try #require(value.objectValue)
}