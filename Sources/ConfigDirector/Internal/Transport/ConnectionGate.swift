import Foundation

final class ConnectionGate: Sendable {
    private struct State {
        var settled: Result<Void, any Error>?
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let state = Locked(State())

    @discardableResult
    func settle(_ result: Result<Void, any Error> = .success(())) -> Bool {
        let (didSettle, continuation) = state.withLock { state -> (
            Bool,
            CheckedContinuation<Void, any Error>?
        ) in
            guard state.settled == nil else { return (false, nil) }
            state.settled = result
            let waiting = state.continuation
            state.continuation = nil
            return (true, waiting)
        }

        continuation?.resume(with: result)
        return didSettle
    }

    /// Waits for the gate to settle, treating `timeout` seconds passing as a success: a connection
    /// that has not opened yet may still open later.
    func wait(timeout: TimeInterval) async throws {
        let timeoutTask = Task { [weak self] in
            let slept: Void? = try? await Task.sleep(seconds: timeout)
            guard slept != nil else { return }
            self?.settle()
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let settled = state.withLock { state -> Result<Void, any Error>? in
                    if let settled = state.settled {
                        return settled
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    state.continuation = continuation
                    return nil
                }

                if let settled {
                    continuation.resume(with: settled)
                }
            }
        } onCancel: {
            takeContinuation()?.resume(throwing: CancellationError())
        }
    }

    private func takeContinuation() -> CheckedContinuation<Void, any Error>? {
        state.exchange(\.continuation, with: nil)
    }
}
