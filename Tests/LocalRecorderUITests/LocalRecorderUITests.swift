import XCTest

final class LocalRecorderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryNavigationAndModeChoicesAreDiscoverable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-unready"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Screen Only"].exists)
        XCTAssertTrue(app.buttons["Camera Only"].exists)
        XCTAssertTrue(app.buttons["Screen + Camera"].exists)
        XCTAssertTrue(app.staticTexts["Local-only · No uploads"].exists)

        app.staticTexts["Library"].click()
        XCTAssertTrue(app.staticTexts["Recordings"].waitForExistence(timeout: 2))

        app.staticTexts["Settings"].click()
        XCTAssertTrue(app.staticTexts["Privacy"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testRecordingIsDisabledBeforeRequiredSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-unready"
        ]
        app.launch()

        let recordButton = app.buttons["Start Recording"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        XCTAssertFalse(recordButton.isEnabled)
        XCTAssertTrue(app.staticTexts["Camera access"].exists)
        XCTAssertTrue(app.buttons["Grant Access"].exists)
    }

    @MainActor
    func testModeSwitchingAndReadyStateControls() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-ready"
        ]
        app.launch()

        let recordButton = app.buttons["Start Recording"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        XCTAssertTrue(recordButton.isEnabled)
        XCTAssertTrue(
            app.descendants(matching: .any)["microphone-toggle"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["quality-picker"].exists
        )

        app.buttons["Screen Only"].click()
        XCTAssertFalse(recordButton.isEnabled)
        XCTAssertTrue(app.staticTexts["No screen source selected"].exists)

        app.buttons["Camera Only"].click()
        XCTAssertTrue(recordButton.isEnabled)

        app.buttons["Screen + Camera"].click()
        XCTAssertFalse(recordButton.isEnabled)
    }

    @MainActor
    func testSwitchingModesCancelsPendingScreenSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-selecting"
        ]
        app.launch()

        let recordButton = app.buttons["Start Recording"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        XCTAssertFalse(recordButton.isEnabled)
        XCTAssertFalse(app.buttons["Full Screen"].isEnabled)
        XCTAssertFalse(app.buttons["Window"].isEnabled)
        XCTAssertFalse(app.buttons["Region"].isEnabled)

        app.buttons["Camera Only"].click()

        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: recordButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 2),
            .completed
        )
    }

    @MainActor
    func testLibraryActionsAreDiscoverable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-ready"
        ]
        app.launch()

        app.staticTexts["Library"].click()
        let fixture = app.staticTexts["UI Fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        fixture.click()

        XCTAssertTrue(app.buttons["Rename"].exists)
        XCTAssertTrue(app.buttons["Show in Finder"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Move to Trash"].exists)
    }

    @MainActor
    func testWindowCaptureOffersAdjustableWebContentOnlyCrop() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-window-content"
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["New Tab — Google Chrome"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "screen-preview-image"
            ].waitForExistence(timeout: 5)
        )
        let toggle = app.descendants(matching: .any)[
            "web-content-only-toggle"
        ]
        XCTAssertTrue(toggle.exists)

        toggle.click()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "browser-controls-height"
            ].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Adjust until the preview begins exactly at the top of the webpage."
            ].exists
        )
    }

    @MainActor
    func testCameraOnlyRecordingPreviewCanBeHiddenAndRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing-recording-controller"
        ]
        app.launch()

        let preview = app.descendants(matching: .any)[
            "recording-camera-preview"
        ]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))

        let hideButton = app.buttons["Hide Camera Preview"]
        XCTAssertTrue(hideButton.waitForExistence(timeout: 2))
        hideButton.click()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 2))

        let showButton = app.buttons["Show Camera Preview"]
        XCTAssertTrue(showButton.waitForExistence(timeout: 2))
        showButton.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["recording-camera-preview"]
                .waitForExistence(timeout: 2)
        )
    }
}
