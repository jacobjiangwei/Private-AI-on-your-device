//
//  Private_AIUITests.swift
//  Private AIUITests
//
//  Created by jacob on 2026/8/29.
//

import XCTest

final class Private_AIUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testModelTransparencyAndNewConversationFocus() throws {
        let app = XCUIApplication()
        app.launch()

        let performance = app.descendants(matching: .any)["model.performance.label"]
        guard performance.waitForExistence(timeout: 60) else {
            throw XCTSkip("Ollama did not become ready, so model UI could not be exercised.")
        }
        XCTAssertTrue(performance.label.contains("TTFT"), performance.debugDescription)
        XCTAssertTrue(performance.label.contains("tok/s"), performance.debugDescription)

        let transparencyButton = app.buttons["model.transparency.button"]
        XCTAssertTrue(transparencyButton.exists)
        transparencyButton.click()
        let transparencyPanel = app.descendants(matching: .any)["model.transparency.panel"]
        XCTAssertTrue(transparencyPanel.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["System prompt"].exists)
        XCTAssertTrue(app.staticTexts["Version 2"].exists)

        app.typeKey(.escape, modifierFlags: [])
        app.buttons["conversation.new.button"].click()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        // TODO: Assert focus through an App-owned test probe; never inject keyboard input.
    }

    @MainActor
    func testWebToolInputOutputPrecedesFinalAnswerAndScrollsToLatest() throws {
        let app = XCUIApplication()
        app.launch()

        guard app.descendants(matching: .any)["model.performance.label"]
            .waitForExistence(timeout: 60)
        else {
            throw XCTSkip("Ollama did not become ready, so the Tool E2E could not run.")
        }

        app.buttons["conversation.new.button"].click()
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        throw XCTSkip(
            "TODO: Drive this scenario through an App-owned test API without keyboard injection, then verify the Tool transcript and product log."
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
