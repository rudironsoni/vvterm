#if os(iOS)
import XCTest
import UIKit

final class ServerNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNativeAttachmentPickersRestoreTerminalKeyboardAfterDismissal() throws {
        try assertNativeAttachmentPickerReturn(inputMode: "direct")
    }

    @MainActor
    func testNativeAttachmentPickersRestoreChatKeyboardAndDraftAfterDismissal() throws {
        try assertNativeAttachmentPickerReturn(inputMode: "chat")
    }

    @MainActor
    private func assertNativeAttachmentPickerReturn(inputMode: String) throws {
        let app = launchNavigationHarness(freshConnection: true, inputMode: inputMode)
        defer { app.terminate() }
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        wait(for: diagnostics, containing: "setup=ready pane=missing", app: app)
        let row = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.server.D3A03FD5-453E-43AC-8BB5-838E5D5D1990").firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "vvterm.serverList.list").firstMatch
        scrollToVisible(row, in: list, app: app)
        tapVisible(row)
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
        let editor = app.descendants(matching: .any).matching(identifier: "vvterm.composer.text").firstMatch
        if inputMode == "chat" {
            wait(for: diagnostics, containing: "keyboardVisible=true", app: app)
            XCTAssertTrue(editor.waitForExistence(timeout: 8))
            app.keys["a"].tap()
            app.keys["b"].tap()
            XCTAssertEqual(editor.value as? String, "ab")
        }
        for source in ["photos", "camera", "files", "photos"] {
            wait(for: diagnostics, containing: "keyboardVisible=true", app: app)
            app.buttons[inputMode == "chat" ? "vvterm.composer.attach" : "vvterm.keyboard.accessory.attachments"].tap()
            app.buttons["vvterm.attachments.\(source)"].tap()
            let cancel = app.buttons.matching(NSPredicate(
                format: "label == 'Cancel' OR identifier == 'DismissImagePickerButton'")).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
            cancel.tap()
            wait(for: diagnostics, containing: "keyboardVisible=true", app: app)
            // The coordinator checks native dismissal one second after a hide.
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            XCTAssertTrue(app.keyboards.firstMatch.exists, diagnostics.label)
            XCTAssertTrue(diagnostics.label.contains("keyboardVisible=true"), diagnostics.label)
            XCTAssertTrue(app.keys["a"].isHittable, diagnostics.label)
            if inputMode == "chat" { XCTAssertEqual(editor.value as? String, "ab") }
        }
    }

    @MainActor
    func testFreshConnectionKeepsToolbarPositionAndFullScreenBackground() throws {
        let app = launchNavigationHarness(freshConnection: true)
        defer { app.terminate() }
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready pane=missing", app: app)
        assertServerToolbar(in: app)
        let serverRow = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.server.D3A03FD5-453E-43AC-8BB5-838E5D5D1990")
            .firstMatch
        let list = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list").firstMatch
        scrollToVisible(serverRow, in: list, app: app)
        tapVisible(serverRow)
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
        let back = app.buttons["vvterm.terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), diagnosticText(in: app))
        let firstTop = back.frame.minY
        wait(for: diagnostics, containing: "keyboardVisible=true", app: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8), diagnosticText(in: app))
        try assertTerminalBackground(in: app, at: CGPoint(x: 2, y: keyboard.frame.minY + 2))

        back.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        assertServerToolbar(in: app)
        scrollToVisible(serverRow, in: list, app: app)
        tapVisible(serverRow)
        wait(for: diagnostics, containing: "state=connected", app: app)
        XCTAssertEqual(back.frame.minY, firstTop, accuracy: 1,
                       "First entry and reopening must use the same top inset.")
        wait(for: diagnostics, containing: "keyboardVisible=true", app: app)
        let hide = app.buttons["vvterm.keyboard.accessory.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 8))
        hide.tap()
        wait(for: diagnostics, containing: "keyboardVisible=false", app: app)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8))
        try assertTerminalBackground(in: app, at: CGPoint(x: app.frame.midX, y: app.frame.maxY - 40))
        back.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        assertServerToolbar(in: app)
    }

    @MainActor
    private func assertServerToolbar(in app: XCUIApplication) {
        for identifier in ["vvterm.sidebar.workspace", "vvterm.serverList.add", "vvterm.serverList.settings"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing \(identifier). \(app.debugDescription)")
            XCTAssertTrue(button.isHittable, "Hidden \(identifier). \(app.debugDescription)")
        }
    }

    @MainActor
    func testServerEntryShowsKeyboardAndKeepsMenuStableWithPrivacyMode() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone stack flow; iPad uses SessionsNavigationUITests")
        let app = launchNavigationHarness(privacyModeEnabled: true)
        defer { app.terminate() }
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready", app: app)
        let serverRow = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.server.D3A03FD5-453E-43AC-8BB5-838E5D5D1990")
            .firstMatch
        let list = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))

        for cycle in 0..<3 {
            scrollToVisible(serverRow, in: list, app: app)
            tapVisible(serverRow)
            let terminalTab = app.segmentedControls.buttons["terminal"]
            XCTAssertTrue(terminalTab.waitForExistence(timeout: 8), diagnosticText(in: app))
            terminalTab.tap()
            let terminal = productionTerminal(in: app)
            XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
            wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)
            // No terminal tap or Keyboard command may repair initial focus.
            wait(for: diagnostics, containing: "imeProxyFirstResponder=true", app: app)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))
            XCTAssertTrue(app.keyboards.keys["a"].isHittable, diagnosticText(in: app))
            app.buttons["vvterm.terminal.moreMenu"].tap()
            let settings = app.buttons["vvterm.terminal.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), diagnosticText(in: app))
            for _ in 0..<3 {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                XCTAssertTrue(settings.exists && settings.isHittable, diagnosticText(in: app))
            }
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            popTerminal(in: app)
            let deferReview = app.buttons["Not Now"]
            if deferReview.waitForExistence(timeout: 3) {
                deferReview.tap()
            }
            if cycle == 0 {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
                app.activate()
            }
        }
    }

    @MainActor
    func testActiveTerminalPushPopPreservesListPositionAndSession() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone stack flow; iPad uses SessionsNavigationUITests")
        let app = launchNavigationHarness()
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready", app: app)

        let serverRow = app.descendants(matching: .any)
            .matching(
                identifier: "vvterm.serverList.server.D3A03FD5-453E-43AC-8BB5-838E5D5D1990"
            )
            .firstMatch
        let activeRow = app.buttons
            .matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "vvterm.sessions.tab.")
            )
            .containing(.image, identifier: "terminal")
            .firstMatch
        let list = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list")
            .firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(serverRow.waitForExistence(timeout: 10))
        assertPostMountServerMetadataReload(
            serverRow: serverRow,
            app: app
        )
        scrollToVisible(activeRow, in: list, app: app)
        let initialRowFrame = activeRow.frame

        tapVisible(activeRow)
        let terminal = productionTerminal(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        wait(
            for: diagnostics,
            containing: "setup=ready state=connected",
            timeout: 45,
            app: app
        )
        wait(for: diagnostics, containing: "shell=true", app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", app: app)
        wait(for: diagnostics, containing: "keyboardVisible=true", app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            diagnosticText(in: app)
        )
        let terminalID = try XCTUnwrap(diagnosticValue("terminalId", in: diagnostics))
        let shellID = try XCTUnwrap(diagnosticValue("shellId", in: diagnostics))

        popTerminal(in: app)
        assertListPosition(
            initialRowFrame,
            activeRow: activeRow,
            list: list,
            app: app
        )

        tapVisible(activeRow)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        assertSession(
            terminalID: terminalID,
            shellID: shellID,
            diagnostics: diagnostics,
            app: app
        )

        let hideKeyboard = app.buttons["vvterm.keyboard.accessory.hide"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 8), diagnosticText(in: app))
        hideKeyboard.tap()
        wait(for: diagnostics, containing: "keyboardVisible=false", app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
            diagnosticText(in: app)
        )

        popTerminal(in: app)
        assertListPosition(
            initialRowFrame,
            activeRow: activeRow,
            list: list,
            app: app
        )

        tapVisible(activeRow)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        assertSession(
            terminalID: terminalID,
            shellID: shellID,
            diagnostics: diagnostics,
            app: app
        )
        wait(for: diagnostics, containing: "keyboardVisible=false", app: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists, diagnosticText(in: app))

        popTerminal(in: app)
        assertListPosition(
            initialRowFrame,
            activeRow: activeRow,
            list: list,
            app: app
        )
        measureNavigationRoundTrip(
            activeRow: activeRow,
            initialRowFrame: initialRowFrame,
            list: list,
            terminal: terminal,
            app: app
        )

        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 8)
    }

    @MainActor
    func testBackgroundReturnPreservesSessionKeyboardAndBackResponsiveness() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone stack flow; iPad uses SessionsNavigationUITests")
        let app = launchNavigationHarness()
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready", app: app)

        let activeRow = app.buttons
            .matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "vvterm.sessions.tab.")
            )
            .containing(.image, identifier: "terminal")
            .firstMatch
        let list = app.descendants(matching: .any)
            .matching(identifier: "vvterm.serverList.list")
            .firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        scrollToVisible(activeRow, in: list, app: app)
        tapVisible(activeRow)
        wait(for: diagnostics, containing: "state=connected", timeout: 45, app: app)

        let terminal = productionTerminal(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        terminal.tap()
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))

        let terminalId = try XCTUnwrap(diagnosticValue("terminalId", in: diagnostics))
        let shellId = try XCTUnwrap(diagnosticValue("shellId", in: diagnostics))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))

        wait(for: diagnostics, containing: "state=connected", timeout: 10, app: app)
        XCTAssertEqual(diagnosticValue("terminalId", in: diagnostics), terminalId)
        XCTAssertEqual(diagnosticValue("shellId", in: diagnostics), shellId)
        XCTAssertFalse(
            app.staticTexts["Reconnecting…"].exists,
            "Backgrounding unnecessarily disconnected the live terminal. \(diagnosticText(in: app))"
        )
        wait(for: diagnostics, containing: "keyboardVisible=true", timeout: 8, app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "The native software keyboard session was not preserved. \(diagnosticText(in: app))"
        )

        popTerminal(in: app)
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 8)
    }

    @MainActor
    private func launchNavigationHarness(
        privacyModeEnabled: Bool = false,
        freshConnection: Bool = false,
        inputMode: String = "direct"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "--vvterm-ui-test-server-navigation",
            "--vvterm-debug-log", "keyboard",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES",
            "-terminalTmuxEnabledDefault", "NO",
            "-terminalInputMode", inputMode,
            "-security.privacyModeEnabled", privacyModeEnabled ? "YES" : "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        if freshConnection {
            app.launchArguments += [
                "--vvterm-ui-test-fresh-server-navigation",
                "-appearanceMode", "dark",
                "-terminalUsePerAppearanceTheme", "NO",
                "-terminalThemeName", "Aizen Dark",
                "-terminalPreserveSizeForKeyboard", "NO",
            ]
        }
        app.launch()

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        if !diagnostics.waitForExistence(timeout: 5),
           app.state == .runningForeground {
            app.terminate()
            app.launch()
        }
        return app
    }

    @MainActor
    private func assertTerminalBackground(in app: XCUIApplication, at point: CGPoint) throws {
        let screenshot = app.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let x = Int(point.x * CGFloat(image.width) / app.frame.width)
        let y = Int(point.y * CGFloat(image.height) / app.frame.height)
        XCTAssertTrue((0..<image.width).contains(x) && (0..<image.height).contains(y))
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        for component in pixel.prefix(3) {
            XCTAssertEqual(Double(component), 26, accuracy: 3,
                           "The full terminal backdrop must use Aizen Dark, including keyboard gaps.")
        }
    }

    @MainActor
    private func scrollToVisible(
        _ element: XCUIElement,
        in list: XCUIElement,
        app: XCUIApplication
    ) {
        for _ in 0..<12 where !isVisible(element, in: list) {
            list.swipeUp()
        }
        XCTAssertTrue(isVisible(element, in: list), diagnosticText(in: app))
    }

    @MainActor
    private func assertPostMountServerMetadataReload(
        serverRow: XCUIElement,
        app: XCUIApplication
    ) {
        let toggle = app.buttons["vvterm.navigationTest.toggleServerMetadata"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), diagnosticText(in: app))
        toggle.tap()
        XCTAssertTrue(serverRow.waitForNonExistence(timeout: 8), diagnosticText(in: app))
        XCTAssertEqual(app.state, .runningForeground)

        toggle.tap()
        XCTAssertTrue(serverRow.waitForExistence(timeout: 8), diagnosticText(in: app))
    }

    @MainActor
    private func measureNavigationRoundTrip(
        activeRow: XCUIElement,
        initialRowFrame: CGRect,
        list: XCUIElement,
        terminal: XCUIElement,
        app: XCUIApplication
    ) {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(
            metrics: [XCTOSSignpostMetric.navigationTransitionMetric],
            options: options
        ) {
            tapVisible(activeRow)
            XCTAssertTrue(
                terminal.waitForExistence(timeout: 8),
                diagnosticText(in: app)
            )
            popTerminal(in: app)
            assertListPosition(
                initialRowFrame,
                activeRow: activeRow,
                list: list,
                app: app
            )
        }
    }

    @MainActor
    private func popTerminal(in app: XCUIApplication) {
        let back = app.buttons["vvterm.terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), diagnosticText(in: app))
        back.tap()
        XCTAssertTrue(
            app.navigationBars["Servers"].waitForExistence(timeout: 8),
            diagnosticText(in: app)
        )
    }

    @MainActor
    private func assertListPosition(
        _ expectedFrame: CGRect,
        activeRow: XCUIElement,
        list: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertTrue(
            activeRow.waitForExistence(timeout: 5) && isVisible(activeRow, in: list),
            "Active row left the visible list after pop. \(diagnosticText(in: app))"
        )
        XCTAssertEqual(
            activeRow.frame.midY,
            expectedFrame.midY,
            accuracy: 8,
            "Server-list scroll position changed during pop"
        )
    }

    @MainActor
    private func isVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && frame.intersects(container.frame)
    }

    @MainActor
    private func tapVisible(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func productionTerminal(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "vvterm.reconnectTest.terminalSurface")
            .firstMatch
    }

    @MainActor
    private func assertSession(
        terminalID: String,
        shellID: String,
        diagnostics: XCUIElement,
        app: XCUIApplication
    ) {
        wait(for: diagnostics, containing: "setup=ready state=connected", app: app)
        XCTAssertEqual(diagnosticValue("terminalId", in: diagnostics), terminalID)
        XCTAssertEqual(diagnosticValue("shellId", in: diagnostics), shellID)
    }

    @MainActor
    private func wait(
        for element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 10,
        app: XCUIApplication
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for \(expected). \(diagnosticText(in: app))"
        )
    }

    @MainActor
    private func diagnosticValue(_ key: String, in diagnostics: XCUIElement) -> String? {
        diagnostics.label
            .split(separator: " ")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    @MainActor
    private func diagnosticText(in app: XCUIApplication) -> String {
        app.staticTexts["vvterm.reconnectTest.diagnostics"].label
    }
}
#endif
