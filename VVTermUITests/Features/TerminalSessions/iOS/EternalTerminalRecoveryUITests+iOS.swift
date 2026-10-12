#if os(iOS)
import XCTest

/// Opt in with VVTERM_ET_UI_INTEGRATION=1 and VVTERM_ET_UI_DROP_FILE.
/// The loopback fixture must seed etSSHPort, etPort, and etRecoveryStartupCommand in the
/// existing reconnect harness defaults. Its shell emits a working directory
/// named ET_UI_<shell PID>_<input count>, and its proxy watches the drop file.
final class EternalTerminalRecoveryUITests: TerminalReconnectUITestCase {
    @MainActor
    func testBackgroundDropTabSwitchAndManualReconnectPreserveRemoteShell() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VVTERM_ET_UI_INTEGRATION"] == "1", "Requires local etserver and SSH fixture")
        let dropFile = URL(fileURLWithPath: try XCTUnwrap(environment["VVTERM_ET_UI_DROP_FILE"]))
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "--vvterm-ui-test-et-recovery", "--vvterm-ui-test-tab-switch",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES", "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES", "-terminalTmuxEnabledDefault", "NO",
            "-security.privacyModeEnabled", "NO", "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        app.launch()
        defer { app.terminate() }
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45))
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        wait(for: diagnostics, containing: "/ET_UI_", timeout: 20, app: app)
        let firstShell = try shellMarker(diagnostics)

        app.buttons["vvterm.tabSwitch.1"].tap()
        let changedShell = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                diagnostics.label.contains("/ET_UI_") && !diagnostics.label.contains("/\(firstShell)_")
            }, object: diagnostics
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changedShell], timeout: 30), .completed)
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        wait(for: diagnostics, containing: "/ET_UI_", timeout: 20, app: app)
        let secondShell = try shellMarker(diagnostics)
        XCTAssertNotEqual(firstShell, secondShell)
        app.buttons["vvterm.tabSwitch.0"].tap()
        wait(for: diagnostics, containing: "/\(firstShell)_0", timeout: 10, app: app)

        for inputCount in 1...3 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(waitForBackgroundState(of: app, timeout: 8))
            try Data("drop".utf8).write(to: dropFile)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.activate()
            wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 30, app: app)
            app.buttons["vvterm.etRecoveryTest.input"].tap()
            wait(for: diagnostics, containing: "/\(firstShell)_\(inputCount)", timeout: 10, app: app)

            app.buttons["vvterm.tabSwitch.1"].tap()
            wait(for: diagnostics, containing: "/\(secondShell)_0", timeout: 15, app: app)
            app.buttons["vvterm.tabSwitch.0"].tap()
            wait(for: diagnostics, containing: "/\(firstShell)_\(inputCount)", timeout: 10, app: app)
        }

        app.buttons["vvterm.etRecoveryTest.reconnect"].tap()
        wait(for: diagnostics, containing: "setup=ready state=connected", timeout: 30, app: app)
        app.buttons["vvterm.etRecoveryTest.input"].tap()
        wait(for: diagnostics, containing: "/\(firstShell)_4", timeout: 10, app: app)
    }

    @MainActor
    private func shellMarker(_ diagnostics: XCUIElement) throws -> String {
        let directory = try XCTUnwrap(diagnosticValue("cwd", in: diagnostics))
        let name = URL(fileURLWithPath: directory).lastPathComponent
        let parts = name.split(separator: "_")
        XCTAssertEqual(parts.count, 4)
        return parts.dropLast().joined(separator: "_")
    }
}
#endif
