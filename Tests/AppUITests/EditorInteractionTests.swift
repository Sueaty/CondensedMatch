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

    func testRallyBarShowsTwoFreeFindsOnTwoLines() {
        let app = openEditor()
        // The bar's own frame also covers its border glow, so measure the gap it fills
        // between the clip row and Export (12 pt spacing on each side).
        let gap = app.buttons["Export"].frame.minY - app.buttons["editor-split"].frame.maxY
        XCTAssertEqual(gap - 24, 54, accuracy: 1)
        XCTAssertEqual(app.otherElements["rally-bar-subtitle"].label, "2 free finds left today")
        XCTAssertTrue(app.buttons["rally-bar-find"].isEnabled)
    }

    func testRallyBarShowsLastFreeFind() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_FREE_FINDS_USED": "1"])
        XCTAssertEqual(app.otherElements["rally-bar-subtitle"].label, "1 free find left today")
        XCTAssertTrue(app.buttons["rally-bar-find"].isEnabled)
        attachScreenshot(app, named: "The last free find of the day is shown in amber")
    }

    func testNoFreeFindsReplacesFindRalliesWithGoPro() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_FREE_FINDS_USED": "2"])
        XCTAssertTrue(app.staticTexts["Free finds refill tomorrow"].exists)
        XCTAssertEqual(app.otherElements["rally-bar-subtitle"].label, "Or go unlimited with Pro")
        XCTAssertFalse(app.buttons["rally-bar-find"].exists)
        attachScreenshot(app, named: "With no free finds left, Go Pro replaces Find rallies")

        app.buttons["rally-bar-go-pro"].tap()
        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.label.contains("Pro"))
    }

    func testFindRalliesShowsProgressThenPutsRalliesOnTimeline() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_RALLY_SCAN_SECONDS": "5"])
        XCTAssertEqual(total(app), 60, accuracy: 0.01)
        app.buttons["rally-bar-find"].tap()

        XCTAssertTrue(app.navigationBars["Finding rallies"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Scanning the match"].exists)
        let foundSome = NSPredicate { _, _ in
            Int(app.staticTexts["rally-finding-count"].label) ?? 0 >= 2
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: foundSome, object: nil)], timeout: 5),
            .completed)
        XCTAssertTrue(app.staticTexts["Just found"].exists)
        attachScreenshot(app, named: "2B shows rallies found so far while scanning")

        XCTAssertTrue(app.buttons["rally-row-1"].waitForExistence(timeout: 10))
        waitUntilReady(app)
        // Three confident rallies with 0.5 s before and 0.3 s after each; the short one is left out.
        XCTAssertEqual(total(app), 7.8 + 4.8 + 10.8, accuracy: 0.01)
        XCTAssertTrue(app.staticTexts["CHECK THESE"].exists)
        XCTAssertTrue(app.staticTexts["RALLIES"].exists)
        XCTAssertEqual(app.buttons["rally-check-3"].value as? String, "Left out")
        XCTAssertEqual(app.buttons["rally-check-1"].value as? String, "Included")
        XCTAssertFalse(app.scrollViews["editor-timeline-scroll"].exists)
        XCTAssertFalse(app.otherElements["rally-bar"].exists)
        XCTAssertTrue(app.buttons["editor-export"].label.hasPrefix("Export 3 rallies"))
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        attachScreenshot(app, named: "Found rallies are listed in place of the timeline")
    }

    func testRallyListCheckTrimRemoveAndUndo() {
        let app = openRallyList()
        let base = 7.8 + 4.8 + 10.8

        app.buttons["rally-check-3"].tap()
        waitForTotal(app, base + 2.3)
        XCTAssertTrue(app.buttons["editor-export"].label.hasPrefix("Export 4 rallies"))
        app.buttons["Undo"].tap()
        waitForTotal(app, base)
        app.buttons["Redo"].tap()
        waitForTotal(app, base + 2.3)

        // An expanded rally plays on its own; the edit's time and play button step aside.
        app.buttons["rally-row-4"].tap()
        let play = app.buttons["rally-preview-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Play"].exists)
        let elapsed = app.staticTexts["rally-preview-time"]
        XCTAssertEqual(elapsed.label, "0:00.0 / 0:10.8")
        play.tap()
        let played = NSPredicate { _, _ in
            !elapsed.label.hasPrefix("0:00.0")
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: played, object: nil)], timeout: 5),
            .completed, "Rally preview stayed at \(elapsed.label)")
        app.buttons["Pause rally"].tap()
        app.buttons["rally-row-4"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))

        // Dragging the end handle lengthens the rally.
        app.buttons["rally-row-1"].tap()
        let endHandle = app.descendants(matching: .any)["Rally end"].firstMatch
        XCTAssertTrue(endHandle.waitForExistence(timeout: 3))
        let grab = endHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.2, thenDragTo: grab.withOffset(CGVector(dx: 40, dy: 0)))
        let lengthened = NSPredicate { _, _ in
            self.total(app) > base + 2.3 + 0.5
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: lengthened, object: nil)], timeout: 5),
            .completed, "Total stayed at \(total(app))")
        XCTAssertEqual(app.staticTexts["rally-trim-was"].label, "was 0:07.8")
        attachScreenshot(app, named: "An expanded rally trims by dragging its handles")
        app.buttons["rally-trim-reset"].tap()
        waitForTotal(app, base + 2.3)

        app.buttons["rally-not-a-rally"].tap()
        waitForTotal(app, base + 2.3 - 7.8)
        XCTAssertFalse(app.buttons["rally-row-1"].exists)
        app.buttons["Undo"].tap()
        waitForTotal(app, base + 2.3)
        XCTAssertTrue(app.buttons["rally-row-1"].exists)

        app.buttons["editor-back"].tap()
        XCTAssertTrue(app.alerts["Discard this edit?"].waitForExistence(timeout: 3))
    }

    func testAddingAMissedRallyPutsItInTheList() {
        let app = openRallyList()
        let base = 7.8 + 4.8 + 10.8

        app.buttons["rally-add-missed"].tap()
        XCTAssertTrue(app.otherElements["rally-add-panel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Play"].exists)
        XCTAssertFalse(app.buttons["rally-add-end"].exists)

        // The 60 s fixture fits in the four-minute strip, so x maps straight to seconds.
        let strip = app.descendants(matching: .any)["rally-add-strip"].firstMatch
        strip.coordinate(withNormalizedOffset: CGVector(dx: 15.0 / 60, dy: 0.5)).tap()
        app.buttons["rally-add-start"].tap()
        let end = app.buttons["rally-add-end"]
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        XCTAssertFalse(end.isEnabled)

        strip.coordinate(withNormalizedOffset: CGVector(dx: 18.0 / 60, dy: 0.5)).tap()
        XCTAssertTrue(end.isEnabled)
        attachScreenshot(app, named: "Marking a missed rally on the source strip")
        end.tap()

        let lengthened = NSPredicate { _, _ in
            abs(self.total(app) - (base + 3)) < 0.2
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: lengthened, object: nil)], timeout: 5),
            .completed, "Total is \(total(app))")
        XCTAssertFalse(app.otherElements["rally-add-panel"].exists)
        XCTAssertTrue(app.staticTexts["Added rally"].exists)
        XCTAssertTrue(app.buttons["rally-preview-play"].exists)
        XCTAssertTrue(app.buttons["editor-export"].label.hasPrefix("Export 4 rallies"))

        app.buttons["Undo"].tap()
        waitForTotal(app, base)
        XCTAssertFalse(app.staticTexts["Added rally"].exists)
    }

    func testCancellingAddKeepsTheList() {
        let app = openRallyList()
        app.buttons["rally-add-missed"].tap()
        XCTAssertTrue(app.otherElements["rally-add-panel"].waitForExistence(timeout: 3))
        app.buttons["rally-add-start"].tap()
        app.buttons["rally-add-cancel"].tap()
        XCTAssertTrue(app.buttons["rally-row-1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertEqual(total(app), 7.8 + 4.8 + 10.8, accuracy: 0.01)
    }

    func testRallyExportOptionsMakeVideoAndClips() {
        let app = openRallyList()
        app.buttons["editor-export"].tap()
        XCTAssertTrue(app.staticTexts["3 RALLIES · 1 SKIPPED"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Every point.\nNone of the waiting."].exists)
        XCTAssertTrue(app.buttons["export-padding-1s"].isSelected)
        XCTAssertFalse(app.staticTexts["Source resolution"].exists)
        let numbers = app.descendants(matching: .any)["export-rally-number"]
        let eachRally = app.descendants(matching: .any)["export-each-rally"]
        XCTAssertEqual(numbers.value as? String, "Off")
        XCTAssertEqual(eachRally.value as? String, "Off")
        attachScreenshot(app, named: "Rally export options")

        app.buttons["export-padding-2s"].tap()
        XCTAssertTrue(app.buttons["export-padding-2s"].isSelected)
        numbers.tap()
        eachRally.tap()
        XCTAssertEqual(numbers.value as? String, "On")
        XCTAssertEqual(eachRally.value as? String, "On")
        XCTAssertTrue(app.staticTexts["3 separate clips for sharing"].exists)

        app.swipeUp()
        app.buttons["Create condensed video"].tap()
        let save = app.buttons["Save to Photos"]
        XCTAssertTrue(save.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Ready for\nanother watch."].exists)
        attachScreenshot(app, named: "Rally export finished")

        // Changing an option after exporting asks for a new video.
        app.swipeDown()
        app.buttons["export-padding-none"].tap()
        XCTAssertTrue(app.buttons["Create condensed video"].waitForExistence(timeout: 3))
        XCTAssertFalse(save.exists)
    }

    func testFramingNoteBannerCanBeDismissed() {
        let app = openRallyList(environment: ["RALLYCUT_EDITOR_TEST_RALLY_NOTES": "1"])
        let banner = app.otherElements["rally-note"]
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The near player was often out of frame, so a few rallies may be missing or cut short."].exists)
        attachScreenshot(app, named: "A framing note sits above the rally list")
        app.buttons["rally-note-dismiss"].tap()
        XCTAssertFalse(banner.waitForExistence(timeout: 1))
    }

    func testStoppingFindKeepsTimelineAndFreeFind() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_RALLY_SCAN_SECONDS": "30"])
        app.buttons["rally-bar-find"].tap()
        let cancel = app.buttons["rally-finding-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))

        cancel.tap()
        let alert = app.alerts["Stop finding rallies?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Keep Finding"].tap()
        XCTAssertTrue(app.navigationBars["Finding rallies"].exists)

        cancel.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Stop"].tap()
        XCTAssertTrue(app.otherElements["rally-bar-subtitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements["rally-bar-subtitle"].label, "2 free finds left today")
        XCTAssertEqual(total(app), 60, accuracy: 0.01)
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
    }

    func testFindingNoRalliesKeepsTimeline() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_RALLIES": "none"])
        app.buttons["rally-bar-find"].tap()
        let toast = app.otherElements["editor-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.contains("No rallies"))
        XCTAssertEqual(total(app), 60, accuracy: 0.01)
        XCTAssertEqual(app.otherElements["rally-bar-subtitle"].label, "2 free finds left today")
    }

    func testFindRalliesWaitsInBarWhileVideoCheckRuns() {
        let app = openEditor(environment: ["RALLYCUT_EDITOR_TEST_VIDEO_CHECK_DELAY": "4"])
        app.buttons["rally-bar-find"].tap()
        let checking = app.buttons["rally-bar-checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 2))
        XCTAssertFalse(checking.isEnabled)
        XCTAssertTrue(app.staticTexts["Checking this video…"].exists)
        XCTAssertEqual(app.otherElements["rally-bar-subtitle"].label, "Rally finding starts right after")
        XCTAssertTrue(app.buttons["Export"].isEnabled)
        attachScreenshot(app, named: "Find rallies waits in the bar while the video check runs")

        // Once the check passes, the search starts on its own.
        XCTAssertTrue(app.navigationBars["Finding rallies"].waitForExistence(timeout: 8))
        XCTAssertFalse(checking.exists)
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

    private func openRallyList(environment: [String: String] = [:]) -> XCUIApplication {
        let app = openEditor(environment: environment.merging(["RALLYCUT_EDITOR_TEST_RALLY_SCAN_SECONDS": "0.5"]) { old, _ in
            old
        })
        app.buttons["rally-bar-find"].tap()
        XCTAssertTrue(app.buttons["rally-row-1"].waitForExistence(timeout: 10))
        waitUntilReady(app)
        return app
    }

    private func waitForTotal(_ app: XCUIApplication, _ expected: Double) {
        let matches = NSPredicate { _, _ in
            abs(self.total(app) - expected) < 0.01
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Total \(total(app)) did not become \(expected)")
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
