import XCTest
import UIKit

@MainActor
final class EditorInteractionTests: XCTestCase {
    func testExportActionsUseSevenToThreeWidthsAndBackReturnsToEditor() throws {
        let app = openEditor()
        app.buttons["Export"].tap()
        let create = app.buttons["Create condensed video"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        app.swipeUp()
        create.tap()

        let save = app.buttons["Save to Photos"]
        let share = app.buttons["Share video"]
        XCTAssertTrue(save.waitForExistence(timeout: 30))
        app.swipeUp()
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(share.isHittable)
        XCTAssertLessThan(save.frame.maxX, share.frame.minX)
        XCTAssertEqual(save.frame.midY, share.frame.midY, accuracy: 1)
        XCTAssertEqual(save.frame.height, share.frame.height, accuracy: 1)
        XCTAssertEqual(save.frame.width / share.frame.width, 7.0 / 3.0, accuracy: 0.03)

        app.buttons["export-back-to-editing"].tap()
        XCTAssertTrue(app.scrollViews["editor-timeline-scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Import match video"].exists)
    }

    func testExportBackBeforeCreatingVideoKeepsEditingSession() throws {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_NEARBY_SPLIT": "1"])
        let before = total(app)
        app.buttons["Export"].tap()
        let back = app.buttons["export-back-to-editing"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.scrollViews["editor-timeline-scroll"].waitForExistence(timeout: 5))
        waitUntilReady(app)
        XCTAssertEqual(total(app), before, accuracy: 0.001)
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
    }

    func testBackWithEditsAsksBeforeDiscarding() throws {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_NEARBY_SPLIT": "1"])
        let before = total(app)
        app.buttons["editor-back"].tap()
        let alert = app.alerts["Discard this edit?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Keep Editing"].tap()
        XCTAssertTrue(app.scrollViews["editor-timeline-scroll"].exists)
        XCTAssertEqual(total(app), before, accuracy: 0.001)

        app.buttons["editor-back"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Discard Edit"].tap()
        XCTAssertTrue(app.buttons["Import match video"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["editor-timeline-scroll"].exists)
    }

    func testPointFifteenMinimumShowsToastAndKeepsShortClipUnchanged() throws {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_SHORT_CLIP": "1"])
        app.buttons["editor-split"].tap()
        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.label.contains("0.15"))
        XCTAssertEqual(total(app), 0.29, accuracy: 0.001)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "1")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "A split below the 0.15 second minimum is explained without changing the clip"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSplitDuringPlaybackUndoKeepsTheCutPosition() throws {
        let app = openEditor()
        app.buttons["Play"].tap()
        let advanced = NSPredicate { _, _ in
            self.time(app) > 0.7
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: nil)], timeout: 5),
            .completed)
        app.buttons["editor-split"].tap()
        waitUntilReady(app)
        let cut = time(app)
        XCTAssertGreaterThan(cut, 0.7)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "2")
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(time(app), cut, accuracy: 1.0 / 30 + 0.001)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "1")
    }

    func testSubsecondSplitPreservesEarlierVisibleCutAndUndoRedo() throws {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_NEARBY_SPLIT": "1"])
        let timeline = app.scrollViews["editor-timeline-scroll"]
        let first = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@", "editor-clip-boundary-", "10.0000")
        ).firstMatch
        let second = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@", "editor-clip-boundary-", "10.9000")
        ).firstMatch
        XCTAssertEqual(time(app), 10.9, accuracy: 0.001)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        timeline.pinch(withScale: 2, velocity: 2)
        waitUntilReady(app)
        XCTAssertTrue(app.buttons["editor-split"].isEnabled)
        app.buttons["editor-split"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "3")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(first.frame.minX, timeline.frame.minX)
        XCTAssertLessThan(first.frame.maxX, second.frame.minX - 20)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Both split boundaries remain visible around the 0.9 second clip"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "2")
        XCTAssertTrue(first.exists)
        XCTAssertFalse(second.exists)
        app.buttons["Redo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "3")
        XCTAssertTrue(first.exists)
        XCTAssertTrue(second.exists)
    }

    func testRepeatedPinchesKeepFootageVisibleAndEditorResponsive() throws {
        let app = openEditor()
        let timeline = app.scrollViews["editor-timeline-scroll"]
        timeline.swipeLeft(velocity: .slow)
        waitUntilReady(app)
        let anchor = time(app)
        let duration = total(app)
        let usesColorFixture = ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SOURCE"] == nil
        let footage = NSPredicate { _, _ in
            self.footageFraction(timeline, time: anchor, duration: duration) > 0.9
        }
        if usesColorFixture {
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: footage, object: nil)], timeout: 10),
                .completed)
        }
        let magnifications: [CGFloat] = [2, 2, 2, 2, 2, 2, 0.25, 0.25, 0.25, 2, 2, 2]
        var peakScale = 0.0
        for (cycle, magnification) in magnifications.enumerated() {
            timeline.pinch(withScale: magnification, velocity: magnification > 1 ? 3 : -3)
            waitUntilReady(app)
            let scale = Double(timeline.value as? String ?? "") ?? 0
            peakScale = max(peakScale, scale)
            if cycle == 8 {
                XCTAssertLessThan(scale, peakScale / 4)
            }
            XCTAssertEqual(time(app), anchor, accuracy: 1.0 / 30 + 0.001)
            if usesColorFixture {
                XCTAssertGreaterThan(
                    footageFraction(timeline, time: anchor, duration: duration), 0.9,
                    "Pinch cycle \(cycle) replaced footage with missing thumbnails")
            }
        }
        XCTAssertGreaterThanOrEqual(peakScale, 470)
        app.buttons["Play"].tap()
        let playing = NSPredicate { _, _ in
            self.time(app) > anchor + 0.2
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 5),
            .completed)
        app.buttons["Pause"].tap()
        timeline.swipeLeft(velocity: .slow)
        waitUntilReady(app)
        app.buttons["editor-split"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "2")
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Footage retained after twelve pinch cycles and subsequent editing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func footageFraction(_ timeline: XCUIElement, time: Double, duration: Double) -> Double {
        guard let image = timeline.screenshot().image.cgImage,
            let scale = Double(timeline.value as? String ?? "")
        else {
            return 0
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else {
            return 0
        }
        var samples = 0
        var footage = 0
        let pointRatio = Double(image.width) / timeline.frame.width
        let y = Int(54 * pointRatio)
        for x in stride(from: 8, to: image.width - 8, by: 11) {
            let pointX = Double(x) / pointRatio
            let editTime = time + (pointX - timeline.frame.width / 2) / scale
            guard editTime > 0.1, editTime < duration - 0.1 else {
                continue
            }
            let offset = (y * image.width + x) * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            samples += 1
            if red > green + 40 || blue > green + 40 {
                footage += 1
            }
        }
        return samples > 0 ? Double(footage) / Double(samples) : 0
    }

    func testRepeatedScrollSplitReverseScrollAndHistoryRemainAligned() throws {
        let app = openEditor()
        let timeline = app.scrollViews["editor-timeline-scroll"]
        let split = app.buttons["editor-split"]
        let selected = app.staticTexts["editor-selected-clip"]
        for count in 2...4 {
            timeline.swipeLeft(velocity: .slow)
            waitUntilReady(app)
            let before = time(app)
            XCTAssertGreaterThan(before, 0)
            XCTAssertTrue(split.isEnabled)
            split.tap()
            waitUntilReady(app)
            XCTAssertEqual(selected.value as? String, String(count))
            XCTAssertEqual(time(app), before, accuracy: 1.0 / 30 + 0.001)
            XCTAssertTrue(split.isEnabled)
            split.tap()
            XCTAssertTrue(app.otherElements["editor-toast"].waitForExistence(timeout: 3))
            XCTAssertEqual(selected.value as? String, String(count))
            let stable = time(app)
            Thread.sleep(forTimeInterval: 0.4)
            XCTAssertEqual(time(app), stable, accuracy: 0.001)
        }
        let selection = selected.label
        timeline.swipeRight(velocity: .fast)
        timeline.swipeLeft(velocity: .fast)
        timeline.swipeRight(velocity: .slow)
        waitUntilReady(app)
        XCTAssertEqual(selected.label, selection)
        let settled = time(app)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(time(app), settled, accuracy: 0.001)
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(selected.value as? String, "3")
        app.buttons["Redo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(selected.value as? String, "4")
        app.buttons["editor-delete"].tap()
        waitUntilReady(app)
        XCTAssertEqual(selected.value as? String, "3")
        XCTAssertEqual(time(app), total(app), accuracy: 0.001)
        XCTAssertTrue(split.isEnabled)
        split.tap()
        XCTAssertTrue(app.otherElements["editor-toast"].waitForExistence(timeout: 3))
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(selected.value as? String, "4")
        XCTAssertEqual(total(app), 60, accuracy: 0.001)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Repeated scroll and split"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testUnavailableSplitShowsToastAndFormerGripAreaScrollsWithoutTrimming() throws {
        let app = openEditor()
        let timeline = app.scrollViews["editor-timeline-scroll"]
        let split = app.buttons["editor-split"]
        for identifier in ["editor-trim-start", "editor-trim-end"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists)
        }
        split.tap()
        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.label.contains("0.15"))
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "1")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        let dismissed = NSPredicate { _, _ in
            !toast.exists
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 6),
            .completed)
        let edge = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        edge.press(
            forDuration: 0.01, thenDragTo: edge.withOffset(CGVector(dx: -70, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
        waitUntilReady(app)
        XCTAssertGreaterThan(time(app), 0)
        XCTAssertEqual(total(app), 60, accuracy: 0.001)
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        XCTAssertTrue(app.buttons["Export"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Timeline without edge handles and scrolling from the former grip area"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClipLimitShowsToastAndKeepsTimelineResponsive() throws {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_CLIP_LIMIT": "1"])
        let timeline = app.scrollViews["editor-timeline-scroll"]
        app.buttons["editor-split"].tap()
        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.label.contains("150"))
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "150")
        timeline.pinch(withScale: 2, velocity: 2)
        waitUntilReady(app)
        timeline.swipeLeft(velocity: .slow)
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "150")
        XCTAssertTrue(app.buttons["Export"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "One hundred fifty clips remain responsive at the split limit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFrameLookupTimeoutShowsToastAndLeavesEditUnchanged() throws {
        let app = openEditor(environment: [
            "RALLYCUT_EDITOR_TEST_NEARBY_SPLIT": "1", "RALLYCUT_EDITOR_TEST_DELAY_FRAME": "1",
        ])
        app.buttons["editor-split"].tap()
        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.label.contains("too long"))
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "2")
        XCTAssertEqual(time(app), 10.9, accuracy: 0.001)
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "1")
    }

    func testPinchPreservesPlayheadSelectionAndEditHistory() throws {
        let app = openEditor()
        let timeline = app.scrollViews["editor-timeline-scroll"]
        timeline.swipeLeft(velocity: .slow)
        waitUntilReady(app)
        app.buttons["editor-split"].tap()
        waitUntilReady(app)
        let anchor = time(app)
        let selection = app.staticTexts["editor-selected-clip"].label
        let initialScale = Double(timeline.value as? String ?? "") ?? 0
        timeline.pinch(withScale: 2, velocity: 2)
        waitUntilReady(app)
        let expandedScale = Double(timeline.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(expandedScale, initialScale * 1.4)
        XCTAssertEqual(time(app), anchor, accuracy: 1.0 / 30 + 0.001)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].label, selection)
        timeline.pinch(withScale: 0.5, velocity: -2)
        waitUntilReady(app)
        XCTAssertLessThan(Double(timeline.value as? String ?? "") ?? 0, expandedScale * 0.8)
        XCTAssertEqual(time(app), anchor, accuracy: 1.0 / 30 + 0.001)
        XCTAssertEqual(total(app), 60, accuracy: 0.001)
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, "1")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pinch zoom anchored at playhead"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testBackgroundReturnPreservesEditingAndUndo() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_NEARBY_SPLIT": "1"])
        let before = total(app)
        let selected = app.staticTexts["editor-selected-clip"].value as? String
        XCUIDevice.shared.press(.home)
        app.activate()
        waitUntilReady(app)
        XCTAssertEqual(total(app), before, accuracy: 0.001)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, selected)
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.buttons["Undo"].tap()
        waitUntilReady(app)
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["editor-selected-clip"].value as? String, selected)
    }

    func testFindRalliesWaitsInBarWhileVideoCheckRuns() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_VIDEO_CHECK_DELAY": "4"])
        app.buttons["rally-bar-find"].tap()
        let checking = app.buttons["rally-bar-checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 2))
        XCTAssertFalse(checking.isEnabled)
        XCTAssertTrue(app.staticTexts["Checking this video…"].exists)
        XCTAssertTrue(app.buttons["Export"].isEnabled)
        attachScreenshot(app, named: "Find rallies waits in the bar while the video check runs")

        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8))
        XCTAssertTrue(toast.label.contains("coming soon"))
        XCTAssertFalse(checking.exists)
        XCTAssertTrue(app.buttons["rally-bar-find"].isEnabled)
    }

    func testRejectionAfterWaitingShowsAlertAndDisablesFindRallies() {
        let app = openEditor(environment: [
            "RALLYCUT_EDITOR_TEST_VIDEO_CHECK": "cameraTooClose",
            "RALLYCUT_EDITOR_TEST_VIDEO_CHECK_DELAY": "4",
        ])
        app.buttons["rally-bar-find"].tap()
        XCTAssertTrue(app.buttons["rally-bar-checking"].waitForExistence(timeout: 2))

        let alert = app.alerts["The camera is too close"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No free find was used'")).count > 0)
        alert.buttons["OK"].tap()

        let find = app.buttons["rally-bar-find"]
        XCTAssertTrue(find.waitForExistence(timeout: 2))
        XCTAssertFalse(find.isEnabled)
        XCTAssertTrue(app.buttons["editor-split"].isEnabled)
        attachScreenshot(app, named: "A rejected video keeps Find rallies disabled")
    }

    func testFinishedRejectionShowsFrameRateAlertImmediately() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_VIDEO_CHECK": "lowFrameRate"])
        app.buttons["rally-bar-find"].tap()
        XCTAssertFalse(app.buttons["rally-bar-checking"].exists)

        let alert = app.alerts["This video is 24 fps"]
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        attachScreenshot(app, named: "A rejected video explains why rally finding is unavailable")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["rally-bar-find"].isEnabled)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testReturningHomeDiscardsSessionAndRelaunchStartsEmpty() {
        let app = openEditor()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Import match video"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your matches"].exists)
        XCTAssertFalse(app.staticTexts["Editor regression"].exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RALLYCUT_EDITOR_TEST_SESSION")
        app.launch()
        XCTAssertTrue(app.buttons["Import match video"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.scrollViews["editor-timeline-scroll"].exists)
        XCTAssertFalse(app.staticTexts["Your matches"].exists)
    }

    private func openEditor(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RALLYCUT_EDITOR_TEST_SESSION"] = UUID().uuidString
        app.launchEnvironment["RALLYCUT_EDITOR_TEST_SOURCE"] =
            ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SOURCE"]
        app.launchEnvironment.merge(environment) { _, new in
            new
        }
        app.launch()
        XCTAssertTrue(app.scrollViews["editor-timeline-scroll"].waitForExistence(timeout: 10))
        waitUntilReady(app)
        let export = app.buttons["Export"]
        XCTAssertTrue(export.isHittable)
        XCTAssertLessThanOrEqual(export.frame.maxY, app.windows.firstMatch.frame.maxY - 15)
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitUntilReady(_ app: XCUIApplication) {
        let ready = NSPredicate { _, _ in
            app.buttons["Play"].exists && app.buttons["Play"].isEnabled
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15),
            .completed)
    }

    private func time(_ app: XCUIApplication) -> Double {
        Double(app.staticTexts["editor-playback-time"].value as? String ?? "") ?? -1
    }

    private func total(_ app: XCUIApplication) -> Double {
        Double(app.staticTexts["editor-total-duration"].value as? String ?? "") ?? -1
    }
}
