import XCTest

final class AppleServicesE2EScenarios: XCTestCase {
    @MainActor
    func testAppLayerLocationDemo() throws {
        let app = XCUIApplication()
        app.launch()

        let demoButton = app.buttons["location.demo.button"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 10))
        demoButton.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["location.demo.panel"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["location.demo.request"].click()
        let received = app.staticTexts["location.demo.state"]
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Location received"),
            object: received
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 35), .completed)
        XCTAssertTrue(app.staticTexts["location.demo.latitude"].exists)
        XCTAssertTrue(app.staticTexts["location.demo.longitude"].exists)
        XCTAssertFalse(app.staticTexts["location.demo.error"].exists)
    }

    @MainActor
    func testAuthorizationStatusThroughOllama() throws {
        throw XCTSkip("TODO: Launch the signed App, ask Ollama which native services are authorized, and compare every reported state with the App-hosted framework results.")
    }

    @MainActor
    func testCurrentLocationThroughOllama() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["model.performance.label"]
                .waitForExistence(timeout: 60)
        )
        app.buttons["conversation.new.button"].click()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        composer.typeText(
            "Use apple_services current_location to tell me my current city. "
                + "Use the city returned by the tool and do not infer it from coordinates."
        )
        app.buttons["chat.send.button"].click()

        let stopButton = app.buttons["chat.stop.button"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 10))
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stopButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 120), .completed)

        let suzhouResult = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "苏州"))
            .firstMatch
        XCTAssertTrue(suzhouResult.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Tool execution failed."].exists)
    }

    @MainActor
    func testNearbyPlaceSearchThroughOllama() throws {
        throw XCTSkip("TODO: Launch the App, ask Ollama for a nearby place, require a successful real MapKit response, and verify the final answer names a returned place.")
    }

    @MainActor
    func testCalendarListingThroughOllama() throws {
        throw XCTSkip("TODO: Launch the signed App with Calendar authorization, ask Ollama to list calendars, and compare its final answer with real EventKit titles.")
    }

    @MainActor
    func testReminderListListingThroughOllama() throws {
        throw XCTSkip("TODO: Launch the signed App with Reminders authorization, ask Ollama to list reminder lists, and compare its final answer with real EventKit titles.")
    }

    @MainActor
    func testContactSearchThroughOllama() throws {
        throw XCTSkip("TODO: Launch the signed App with Contacts authorization, create a uniquely tagged contact through Contacts, ask Ollama to find it, verify the final answer, and remove it.")
    }

    @MainActor
    func testNotificationStatusThroughOllama() throws {
        throw XCTSkip("TODO: Launch the signed App, ask Ollama for notification authorization and presentation settings, and compare its final answer with UserNotifications.")
    }

    @MainActor
    func testOpenURLThroughOllama() throws {
        throw XCTSkip("TODO: Launch the App, ask Ollama to open a controlled HTTPS URL, and verify the real user-visible workspace operation and exact destination.")
    }
}