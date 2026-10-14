#if os(iOS)
import XCTest

final class TerminalAttachmentPresentationUITests: TerminalReconnectUITestCase {
    @MainActor
    func testPhotosFromTerminalAccessoryLoadsAndDismisses() {
        let (app, _) = launchProductionSSHTestHarness(repeatsKeyboardStateUpdates: true, serverNavigation: true)
        defer { app.terminate() }
        productionTerminal(in: app).tap()
        verifyPhotosPresentation(in: app, attachmentButton: "vvterm.keyboard.accessory.attachments")
    }

    @MainActor
    func testPhotosFromChatLoadsAndDismissesWithoutLosingDraft() {
        let (app, _) = launchProductionSSHTestHarness(chatMode: true, repeatsKeyboardStateUpdates: true,
                                                     serverNavigation: true)
        defer { app.terminate() }
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        app.keys["a"].tap()
        verifyPhotosPresentation(in: app, attachmentButton: "vvterm.composer.attach")
        XCTAssertEqual(editor.value as? String, "a")
    }

    @MainActor
    private func verifyPhotosPresentation(in app: XCUIApplication, attachmentButton: String) {
        // Keep publishing keyboard state while the production route presents
        // Photos. These parent updates must not replace the native picker.
        for _ in 0..<2 {
            let attachments = app.buttons[attachmentButton]
            XCTAssertTrue(attachments.waitForExistence(timeout: 8), app.debugDescription)
            attachments.tap()
            app.buttons["vvterm.attachments.photos"].tap()
            let photos = app.navigationBars["Photos"]
            XCTAssertTrue(photos.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(app.scrollViews["photosView_content_scroll_view"].exists, app.debugDescription)
            let cancel = photos.buttons["Cancel"]
            XCTAssertTrue(cancel.exists, app.debugDescription)
            cancel.tap()
            XCTAssertTrue(photos.waitForNonExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        }
    }
}
#endif
