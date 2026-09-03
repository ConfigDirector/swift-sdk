@testable import ConfigDirector
import Foundation
import Testing

struct ConnectionGateTests {
    @Test func releasesACallerThatWaitsAfterTheGateHasSettled() async {
        let gate = ConnectionGate()
        gate.settle()

        let released = await withTimeout { await (try? gate.wait(timeout: 5)) != nil } ?? false

        #expect(released, "a gate that settled before the wait never released the caller")
    }

    @Test func throwsTheFailureItSettledWith() async {
        let gate = ConnectionGate()
        let waiting = Task { try await gate.wait(timeout: 5) }
        await settle(0.05)

        gate.settle(.failure(ConfigDirectorError.connectionFailed(message: "rejected", statusCode: 401)))

        let result = await withTimeout { await waiting.result }
        #expect(throws: ConfigDirectorError.connectionFailed(message: "rejected", statusCode: 401)) {
            try result?.get()
        }
    }

    @Test func settlesOnlyOnce() async {
        let gate = ConnectionGate()

        #expect(gate.settle())
        #expect(!gate.settle(.failure(ConfigDirectorError.missingClientSDKKey)))

        let released = await withTimeout { await (try? gate.wait(timeout: 5)) != nil } ?? false
        #expect(released, "the gate settled again with a failure")
    }

    @Test func treatsRunningOutOfTimeAsASuccess() async throws {
        let gate = ConnectionGate()

        let startedAt = Date()
        try await gate.wait(timeout: 0.1)

        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test func throwsAtOnceWhenTheCallerWasCancelledBeforeWaiting() async {
        let gate = ConnectionGate()
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.wait(timeout: 5)
        }

        let result = await withTimeout { await waiting.result }

        #expect(throws: CancellationError.self) { try result?.get() }
    }

    @Test func releasesTheCallerWhenTheWaitIsCancelled() async {
        let gate = ConnectionGate()
        let waiting = Task { try await gate.wait(timeout: 60) }
        await settle(0.05)

        waiting.cancel()

        let result = await withTimeout { await waiting.result }
        #expect(throws: CancellationError.self) { try result?.get() }
    }
}
