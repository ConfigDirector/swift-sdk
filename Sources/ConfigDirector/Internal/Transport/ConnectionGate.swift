import Foundation

/// A one-shot signal a caller waits on while a connection either opens, fails in a way retrying
/// cannot fix, or runs out of time.
final class ConnectionGate: Sendable {
    private struct State {
        var settled: Result<Void, any Error>?
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let state = Locked(State())

    /// Settles the gate, returning false when it had already settled.
    @discardableResult
    func settle(_ result: Result<Void, any Error> = .success(())) -> Bool {
        let (didSettle, continuation) = state.withLock { state -> (
            Bool,
            CheckedContinuation<Void, any Error>?
        ) in
            guard state.settled == nil else { return (false, nil) }
            state.settled = result
            defer { state.continuation = nil }
            return (true, state.continuation)
        }

        continuation?.resume(with: result)
        return didSettle
    }

    /// Waits for the gate to settle, treating `timeout` seconds passing as a success: a connection
    /// that has not opened yet may still open later.
    func wait(timeout: TimeInterval) async throws {
        let timeoutTask = Locked<Task<Void, Never>?>(nil)
        defer { timeoutTask.withLock { $0 }?.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let settled = state.withLock { state -> Result<Void, any Error>? in
                    guard let settled = state.settled else {
                        state.continuation = continuation
                        return nil
                    }
                    return settled
                }

                if let settled {
                    continuation.resume(with: settled)
                    return
                }

                timeoutTask.withLock {
                    $0 = Task { [weak self] in
                        let slept: Void? = try? await Task.sleep(
                            nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                        )
                        guard slept != nil else { return }
                        self?.settle()
                    }
                }
            }
        } onCancel: {
            takeContinuation()?.resume(throwing: CancellationError())
        }
    }

    private func takeContinuation() -> CheckedContinuation<Void, any Error>? {
        state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
    }
}
