import XCTest

final class AppUITests: XCTestCase {
    @MainActor
    func testLibraryPrivacyAndPhotoPickerCancellation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Privacy and import guide"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Privacy and import guide"].tap()
        XCTAssertTrue(app.staticTexts["Your court.\nYour footage."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Import match video"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Import match video"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Record match"].exists)
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
        screenshot.name = "Large Type library"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
