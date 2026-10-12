#if os(iOS)
import XCTest
import UIKit

final class TerminalScrollUITests: TerminalKeyboardUITestCase {
    @MainActor
    func testSlowDragTracksFingerWithoutOpeningKeyboard() throws {
        let app = launchKeyboardHarness(seedsTerminalScrollHistory: true)
        _ = waitForTerminal(in: app)
        waitForDiagnosticMetrics(in: app) { ($0["scrollMaximumY"] ?? 0) > 60 }
        let before = try requiredDiagnosticMetric("scrollOffsetY", in: app)
        let distance = min(80, before / 2)
        let start = try terminalTouchCoordinate(in: app)
        let end = start.withOffset(CGVector(dx: 0, dy: distance * (try terminalScreenScale(in: app))))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        waitForDiagnosticMetrics(in: app) { ($0["scrollOffsetY"] ?? before) < before - distance / 2 }
        let after = try requiredDiagnosticMetric("scrollOffsetY", in: app)
        XCTAssertEqual(before - after, distance, accuracy: 15, diagnosticsText(in: app))
        XCTAssertFalse(app.keyboards.firstMatch.exists, diagnosticsText(in: app))
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)

        try terminalTouchCoordinate(in: app).tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, diagnosticsText(in: app))
        app.buttons["vvterm.keyboardTest.showKeyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), diagnosticsText(in: app))
    }

    @MainActor
    func testFlickMovesHistoryAndCanReverseDirection() throws {
        let app = launchKeyboardHarness(seedsTerminalScrollHistory: true)
        _ = waitForTerminal(in: app)
        waitForDiagnosticMetrics(in: app) { ($0["scrollMaximumY"] ?? 0) > 60 }
        let before = try requiredDiagnosticMetric("scrollOffsetY", in: app)
        let start = try terminalTouchCoordinate(in: app)
        let scale = try terminalScreenScale(in: app)
        let end = start.withOffset(CGVector(dx: 0, dy: 180 * scale))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        waitForDiagnosticMetrics(in: app) { ($0["scrollOffsetY"] ?? before) < before }
        let older = try requiredDiagnosticMetric("scrollOffsetY", in: app)
        XCTAssertGreaterThanOrEqual(older, -1, diagnosticsText(in: app))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180 * scale)), withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForDiagnosticMetrics(in: app) { ($0["scrollOffsetY"] ?? 0) > older }
        let newer = try requiredDiagnosticMetric("scrollOffsetY", in: app)
        let maximum = try requiredDiagnosticMetric("scrollMaximumY", in: app)
        XCTAssertLessThanOrEqual(newer, maximum + 1, diagnosticsText(in: app))
        XCTAssertFalse(app.keyboards.firstMatch.exists, diagnosticsText(in: app))
    }

    @MainActor
    func testMouseWheelReachesCapturedTerminalWithoutClicking() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Mouse wheel simulation needs an iPad.")
        let app = launchKeyboardHarness(simulatesTerminalMouseCapture: true)
        _ = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "mouseCaptured=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        try terminalTouchCoordinate(in: app)
            .scroll(byDeltaX: 0, deltaY: -80)
        waitForDiagnosticMetrics(in: app) { ($0["mouseScrollReports"] ?? 0) > 0 }
        assertMouseClickCountsRemain(presses: 0, releases: 0, in: app)
    }

    @MainActor
    func testCapturedFlickTravelsFartherThanSlowDrag() throws {
        let app = launchKeyboardHarness(simulatesTerminalMouseCapture: true, seedsTerminalScrollHistory: true)
        _ = waitForTerminal(in: app)
        let diagnostics = app.staticTexts["vvterm.keyboardTest.diagnostics"]
        wait(for: diagnostics, labelContaining: "mouseCaptured=true", timeout: 5, diagnostics: diagnosticsText(in: app))
        let start = try terminalTouchCoordinate(in: app)
        let end = start.withOffset(CGVector(dx: 0, dy: 150 * (try terminalScreenScale(in: app))))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        // XCTest waits for scroll motion to finish before the next query.
        // Compare complete gestures instead of observing mid-motion input.
        let flickReports = try requiredDiagnosticMetric("mouseScrollReports", in: app)
        let dragRows = 150 / (try requiredDiagnosticMetric("linkCellHeight", in: app))
        XCTAssertGreaterThan(flickReports, dragRows + 3, diagnosticsText(in: app))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let slowReports = try requiredDiagnosticMetric("mouseScrollReports", in: app) - flickReports
        XCTAssertGreaterThan(slowReports, 0, diagnosticsText(in: app))
        XCTAssertLessThanOrEqual(slowReports, dragRows + 3, diagnosticsText(in: app))
        XCTAssertFalse(app.keyboards.firstMatch.exists, diagnosticsText(in: app))
    }

    @MainActor
    func testDoubleTapStillSelectsTextDuringMouseCapture() throws {
        let app = launchKeyboardHarness(simulatesTerminalMouseCapture: true)
        _ = waitForTerminal(in: app)
        let point = try terminalTouchCoordinate(in: app)
        point.tap()
        waitForMouseClickCounts(presses: 1, releases: 1, in: app)
        point.doubleTap()
        waitForDiagnosticMetrics(in: app) { ($0["nativeSelectionLength"] ?? 0) > 0 }
        assertMouseClickCountsRemain(presses: 1, releases: 1, in: app)
    }
}
#endif
