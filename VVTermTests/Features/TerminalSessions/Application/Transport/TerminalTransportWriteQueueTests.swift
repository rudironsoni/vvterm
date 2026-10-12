import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct TerminalTransportWriteQueueTests {
    @Test
    @MainActor
    func preservesInputOrderWhenAnEarlierWriteSuspends() async {
        let queue = TerminalTransportWriteQueue()
        let recorder = TerminalTransportWriteRecorder()
        let gate = TerminalTransportWriteGate()
        let routeID = UUID()

        queue.enqueue(Data([1]), routeID: routeID) { _ in
            await gate.block()
            await recorder.append(1)
        }
        await gate.waitUntilBlocked()
        for value in [UInt8(2), 3] {
            queue.enqueue(Data([value]), routeID: routeID) { data in
                for byte in data { await recorder.append(Int(byte)) }
            }
        }
        await gate.release()

        await queue.waitForPendingWrites()

        let values = await recorder.values
        #expect(values == [1, 2, 3])
    }

    @Test
    @MainActor
    func cancelDropsQueuedWriteBehindCancellationIgnoringOperation() async {
        let queue = TerminalTransportWriteQueue()
        let gate = TerminalTransportWriteGate()
        let recorder = TerminalTransportWriteRecorder()
        let routeID = UUID()

        queue.enqueue(Data([1]), routeID: routeID) { _ in
            await gate.block()
            await recorder.append(1)
        }
        await gate.waitUntilBlocked()
        queue.enqueue(Data([2]), routeID: routeID) { _ in
            await recorder.append(2)
        }

        queue.cancel()
        await gate.release()
        await recorder.waitForCount(1)

        let values = await recorder.values
        #expect(values == [1])
    }

    @Test
    @MainActor
    func wheelBurstUsesOneWriteAndPreservesEveryReport() async {
        let queue = TerminalTransportWriteQueue()
        let recorder = TerminalTransportDataRecorder()
        let routeID = UUID()
        let report = Data("\u{1B}[<64;10;10M".utf8)
        var expected = Data()
        for _ in 0..<128 {
            expected.append(report)
            queue.enqueue(report, routeID: routeID) { await recorder.append($0) }
        }
        await queue.waitForPendingWrites()
        let writes = await recorder.writes
        #expect(writes.count == 1)
        #expect(writes.reduce(into: Data()) { $0.append($1) } == expected)
    }

    @Test
    @MainActor
    func wheelBurstBehindASuspendedWriteDoesNotCreateAWriteBacklog() async {
        let queue = TerminalTransportWriteQueue()
        let gate = TerminalTransportWriteGate()
        let recorder = TerminalTransportDataRecorder()
        let routeID = UUID()
        queue.enqueue(Data([0]), routeID: routeID) { data in
            await gate.block()
            await recorder.append(data)
        }
        await gate.waitUntilBlocked()
        let report = Data("\u{1B}[<64;10;10M".utf8)
        for _ in 0..<128 {
            queue.enqueue(report, routeID: routeID) { await recorder.append($0) }
        }
        await gate.release()
        await queue.waitForPendingWrites()
        let writes = await recorder.writes
        #expect(writes.count == 2)
        #expect(writes.first == Data([0]))
        #expect(writes.last?.count == report.count * 128)
    }

    @Test
    @MainActor
    func combinedWritesAreBoundedAndKeepShellsSeparate() async {
        let queue = TerminalTransportWriteQueue()
        let recorder = TerminalTransportDataRecorder()
        let firstRoute = UUID()
        let secondRoute = UUID()
        let chunk = Data(repeating: 1, count: 32 * 1024)
        for _ in 0..<3 {
            queue.enqueue(chunk, routeID: firstRoute) { await recorder.append($0) }
        }
        queue.enqueue(Data([2]), routeID: secondRoute) { await recorder.append($0) }
        await queue.waitForPendingWrites()
        let writes = await recorder.writes
        #expect(writes.map(\.count) == [64 * 1024, 32 * 1024, 1])
        #expect(writes.last == Data([2]))
    }

    @Test
    @MainActor
    func cancellationDoesNotLetAnOldWriterConsumeReplacementInput() async {
        let queue = TerminalTransportWriteQueue()
        let oldGate = TerminalTransportWriteGate()
        let newGate = TerminalTransportWriteGate()
        let recorder = TerminalTransportWriteRecorder()
        queue.enqueue(Data([1]), routeID: UUID()) { _ in
            await oldGate.block()
            await recorder.append(1)
        }
        await oldGate.waitUntilBlocked()
        queue.cancel()
        let routeID = UUID()
        queue.enqueue(Data([2]), routeID: routeID) { _ in
            await newGate.block()
            await recorder.append(2)
        }
        await newGate.waitUntilBlocked()
        await oldGate.release()
        await recorder.waitForCount(1)
        queue.enqueue(Data([3]), routeID: routeID) { _ in await recorder.append(3) }
        await newGate.release()
        await queue.waitForPendingWrites()
        let values = await recorder.values
        #expect(values == [1, 2, 3])
    }
}

private actor TerminalTransportDataRecorder {
    private(set) var writes: [Data] = []

    func append(_ data: Data) { writes.append(data) }
}

private actor TerminalTransportWriteRecorder {
    private(set) var values: [Int] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ value: Int) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.0 }
        countWaiters.removeAll { values.count >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}

private actor TerminalTransportWriteGate {
    private var blocked = false
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        let waiters = blockWaiters
        blockWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
