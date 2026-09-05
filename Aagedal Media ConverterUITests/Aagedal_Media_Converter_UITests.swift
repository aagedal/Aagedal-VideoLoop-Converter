//
//  Aagedal_VideoLoop_Converter_2_0UITests.swift
//  Aagedal VideoLoop Converter 2.0UITests
//
//  Created by Truls Aagedal on 30/06/2024.
//

import XCTest

final class Aagedal_Media_Converter_UITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesWithEmptyQueue() throws {
        launchApp()
        defer { app.terminate() }

        XCTAssertTrue(element("queue.empty").waitForExistence(timeout: 10))
        XCTAssertTrue(element("toolbar.import").exists)
        XCTAssertTrue(element("toolbar.preset").exists)
        XCTAssertTrue(element("toolbar.settings").exists)
        XCTAssertEqual(element("toolbar.conversion").label, "Start Conversion")
    }

    @MainActor
    func testOpensSettingsAndMovesBetweenPanes() throws {
        launchApp()
        defer { app.terminate() }

        let settingsButton = element("toolbar.settings")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()

        let settingsRoot = element("settings.root")
        XCTAssertTrue(settingsRoot.waitForExistence(timeout: 10))
        let generalTab = element("settings.tab.general")
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5))
        XCTAssertEqual(settingsRoot.value as? String, "general")

        let presetsTab = element("settings.tab.presets")
        XCTAssertTrue(presetsTab.exists)
        presetsTab.click()
        XCTAssertEqual(settingsRoot.value as? String, "presets")

        let metadataTab = element("settings.tab.metadata")
        metadataTab.click()
        XCTAssertEqual(settingsRoot.value as? String, "metadata")
    }

    @MainActor
    func testImportsGeneratedFixtureAndSelectsPreset() throws {
        let fixtureDirectory = try makeFixtureDirectory()

        launchApp(generatedFixtureDirectory: fixtureDirectory)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertEqual(queueItem.label, "ui-test-fixture.mp4")
        XCTAssertEqual(queueItem.value as? String, "waiting")
        XCTAssertFalse(element("queue.empty").exists)

        let presetPicker = element("toolbar.preset")
        XCTAssertTrue(presetPicker.waitForExistence(timeout: 5))
        app.activate()
        presetPicker.click()

        let h264Preset = app.menuItems["H.264 / AVC"]
        if !h264Preset.waitForExistence(timeout: 2) {
            // A floating window from another app can occasionally steal the first
            // menu click on macOS. Reactivate and retry the interaction once.
            app.activate()
            presetPicker.click()
        }
        XCTAssertTrue(h264Preset.waitForExistence(timeout: 5))
        h264Preset.click()
        XCTAssertEqual(presetPicker.value as? String, "H.264 / AVC")
    }

    @MainActor
    func testStartsAndCancelsConversion() throws {
        let fixtureDirectory = try makeFixtureDirectory()

        launchApp(
            generatedFixtureDirectory: fixtureDirectory,
            defaultPreset: "H.264 / AVC",
            realtimeInput: true
        )
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertEqual(queueItem.value as? String, "waiting")

        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(conversionButton.waitForExistence(timeout: 5))
        XCTAssertTrue(conversionButton.isEnabled)
        conversionButton.click()

        XCTAssertTrue(waitForValue("converting", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForLabel("Cancel Conversion", of: conversionButton, timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("cancelled", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testExposesSuccessfulConversionResult() throws {
        let fixtureDirectory = try makeFixtureDirectory()

        launchApp(
            generatedFixtureDirectory: fixtureDirectory,
            defaultPreset: "H.264 / AVC"
        )
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(conversionButton.waitForExistence(timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("done", of: queueItem, timeout: 20))
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testExposesFailedConversionAndError() throws {
        let fixtureDirectory = try makeFixtureDirectory()

        launchApp(
            generatedFixtureDirectory: fixtureDirectory,
            defaultPreset: "H.264 / AVC"
        )
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertEqual(queueItem.label, "ui-test-fixture.mp4")
        try FileManager.default.removeItem(
            at: fixtureDirectory.appendingPathComponent("ui-test-fixture.mp4")
        )
        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(conversionButton.waitForExistence(timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("failed", of: queueItem, timeout: 20))
        let errorDetail = element("queue.item.detail")
        XCTAssertTrue(errorDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Cannot access input file", of: errorDetail, timeout: 5))
        let detailsButton = element("queue.item.errorDetails")
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 5))
        detailsButton.click()
        let expandedDetails = element("queue.errorDetails.text")
        XCTAssertTrue(expandedDetails.waitForExistence(timeout: 5))
        XCTAssertTrue((expandedDetails.value as? String ?? "").contains("Cannot access input file"))
        XCTAssertTrue(element("queue.errorDetails.copy").isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Queue error details"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    @MainActor
    private func launchApp(
        generatedFixtureDirectory: URL? = nil,
        defaultPreset: String = "VideoLoop",
        realtimeInput: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ffmpegBinarySource", "app"]
        if let generatedFixtureDirectory {
            app.launchArguments += [
                "-outputFolder", generatedFixtureDirectory.path,
                "-defaultExportPreset", defaultPreset,
                "-saveNextToOriginal", "NO",
            ]
            app.launchEnvironment["AMC_UI_TEST_GENERATED_FIXTURE"] = "1"
            app.launchEnvironment["AMC_UI_TEST_FIXTURE_DIRECTORY"] = generatedFixtureDirectory.path
            if realtimeInput {
                app.launchEnvironment["AMC_UI_TEST_REALTIME_INPUT"] = "1"
            }
        }
        app.launch()
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForLabel(_ label: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForEnabled(_ enabled: Bool, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "enabled == %@", NSNumber(value: enabled))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
