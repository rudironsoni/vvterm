#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalHardwareKeyboardTests {
    @Test
    func attachmentEventsOverrideStaleSystemProbesBeforeTheFirstKey() throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: try #require(runtime.app),
            appWrapper: runtime,
            paneId: "hardware-attachment-test",
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "hardware-attachment-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        defer { terminal.cleanup() }
        terminal.keyboardUITestSetHardwareKeyboardAttached(false)
        #expect(!terminal.shouldHideKeyboardAccessoryBar)
        terminal.keyboardUITestHardwareKeyboardOverride = nil

        terminal.updateHardwareKeyboardState(attached: true, reloadInputViewsIfNeeded: false)
        #expect(terminal.isHardwareKeyboardAttached)
        #expect(terminal.shouldHideKeyboardAccessoryBar)
        #expect(terminal.hardwareKeyboardAttachment.resolveSystemAttachment(false))
        terminal.refreshHardwareKeyboardAttachmentFromSystem()
        #expect(terminal.isHardwareKeyboardAttached)

        terminal.updateHardwareKeyboardState(attached: false, reloadInputViewsIfNeeded: false)
        #expect(!terminal.isHardwareKeyboardAttached)
        #expect(!terminal.shouldHideKeyboardAccessoryBar)
        #expect(!terminal.hardwareKeyboardAttachment.resolveSystemAttachment(true))
        terminal.refreshHardwareKeyboardAttachmentFromSystem()
        #expect(!terminal.isHardwareKeyboardAttached)

        terminal.keyboardUITestHardwareKeyboardOverride = nil
        terminal.markHardwareKeyboardDetectedFromKeyPress()
        #expect(terminal.isHardwareKeyboardAttached)
        terminal.keyboardUITestHardwareKeyboardOverride = false
        terminal.refreshHardwareKeyboardAttachmentFromSystem()
        #expect(!terminal.isHardwareKeyboardAttached)
    }
}
#endif
