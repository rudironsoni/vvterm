import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct EternalTerminalRuntimeRecoveryTests {
    private actor Session: EternalTerminalSession {
        private enum Activity { case foreground, background }

        nonisolated let output = AsyncStream<Data> { _ in }
        nonisolated let stateChanges: AsyncStream<EternalTerminalSessionState>
        private let continuation: AsyncStream<EternalTerminalSessionState>.Continuation
        private var activity = Activity.foreground
        private var operations: [String] = []
        private var checkpointFailure: (any Error)?

        init() {
            let stream = AsyncStream.makeStream(of: EternalTerminalSessionState.self)
            stateChanges = stream.stream
            continuation = stream.continuation
        }

        func connect() async throws { continuation.yield(.connected) }
        func send(_ data: Data) async throws {}
        func resize(rows: Int, cols: Int, pixelWidth: Int?, pixelHeight: Int?) async throws {
            operations.append("resize")
            if activity == .background { throw EternalTerminalSessionFailure.applicationSuspended }
        }
        func notifyNetworkPathChanged() async {
            operations.append("probe")
            if activity == .foreground { continuation.yield(.connected) }
        }
        func persistCheckpoint(ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool) async throws {}
        func prepareForApplicationBackground(
            ifCurrentOwner: @MainActor @Sendable @escaping () -> Bool
        ) async throws {
            activity = .background
            operations.append("checkpoint")
            if let checkpointFailure { throw checkpointFailure }
        }
        func resumeFromApplicationBackground() async {
            operations.append("resume")
            activity = .foreground
        }
        func preparedStartupPlan() async -> TerminalShellStartupPlan { .plainShell }
        func withBootstrapSSHClient<Result: Sendable>(
            _ operation: @Sendable (SSHClient) async throws -> Result
        ) async throws -> Result { try await operation(SSHClient.testing()) }
        func close() async { operations.append("close") }
        func emit(_ state: EternalTerminalSessionState) { continuation.yield(state) }
        func recordedOperations() -> [String] { operations }
        func failCheckpoint(_ failure: any Error) { checkpointFailure = failure }
    }

    private struct Killer: EternalTerminalRemoteSessionKilling {
        func killSession(_ identifier: RemoteSessionIdentifier, using client: SSHClient) async {}
    }

    @MainActor
    private final class Preparer: EternalTerminalSessionPreparing {
        let session = Session()
        var discardedPaneIDs: [UUID] = []

        func prepareSession(
            request: EternalTerminalSessionRequest,
            startupPlanProvider: @Sendable @escaping (SSHClient) async throws -> TerminalShellStartupPlan,
            isCurrentOwner: @MainActor @Sendable @escaping () -> Bool
        ) async throws -> PreparedEternalTerminalSession {
            .init(session: session, origin: .bootstrapped)
        }
        func discardResumeState(for paneId: UUID) throws { discardedPaneIDs.append(paneId) }
    }

    @MainActor
    private final class Fixture {
        let preparer = Preparer()
        var states: [ConnectionState] = []
        var events: [EternalTerminalRuntimeEvent] = []
        var runtime: EternalTerminalRuntime!

        init() {
            let server = Server(workspaceId: UUID(), name: "ET recovery", host: "example.invalid", username: "test")
            runtime = EternalTerminalRuntime(
                paneId: UUID(), server: server, credentials: ServerCredentials(serverId: server.id),
                ownerAccess: .init(
                    isCurrent: { [weak self] _, token in self?.runtime?.identityToken == token },
                    startupPlan: { _, _, _, _ in .plainShell },
                    resumeContext: { _ in nil }, setResumeContext: { _, _ in },
                    startupActionReplayPending: { _ in false }, setStartupActionReplayPending: { _, _ in },
                    remoteSessionAttached: { _ in },
                    updateConnectionState: { [weak self] _, state in self?.states.append(state) },
                    markEternalTerminalTransport: { _ in }, handleShellEnd: { _, _, _ in },
                    unregister: { _, _ in }
                ),
                dependencies: .init(
                    recordEvent: { [weak self] in self?.events.append($0) },
                    remoteSessionKiller: Killer(), sessionPreparer: preparer
                )
            )
            runtime.resize(cols: 80, rows: 24, pixelSize: nil)
        }

        func start() async {
            runtime.startIfNeeded()
            #expect(await wait { self.states.last == .connected && !self.runtime.isStartInFlight })
        }

        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<2_000 {
                if condition() { return true }
                await Task.yield()
            }
            return condition()
        }
    }

    @Test
    func pausedRecoveredConnectionDoesNotFailOrDeleteResumeState() async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.runtime.prepareForApplicationBackground()
        await fixture.preparer.session.emit(.reconnecting)
        await fixture.preparer.session.emit(.connected)
        for _ in 0..<200 { await Task.yield() }

        #expect(!fixture.events.contains { if case .connectionFailed = $0 { return true }; return false })
        #expect(!fixture.states.contains { if case .failed = $0 { return true }; return false })
        #expect(fixture.preparer.discardedPaneIDs.isEmpty)
        await fixture.runtime.close()
    }

    @Test
    func foregroundResumesWritesBeforeVerifyingTheSameConnection() async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.runtime.prepareForApplicationBackground()
        await fixture.preparer.session.emit(.reconnecting)
        #expect(await fixture.wait { fixture.states.last == .reconnecting(attempt: 1) })
        await fixture.runtime.resumeFromApplicationBackground()

        #expect(await fixture.wait { fixture.states.last == .connected })
        let operations = await fixture.preparer.session.recordedOperations()
        #expect(operations.contains("probe"))
        if let resume = operations.firstIndex(of: "resume"), let probe = operations.firstIndex(of: "probe") {
            #expect(resume < probe)
        }
        #expect(!operations.contains("close"))
        #expect(fixture.preparer.discardedPaneIDs.isEmpty)
        await fixture.runtime.close()
    }

    @Test
    func localClosedErrorDoesNotInvalidateRemoteCredentials() async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.preparer.session.emit(.failed(.connectionClosed))
        #expect(await fixture.wait { fixture.events.contains(.connectionFailed(reason: "lifecycle")) })
        #expect(fixture.preparer.discardedPaneIDs.isEmpty)
        await fixture.runtime.close()
    }

    @Test
    func replacementSavesCurrentProtocolStateBeforeClosing() async throws {
        let fixture = Fixture()
        await fixture.start()
        try await fixture.runtime.prepareForReconnect()
        fixture.runtime.abortConnection()
        #expect(await fixture.wait { !fixture.runtime.isStartInFlight })
        for _ in 0..<20 { await Task.yield() }

        let operations = await fixture.preparer.session.recordedOperations()
        let checkpoint = try #require(operations.firstIndex(of: "checkpoint"))
        let close = try #require(operations.firstIndex(of: "close"))
        #expect(checkpoint < close)
        #expect(fixture.preparer.discardedPaneIDs.isEmpty)
    }

    @Test
    func cancelledPreparationResumesTheOriginalSession() async {
        let fixture = Fixture()
        await fixture.start()
        await fixture.preparer.session.failCheckpoint(CancellationError())
        do {
            try await fixture.runtime.prepareForReconnect()
            Issue.record("Expected preparation to be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
        let operations = await fixture.preparer.session.recordedOperations()
        #expect(operations.suffix(2) == ["checkpoint", "resume"])
        #expect(!operations.contains("close"))
        await fixture.runtime.close()
    }

    @Test
    func checkpointSaveFailureKeepsTheOriginalSessionOpen() async {
        let fixture = Fixture()
        await fixture.start()
        let failure = EternalTerminalSessionFailure.resumeState(
            message: "Test checkpoint write failed", discardStoredState: false
        )
        await fixture.preparer.session.failCheckpoint(failure)
        do {
            try await fixture.runtime.prepareForReconnect()
            Issue.record("Expected checkpoint save to fail")
        } catch {
            #expect(error as? EternalTerminalSessionFailure == failure)
        }

        let operations = await fixture.preparer.session.recordedOperations()
        #expect(!operations.contains("close"))
        #expect(operations.suffix(2) == ["checkpoint", "resume"])
        #expect(fixture.preparer.discardedPaneIDs.isEmpty)
        await fixture.runtime.close()
    }
}
