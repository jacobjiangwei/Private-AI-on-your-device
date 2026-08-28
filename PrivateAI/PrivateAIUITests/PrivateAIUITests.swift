//
//  PrivateAIUITests.swift
//  PrivateAIUITests
//
import XCTest

final class PrivateAIUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testJourney_ReadyChat_ModelChoiceFileConsentAndBranching() throws {
        let app = step("01 | Launch | Ready fixture -> composer available") {
            launchReadyApp()
        }

        step("02 | Models | Select llama3.2:latest -> toolbar updates") {
            let modelStatus = app.buttons["model-status.open"]
            XCTAssertTrue(modelStatus.waitForExistence(timeout: 2))
            modelStatus.click()
            XCTAssertTrue(
                app.staticTexts["Local model status"]
                    .waitForExistence(timeout: 2)
            )
            let picker = app.popUpButtons["model-status.picker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 2))
            picker.click()
            let llama = app.menuItems["llama3.2:latest"]
            XCTAssertTrue(llama.waitForExistence(timeout: 2))
            llama.click()

            let selected = expectation(
                for: NSPredicate(format: "value == 'llama3.2:latest'"),
                evaluatedWith: modelStatus
            )
            wait(for: [selected], timeout: 2)
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }

        step("03 | Files | Cancel path permission -> draft remains") {
            let composer = app.descendants(matching: .textView)["chat.composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 3))
            composer.click()
            composer.typeText("/Users/example/word-online-snapshot.md\nRead this file")
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 2))
            let enabled = expectation(
                for: NSPredicate(format: "enabled == true"),
                evaluatedWith: send
            )
            wait(for: [enabled], timeout: 2)
            send.click()

            let openPanel = app.sheets.firstMatch
            XCTAssertTrue(openPanel.waitForExistence(timeout: 3))
            XCTAssertTrue(openPanel.buttons["Cancel"].waitForExistence(timeout: 2))
            openPanel.buttons["Cancel"].click()
            XCTAssertTrue(
                app.staticTexts["File access was not granted."]
                    .waitForExistence(timeout: 3)
            )
            let draft = composer.value as? String ?? ""
            XCTAssertTrue(draft.contains("word-online-snapshot.md"))
            composer.click()
            composer.typeKey("a", modifierFlags: .command)
            composer.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        }

        step("04 | Chat | Send prompt -> completed fixture response") {
            send("Say hello", in: app)
            let answer = app.staticTexts["Hello from local Qwen fixture"]
            XCTAssertTrue(answer.waitForExistence(timeout: 3))
            let status = app.staticTexts["chat.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 2))
            let ready = expectation(
                for: NSPredicate(format: "label == 'Ready' OR value == 'Ready'"),
                evaluatedWith: status
            )
            wait(for: [ready], timeout: 2)
            XCTAssertFalse(app.buttons["chat.stop"].exists)
        }

        step("05 | Search | Find answer text -> matching chat opens") {
            let newChat = app.buttons["New chat"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 2))
            newChat.click()
            let search = app.textFields["chat.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 2))
            search.click()
            search.typeText("local Qwen fixture")
            let result = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH 'chat.search.result.'"
                )
            ).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 2))
            XCTAssertTrue(result.label.contains("Hello from local Qwen fixture"))
            result.click()
            XCTAssertTrue(
                app.staticTexts["Hello from local Qwen fixture"]
                    .waitForExistence(timeout: 2)
            )
            search.typeKey("a", modifierFlags: .command)
            search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        }

        step("06 | Branch | Edit and resend -> branch becomes visible") {
            let edit = app.buttons["Edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 2))
            edit.click()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 2))
            let composer = app.descendants(matching: .textView)["chat.composer"]
            composer.click()
            composer.typeKey("a", modifierFlags: .command)
            composer.typeText("Edited prompt")
            let sendInNewChat = app.buttons["Send in new chat"]
            XCTAssertTrue(sendInNewChat.waitForExistence(timeout: 2))
            sendInNewChat.click()

            XCTAssertTrue(branchLabel(in: app).waitForExistence(timeout: 3))
            XCTAssertTrue(
                app.staticTexts["Hello from local Qwen fixture"]
                    .waitForExistence(timeout: 3)
            )
        }
    }

    @MainActor
    func testJourney_MissingOllama_InstallHandoffPreservesDraft() throws {
        let app = step("01 | Launch | Missing Ollama -> install guidance") {
            launchApp(arguments: ["--privateai-ui-test-missing-ollama"])
        }

        step("02 | Recovery | Show official download and recheck only") {
            XCTAssertTrue(
                app.staticTexts["Install Ollama from the official site"]
                    .waitForExistence(timeout: 3)
            )
            XCTAssertTrue(app.buttons["Official Download"].exists)
            XCTAssertTrue(app.buttons["Recheck"].exists)
            XCTAssertFalse(app.buttons["Copy Pull Command"].exists)
        }

        step("03 | Draft | Keep text while sending remains blocked") {
            let composer = app.descendants(matching: .textView)["chat.composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 2))
            composer.click()
            composer.typeText("Keep this draft")
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 2))
            XCTAssertFalse(send.isEnabled)
            let draft = composer.value as? String
            XCTAssertTrue(draft?.contains("Keep") == true)
            XCTAssertTrue(draft?.contains("draft") == true)
        }
    }

    @MainActor
    func testJourney_MissingModel_PullHandoffBlocksSend() throws {
        let app = step("01 | Launch | No models -> model guidance") {
            launchApp(arguments: ["--privateai-ui-test-missing-model"])
        }

        step("02 | Recovery | Show recommended pull handoff and block send") {
            XCTAssertTrue(
                app.staticTexts["Add an Ollama model"]
                    .waitForExistence(timeout: 3)
            )
            XCTAssertTrue(app.staticTexts["ollama pull qwen3.8:27b-mlx"].exists)
            XCTAssertTrue(
                app.staticTexts.matching(
                    NSPredicate(
                        format: "label CONTAINS[c] 'available disk' OR value CONTAINS[c] 'available disk'"
                    )
                ).firstMatch.waitForExistence(timeout: 2)
            )
            XCTAssertTrue(app.buttons["Copy Pull Command"].exists)
            XCTAssertTrue(app.buttons["Model Page"].exists)
            XCTAssertTrue(app.buttons["Recheck"].exists)
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 2))
            XCTAssertFalse(send.isEnabled)
        }
    }

    @MainActor
    func testJourney_StartupFailure_RetryRecoversInPlace() throws {
        let app = step("01 | Launch | Storage failure -> retry screen") {
            launchApp(arguments: [
                "--privateai-ui-test",
                "--privateai-ui-test-startup-failure-once"
            ])
        }

        step("02 | Startup | Retry -> chat recovers without relaunch") {
            XCTAssertTrue(
                app.staticTexts["Local data unavailable"]
                    .waitForExistence(timeout: 3)
            )
            XCTAssertTrue(app.descendants(matching: .any)["startup.failure"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["chat.root"].exists)

            let retry = app.buttons["Retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 2))
            retry.click()
            waitUntilReady(app, timeout: 10)
        }
    }

    @MainActor
    func testJourney_DocumentLibrary_SearchAttachAndDelete() throws {
        let app = step("01 | Launch | Seeded Library -> ready chat") {
            let app = launchApp(arguments: [
                "--privateai-ui-test",
                "--privateai-ui-test-library"
            ])
            waitUntilReady(app)
            return app
        }

        step("02 | Library | Search and attach seeded document") {
            let openLibrary = app.buttons["library.open"]
            XCTAssertTrue(openLibrary.waitForExistence(timeout: 2))
            openLibrary.click()
            let search = app.searchFields["Search files and contents"]
            XCTAssertTrue(search.waitForExistence(timeout: 2))
            search.click()
            search.typeText("LIBRARY-UI-SEARCH-73")
            XCTAssertTrue(
                app.staticTexts["library-fixture.md"]
                    .waitForExistence(timeout: 2)
            )

            let add = app.buttons["Add library-fixture.md to chat"]
            XCTAssertTrue(add.waitForExistence(timeout: 2))
            add.click()
            app.buttons["Done"].click()
            XCTAssertTrue(
                app.staticTexts["library-fixture.md"]
                    .waitForExistence(timeout: 2)
            )
        }

        step("03 | Library | Confirm deletion -> document disappears") {
            let openLibrary = app.buttons["library.open"]
            openLibrary.click()
            let delete = app.buttons["Delete library-fixture.md from Library"]
            XCTAssertTrue(delete.waitForExistence(timeout: 2))
            delete.click()
            let confirm = app.sheets.buttons["Delete"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 2))
            confirm.click()
            XCTAssertTrue(app.staticTexts["No documents"].waitForExistence(timeout: 2))
        }
    }

    @MainActor
    func testJourney_FailedGeneration_RetryCreatesBranch() throws {
        let app = step("01 | Launch | Failed-chat fixture -> ready chat") {
            let app = launchApp(arguments: [
                "--privateai-ui-test",
                "--privateai-ui-test-failed-chat"
            ])
            waitUntilReady(app)
            return app
        }

        step("02 | Chat | First generation fails -> retry appears") {
            send("Retry prompt", in: app)
            XCTAssertTrue(app.staticTexts["Partial fixture"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 2))
        }

        step("03 | Recovery | Retry -> recovered branch becomes visible") {
            app.buttons["Retry"].click()
            XCTAssertTrue(branchLabel(in: app).waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Recovered fixture"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testStoreScreenshotsEnglish() throws {
        let app = launchApp(arguments: [
            "--privateai-ui-test",
            "--privateai-ui-test-store-assets",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ])
        XCTAssertTrue(app.buttons["library.open"].waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        captureStoreScreenshot(named: "en-US-01-chat", app: app)

        app.buttons["library.open"].click()
        XCTAssertTrue(
            app.staticTexts["product-brief.md"].waitForExistence(timeout: 3)
        )
        captureStoreScreenshot(named: "en-US-02-library", app: app)
    }

    @MainActor
    private func launchReadyApp() -> XCUIApplication {
        let app = launchApp(arguments: ["--privateai-ui-test"])
        waitUntilReady(app)
        return app
    }

    @MainActor
    private func launchApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func send(_ prompt: String, in app: XCUIApplication) {
        let composer = app.descendants(matching: .textView)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.click()
        composer.typeText(prompt)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        let enabled = expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: send
        )
        wait(for: [enabled], timeout: 2)
        send.click()
    }

    @MainActor
    private func waitUntilReady(
        _ app: XCUIApplication,
        timeout: TimeInterval = 3
    ) {
        app.activate()
        let status = app.staticTexts["chat.status"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout))
        let connected = expectation(
            for: NSPredicate(
                format: "label == 'Ollama connected' OR value == 'Ollama connected'"
            ),
            evaluatedWith: status
        )
        wait(for: [connected], timeout: timeout)
    }

    @MainActor
    private func branchLabel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.branch"]
    }

    @MainActor
    private func captureStoreScreenshot(
        named name: String,
        app: XCUIApplication
    ) {
        let attachment = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func step<Result>(
        _ name: String,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try XCTContext.runActivity(named: name) { _ in
            try body()
        }
    }
}
