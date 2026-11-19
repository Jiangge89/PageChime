import XCTest

/// Drives the app the way a parent would. The microphone is a scripted
/// reader (`UITEST_SPEECH`) and the camera returns rendered pages
/// (`UITEST_PAGES`); everything else is the real app. Tests that scan pages
/// need the backend running and PAGECHIME_LIVE_BACKEND set:
///
///   TEST_RUNNER_PAGECHIME_LIVE_BACKEND=1 xcodebuild test -only-testing:PageChimeUITests ...
final class ReadingFlowUITests: XCTestCase {
    static let demoEnglish = "The dog barked, then thunder rolled and rain began to fall."
    static let demoChinese = "小狗汪汪叫，天上打雷了，接着下起了雨。"
    static let pageOne = """
    Suddenly a big grey wolf stepped out from behind an oak. The wolf howled at the moon. \
    He knocked on the cottage door, knock knock. The old door creaked open. \
    Thunder rolled across the sky and rain poured down on the little house.
    """
    static let pageTwo = "Inside, a fire crackled in the fireplace. A little bird sang by the window, and far away a dog barked."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(onboarding: Bool = false, speech: String? = nil, pages: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-reset-state"]
        if !onboarding { app.launchArguments += ["-hasCompletedOnboarding", "YES"] }
        if let speech { app.launchEnvironment["UITEST_SPEECH"] = speech }
        if !pages.isEmpty { app.launchEnvironment["UITEST_PAGES"] = pages.joined(separator: "||") }
        app.launch()
        return app
    }

    private func requireLiveBackend() throws {
        guard ProcessInfo.processInfo.environment["PAGECHIME_LIVE_BACKEND"] != nil else {
            throw XCTSkip("Set PAGECHIME_LIVE_BACKEND (and run the backend) for scanning tests")
        }
    }

    // MARK: - Onboarding

    func testFirstLaunchShowsOnboardingOnceAndSkipGoesHome() {
        let app = launch(onboarding: true)
        XCTAssertTrue(app.staticTexts["Read any book aloud. Hear it come alive."].waitForExistence(timeout: 10))
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.buttons["Scan the first page"].waitForExistence(timeout: 5))

        // Remembered across launches.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-ui-testing"]
        again.launch()
        XCTAssertTrue(again.buttons["Scan the first page"].waitForExistence(timeout: 10))
        XCTAssertFalse(again.staticTexts["Read any book aloud. Hear it come alive."].exists)
    }

    func testOnboardingDemoHearsTheSentenceAndFinishes() {
        let app = launch(onboarding: true, speech: Self.demoEnglish)
        app.buttons["Get started"].tap()
        app.buttons["Turn on the microphone"].tap()
        XCTAssertTrue(app.staticTexts["That's PageChime."].waitForExistence(timeout: 20), "The demo sentence should set off its sounds")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["For the best results"].waitForExistence(timeout: 5))
        app.buttons["Start my first story"].tap()
        XCTAssertTrue(app.buttons["Scan the first page"].waitForExistence(timeout: 5))
    }

    func testGuideCanBeReplayedFromSettings() {
        let app = launch()
        app.buttons["Settings"].tap()
        let guide = app.buttons["How to use PageChime"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        guide.tap()
        XCTAssertTrue(app.staticTexts["Read any book aloud. Hear it come alive."].waitForExistence(timeout: 5))
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.buttons["Scan the first page"].waitForExistence(timeout: 5))
    }

    // MARK: - Reading

    func testReadingWithoutScanningPauseResumeAndRecap() {
        let app = launch(speech: Self.demoEnglish)
        app.buttons["Read without scanning"].tap()

        let center = app.descendants(matching: .any)["readingCenter"]
        XCTAssertTrue(center.waitForExistence(timeout: 5))
        waitFor(center, label: "Dog bark", or: "Thunder", timeout: 20)

        app.buttons["Pause"].tap()
        waitFor(center, label: "Paused", timeout: 5)
        app.buttons["Resume"].tap()
        waitFor(center, label: "Listening", or: "Last sound", timeout: 5)

        app.buttons["Stop reading"].tap()
        XCTAssertTrue(app.staticTexts["The end."].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(number(in: app.descendants(matching: .any)["recapSounds"]), 2)
        XCTAssertTrue(app.staticTexts["Dog bark"].exists)
        XCTAssertTrue(app.staticTexts["Thunder"].exists)

        app.buttons["Done for tonight"].tap()
        XCTAssertTrue(app.buttons["Scan the first page"].waitForExistence(timeout: 5))
    }

    func testScanReadNextPageAndRecap() throws {
        try requireLiveBackend()
        let app = launch(speech: Self.pageOne + " || " + Self.pageTwo, pages: [Self.pageOne, Self.pageTwo])

        // Page 1: scan, see its sounds, read it through.
        app.buttons["Scan the first page"].tap()
        let ready = app.staticTexts["soundsReady"]
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "Page 1 should analyze")
        let firstCount = number(in: ready)
        XCTAssertGreaterThanOrEqual(firstCount, 3, ready.label)
        XCTAssertTrue(app.staticTexts["Page 1"].exists)
        app.buttons["Start reading"].tap()

        let progress = app.descendants(matching: .any)["pageProgress"]
        waitFor(progress, label: "\(firstCount) of \(firstCount)", timeout: 45)
        // A parent turns the page after its last words, which follow the last cue.
        sleep(3)

        // Page 2: next page pauses, scans and resumes where the reader is.
        app.buttons["Scan the next page"].tap()
        XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "Page 2 should analyze")
        let secondCount = number(in: ready)
        app.buttons["Start reading"].tap()
        if secondCount > 0 {
            waitFor(progress, label: "\(secondCount) of \(secondCount)", timeout: 45)
        }

        app.buttons["Stop reading"].tap()
        XCTAssertTrue(app.staticTexts["The end."].waitForExistence(timeout: 5))
        XCTAssertEqual(number(in: app.descendants(matching: .any)["recapPages"]), 2)
        XCTAssertGreaterThanOrEqual(number(in: app.descendants(matching: .any)["recapSounds"]), firstCount + secondCount)

        app.buttons["Read another story"].tap()
        XCTAssertTrue(app.buttons["Scan the first page"].waitForExistence(timeout: 5))
    }

    func testChineseReading() {
        let app = launch(speech: Self.demoChinese)
        app.buttons["Reading language: English"].tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.buttons["不扫描，直接读"].waitForExistence(timeout: 5))
        app.buttons["不扫描，直接读"].tap()

        let center = app.descendants(matching: .any)["readingCenter"]
        waitFor(center, label: "Dog bark", or: "Thunder", timeout: 20)
        app.buttons["结束朗读"].tap()
        XCTAssertTrue(app.staticTexts["讲完啦。"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(number(in: app.descendants(matching: .any)["recapSounds"]), 2)
    }

    // MARK: - Helpers

    private func waitFor(_ element: XCUIElement, label first: String, or second: String? = nil, timeout: TimeInterval,
                         file: StaticString = #filePath, line: UInt = #line) {
        let format = second == nil ? "label CONTAINS %@" : "label CONTAINS %@ OR label CONTAINS %@"
        let predicate = NSPredicate(format: format, argumentArray: [first] + (second.map { [$0] } ?? []))
        let found = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
        XCTAssertTrue(found, "Expected \"\(first)\"\(second.map { " or \"\($0)\"" } ?? ""), got \"\(element.exists ? element.label : "<missing>")\"",
                      file: file, line: line)
    }

    /// The first whole number in an element's label ("5 sounds ready" → 5).
    private func number(in element: XCUIElement) -> Int {
        guard element.exists, let range = element.label.range(of: "[0-9]+", options: .regularExpression) else { return -1 }
        return Int(element.label[range]) ?? -1
    }
}
