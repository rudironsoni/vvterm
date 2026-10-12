#if os(iOS)
import XCTest

/// Requires the loopback SSH credentials used by TerminalReconnectUITestHarness.
/// Its PTY fixture must set OSC 0 to `INPUT_<accumulated text>` after every
/// received character. This verifies the destination without a Return event.
final class TerminalSplitPaneFocusUITests: TerminalReconnectUITestCase {
    @MainActor
    func testCommandOptionArrowTransfersInputToSelectedSSHPane() throws {
        let (app, diagnostics) = launchProductionSSHTestHarness(splitPaneFocus: true)
        defer { app.terminate() }
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 5, app: app)
        let topPane = try XCTUnwrap(diagnosticValue("focusedPaneId", in: diagnostics))
        app.typeKey("a", modifierFlags: [])
        wait(for: diagnostics, containing: "title=INPUT_a", timeout: 8, app: app)
        app.buttons["vvterm.splitFocusTest.create"].tap()
        _ = try XCTUnwrap(waitForChangedDiagnosticValue(
            "focusedPaneId", previousValue: topPane, in: diagnostics, timeout: 8, app: app
        ))
        wait(for: diagnostics, containing: "state=connected", timeout: 8, app: app)
        wait(for: diagnostics, containing: "shell=true", timeout: 8, app: app)
        app.typeKey("b", modifierFlags: [])
        wait(for: diagnostics, containing: "title=INPUT_b", timeout: 8, app: app)
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.command, .option])
        wait(for: diagnostics, containing: "focusedPaneId=\(topPane)", timeout: 8, app: app)
        wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 5, app: app)
        wait(for: diagnostics, containing: "acceptsInput=true", timeout: 5, app: app)
        app.typeKey("c", modifierFlags: [])
        wait(for: diagnostics, containing: "title=INPUT_ac", timeout: 8, app: app)
        var topInput = "ac"
        var bottomInput = "b"

        for index in 0..<3 {
            app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [.command, .option])
            _ = try XCTUnwrap(waitForChangedDiagnosticValue(
                "focusedPaneId", previousValue: topPane, in: diagnostics, timeout: 8, app: app
            ))
            wait(for: diagnostics, containing: "state=connected", timeout: 8, app: app)
            wait(for: diagnostics, containing: "shell=true", timeout: 8, app: app)
            wait(for: diagnostics, containing: "inputAllowed=true", timeout: 5, app: app)
            wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 5, app: app)
            wait(for: diagnostics, containing: "acceptsInput=true", timeout: 5, app: app)
            let bottomText = "bottom\(index)"
            for key in bottomText {
                app.typeKey(String(key), modifierFlags: [])
            }
            bottomInput += bottomText
            wait(for: diagnostics, containing: "title=INPUT_\(bottomInput)", timeout: 8, app: app)

            app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [.command, .option])
            wait(for: diagnostics, containing: "focusedPaneId=\(topPane)", timeout: 8, app: app)
            wait(for: diagnostics, containing: "inputAllowed=true", timeout: 5, app: app)
            wait(for: diagnostics, containing: "imeProxyFirstResponder=true", timeout: 5, app: app)
            let topText = "top\(index)"
            for key in topText {
                app.typeKey(String(key), modifierFlags: [])
            }
            topInput += topText
            wait(for: diagnostics, containing: "title=INPUT_\(topInput)", timeout: 8, app: app)
        }
    }
}
#endif
