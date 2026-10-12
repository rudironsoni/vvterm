#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalScrollTests {
    @Test
    func nativeScrollViewOwnsTouchMotion() async throws {
        try await withTerminal { terminal, _ in
            let scroll = terminal.terminalScrollView
            #expect(terminal.scrollRecognizer.view === terminal)
            #expect(scroll.decelerationRate == .normal)
            #expect(scroll.panGestureRecognizer === terminal.scrollRecognizer)
            #expect(scroll.panGestureRecognizer.allowedScrollTypesMask == .all)
            #expect(scroll.panGestureRecognizer.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)])
            #expect(scroll.contentInsetAdjustmentBehavior == .never)
            #expect(!scroll.delaysContentTouches)
            #expect(terminal.imeProxyTextView.next === terminal)
        }
    }

    @Test
    func historyKeepsFractionalDistanceAndChangesTheActualViewport() async throws {
        try await withTerminal { terminal, runtime in
            let output = (0..<120).map { "scroll row \($0)" }.joined(separator: "\r\n") + "\r\n"
            #expect(await terminal.receiveTerminalOutput(Data(output.utf8)))
            try await wait(runtime: runtime) { (terminal.scrollbar?.rowsBelowViewport == 0) && (terminal.scrollbar?.offset ?? 0) > 2 }
            let scroll = terminal.terminalScrollView
            let height = terminal.cellSize.height
            try #require(height > 0)
            scroll.contentOffset = .zero
            let firstPage = try viewportText(terminal)
            scroll.contentOffset.y = height * 0.49
            #expect(try viewportText(terminal) == firstPage)
            scroll.contentOffset.y = height * 1.01
            #expect(try viewportText(terminal) != firstPage)
            scroll.contentOffset.y = height * 0.9
            #expect(try viewportText(terminal) == firstPage)
            #expect(abs(scroll.contentOffset.y - height * 0.9) <= 1 / terminal.contentScaleFactor)

            let state = try #require(terminal.scrollbar)
            terminal.scrollbar = .init(total: state.total, offset: 0, len: state.len)
            scroll.synchronize()
            #expect(abs(scroll.contentOffset.y - height * 0.9) <= 1 / terminal.contentScaleFactor)
            #expect(scroll.contentSize.height == scroll.bounds.height + CGFloat(state.total - state.len) * height)
            let inputFrame = terminal.imeProxyTextView.convert(terminal.imeProxyTextView.bounds, to: terminal)
            #expect(abs(inputFrame.minY) < 0.001)
            #expect(inputFrame.size == terminal.bounds.size)
            terminal.cellSize.height = height * 2
            scroll.synchronize()
            #expect(scroll.contentOffset.y == 0)
        }
    }

    @Test
    func capturedInputRetainsSmallDeltasAndDoesNotMultiplyWheelRows() async throws {
        try await withTerminal { terminal, runtime in
            #expect(await terminal.receiveTerminalOutput(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8)))
            terminal.cellSize = CGSize(width: 10, height: 20)
            terminal.terminalScrollView.synchronize()
            var input = Data()
            terminal.writeCallback = { input.append($0) }
            let scroll = terminal.terminalScrollView
            for _ in 0..<3 { scroll.contentOffset.y -= 5 }
            runtime.appTick()
            await Task.yield()
            #expect(input.isEmpty)
            scroll.contentOffset.y -= 5
            try await wait(runtime: runtime) { !input.isEmpty }
            let report = String(decoding: input, as: UTF8.self)
            #expect(report.components(separatedBy: "\u{1B}[<64;").count - 1 == 1)
            #expect(!report.contains("\u{1B}[<65;"))
        }
    }

    @Test
    func capturedBurstGroupsReportsWaitingForTransport() async throws {
        try await withTerminal { terminal, runtime in
            #expect(await terminal.receiveTerminalOutput(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8)))
            try await wait(runtime: runtime) { terminal.surface?.mouseCaptured == true }
            let queue = TerminalTransportWriteQueue()
            defer { queue.cancel() }
            let routeID = UUID()
            let (release, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            var blocked = false
            var writes: [Data] = []
            var reports = Data()
            var callbacks = 0
            queue.enqueue(Data([0]), routeID: routeID) { data in
                blocked = true
                for await _ in release { break }
                writes.append(data)
            }
            try await wait(runtime: runtime) { blocked }
            terminal.writeCallback = { data in
                callbacks += 1
                reports.append(data)
                queue.enqueue(data, routeID: routeID) { writes.append($0) }
            }
            terminal.sendPointerPosition(CGPoint(x: 20, y: 20), mods: [])
            terminal.surface?.sendMouseScroll(.init(x: 0, y: 128, mods: .init(precision: false, momentum: .none)))
            try await wait(runtime: runtime) {
                String(decoding: reports, as: UTF8.self).components(separatedBy: "\u{1B}[<64;").count - 1 == 128
            }
            continuation.yield(())
            await queue.waitForPendingWrites()
            #expect(writes.count == 2)
            #expect(writes.last == reports)
            print("Captured wheel burst: \(callbacks) native callbacks, \(writes.count - 1) pending SSH write")
        }
    }

    @Test
    func alternateScreenWithoutMouseCaptureReceivesCursorKeys() async throws {
        try await withTerminal { terminal, runtime in
            #expect(await terminal.receiveTerminalOutput(Data("\u{1B}[?1049h\u{1B}[?1007h".utf8)))
            terminal.cellSize = CGSize(width: 10, height: 20)
            terminal.scrollbar = .init(total: 30, offset: 0, len: 30)
            terminal.terminalScrollView.synchronize()
            var input = Data()
            terminal.writeCallback = { input.append($0) }
            terminal.terminalScrollView.contentOffset.y -= 20
            try await wait(runtime: runtime) { !input.isEmpty }
            #expect(String(decoding: input, as: UTF8.self) == "\u{1B}[A")
        }
    }

    @Test
    func selectionPointerButtonsAndPausedViewsRejectScrolling() async throws {
        try await withTerminal { terminal, _ in
            let pan = terminal.scrollRecognizer
            #expect(terminal.gestureRecognizerShouldBegin(pan))
            terminal.activePointerButton = .left
            #expect(!terminal.gestureRecognizerShouldBegin(pan))
            terminal.activePointerButton = nil
            terminal.nativeSelectionLifecycle.beginInteraction(restoreTerminalInput: false)
            #expect(!terminal.gestureRecognizerShouldBegin(pan))
            terminal.nativeSelectionLifecycle.cancel()
            terminal.pauseRendering()
            #expect(!terminal.gestureRecognizerShouldBegin(pan))
            terminal.cleanup()
            #expect(terminal.terminalScrollView.delegate == nil)
            #expect(terminal.terminalScrollView.terminalOwner == nil)
        }
    }

    private func withTerminal(
        _ action: (GhosttyTerminalView, GhosttyRuntime) async throws -> Void
    ) async throws {
        let runtime = GhosttyRuntime()
        defer { runtime.cleanup() }
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            worktreePath: FileManager.default.currentDirectoryPath,
            ghosttyApp: try #require(runtime.app),
            appWrapper: runtime,
            terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot(
                profile: .defaultValue(lastWriterDeviceId: "scroll-test"),
                showsDismissKeyboardButton: true
            ),
            useCustomIO: true
        )
        defer { terminal.cleanup() }
        terminal.setTerminalInputAcquisitionAllowed(true)
        terminal.setupWriteCallback()
        terminal.isPaused = false
        terminal.layoutIfNeeded()
        try await action(terminal, runtime)
    }

    private func wait(runtime: GhosttyRuntime, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            runtime.appTick()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(condition())
    }

    private func viewportText(_ terminal: GhosttyTerminalView) throws -> String {
        let surface = try #require(terminal.surface?.unsafeCValue)
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        try #require(ghostty_surface_read_text(surface, selection, &text))
        defer { ghostty_surface_free_text(surface, &text) }
        let pointer = try #require(text.text)
        let count = try #require(Int(exactly: text.text_len))
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }
}
#endif
