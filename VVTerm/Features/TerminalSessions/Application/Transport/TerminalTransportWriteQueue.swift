import Foundation

/// Preserves terminal input order and combines pending bytes for the same shell.
@MainActor
final class TerminalTransportWriteQueue {
    private struct PendingWrite {
        let routeID: UUID
        var data: Data
        let operation: @MainActor @Sendable (Data) async -> Void
    }

    private var pendingWrites: [PendingWrite] = []
    private var writerTask: Task<Void, Never>?

    func enqueue(
        _ data: Data,
        routeID: UUID,
        operation: @escaping @MainActor @Sendable (Data) async -> Void
    ) {
        guard !data.isEmpty else { return }
        // Limit combined writes to 64 KiB. Larger existing input (such as a
        // paste) stays in its own write. Subtraction avoids count overflow.
        let maximumCombinedBytes = 64 * 1024
        if let last = pendingWrites.indices.last,
           pendingWrites[last].routeID == routeID,
           data.count <= maximumCombinedBytes,
           pendingWrites[last].data.count <= maximumCombinedBytes - data.count {
            pendingWrites[last].data.append(data)
        } else {
            pendingWrites.append(PendingWrite(routeID: routeID, data: data, operation: operation))
        }
        guard writerTask == nil else { return }
        writerTask = Task(priority: .userInitiated) { [weak self] in
            await self?.drain()
        }
    }

    func cancel() {
        writerTask?.cancel()
        writerTask = nil
        pendingWrites.removeAll()
    }

    func waitForPendingWrites() async {
        await writerTask?.value
    }

    private func drain() async {
        while !Task.isCancelled, !pendingWrites.isEmpty {
            let write = pendingWrites.removeFirst()
            await write.operation(write.data)
        }
        // A cancelled writer can finish after a replacement has started.
        if !Task.isCancelled { writerTask = nil }
    }
}
