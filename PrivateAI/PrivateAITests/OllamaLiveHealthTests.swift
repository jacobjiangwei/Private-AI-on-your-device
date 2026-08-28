import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrivateAI

final class OllamaLiveHealthTests: XCTestCase {
    func testInstalledQwenStreamsResponse() async throws {
        guard ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Run the PrivateAI-Tests scheme to exercise local Qwen.")
        }

        let modelName = "qwen3.8:27b-mlx"
        let client = OllamaClient()
        let models = try await client.models()
        XCTAssertTrue(
            models.contains { $0.name == modelName },
            "Install the exact supported model before running the live Qwen check."
        )
        let recorder = LiveEventRecorder()
        let result = try await client.streamChat(
            model: modelName,
            messages: [
                OllamaMessage(
                    role: .user,
                    content: "Reply with exactly: PRIVATEAI_LIVE_OK"
                )
            ],
            thinking: false,
            toolsEnabled: false,
            utilityToolsEnabled: false,
            localContextToolsEnabled: false,
            jsonFormat: false,
            onEvent: { event in
                await recorder.append(event)
            }
        )
        let sawContent = await recorder.sawContent

        XCTAssertTrue(sawContent)
        XCTAssertEqual(
            result.content.trimmingCharacters(in: .whitespacesAndNewlines),
            "PRIVATEAI_LIVE_OK"
        )
        XCTAssertGreaterThan(result.outputTokens, 0)
    }

    func testInstalledQwenUnderstandsLocalRedImage() async throws {
        guard ProcessInfo.processInfo.environment["PRIVATEAI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Run the PrivateAI-Tests scheme to exercise local Qwen vision.")
        }
        let client = OllamaClient()
        let image = try makeRedJPEG()

        let result = try await client.streamChat(
            model: OllamaClient.recommendedModelName,
            messages: [
                OllamaMessage(
                    role: .user,
                    content: "This image is one solid color. Reply with exactly the uppercase English color name and nothing else.",
                    images: [image.base64EncodedString()]
                )
            ],
            thinking: false,
            toolsEnabled: false,
            utilityToolsEnabled: false,
            localContextToolsEnabled: false,
            jsonFormat: false,
            onEvent: { _ in }
        )

        XCTAssertEqual(
            result.content.trimmingCharacters(in: .whitespacesAndNewlines),
            "RED"
        )
    }

    private func makeRedJPEG() throws -> Data {
        let width = 256
        let height = 256
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.coderInvalidValue) }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw CocoaError(.coderInvalidValue)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }
}

private actor LiveEventRecorder {
    private(set) var sawContent = false

    func append(_ event: OllamaStreamEvent) {
        if case .content(let content) = event, !content.isEmpty {
            sawContent = true
        }
    }
}