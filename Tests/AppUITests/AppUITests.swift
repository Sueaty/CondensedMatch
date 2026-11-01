import XCTest

final class AppUITests: XCTestCase {
    @MainActor
    func testVideoImportRequiresPickerConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        for shouldConfirm in [false, true] {
            let importButton = app.buttons["Import match video"]
            XCTAssertTrue(importButton.waitForExistence(timeout: 10))
            importButton.tap()

            let video = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 15))
            let confirm = app.buttons["video-import-confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertFalse(app.staticTexts["Select up to 2 videos."].exists)

            for tapIndex in 0..<6 {
                video.tap()
                let expectedEnabled = tapIndex.isMultiple(of: 2)
                let updatedSelection = NSPredicate { _, _ in
                    confirm.exists && confirm.isEnabled == expectedEnabled
                }
                XCTAssertEqual(
                    XCTWaiter.wait(
                        for: [XCTNSPredicateExpectation(predicate: updatedSelection, object: nil)],
                        timeout: 5
                    ),
                    .completed,
                    "Tap \(tapIndex + 1) must toggle selection without dismissing the picker\n\(app.debugDescription)"
                )
                XCTAssertTrue(app.navigationBars["Select video"].exists)
                XCTAssertTrue(video.exists)
                XCTAssertFalse(app.scrollViews["editor-timeline-scroll"].exists)
            }

            video.tap()
            let otherVideo = app.images.matching(identifier: "PXGGridLayout-Info").element(boundBy: 1)
            XCTAssertTrue(otherVideo.exists)
            otherVideo.tap()
            otherVideo.tap()
            let clearedReplacement = NSPredicate { _, _ in
                confirm.exists && !confirm.isEnabled
            }
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: clearedReplacement, object: nil)],
                    timeout: 5
                ),
                .completed,
                "Selecting a different video must replace the previous selection"
            )
            app.navigationBars["Select video"].swipeDown()
            XCTAssertTrue(app.navigationBars["Select video"].exists)
            XCTAssertFalse(confirm.isEnabled)

            video.tap()

            let prematureImport = NSPredicate { _, _ in
                app.staticTexts["Bringing your match in…"].exists
                    || app.scrollViews["editor-timeline-scroll"].exists
            }
            let noImport = XCTNSPredicateExpectation(predicate: prematureImport, object: nil)
            noImport.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [noImport], timeout: 3), .completed)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Selected video waits for picker confirmation"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(confirm.isEnabled)

            if shouldConfirm {
                confirm.tap()
                XCTAssertTrue(app.scrollViews["editor-timeline-scroll"].waitForExistence(timeout: 120))
            } else {
                app.buttons["Cancel"].tap()
                XCTAssertTrue(importButton.waitForExistence(timeout: 5))
                XCTAssertTrue(importButton.isEnabled)
                XCTAssertFalse(app.staticTexts["Bringing your match in…"].exists)
                XCTAssertFalse(app.scrollViews["editor-timeline-scroll"].exists)
            }
        }
    }

    @MainActor
    func testHomePhotoPickerCancellation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Import match video"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Import match video"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Import match video"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your matches"].exists)
    }

    @MainActor
    func testLargeTypeCreateActionsRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let importVideo = app.buttons["Import match video"]
        XCTAssertTrue(importVideo.waitForExistence(timeout: 10))
        if !importVideo.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(importVideo.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Large Type home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
