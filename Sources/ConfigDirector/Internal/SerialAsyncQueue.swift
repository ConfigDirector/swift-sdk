import Foundation

/// Runs asynchronous operations one at a time, in the order they were submitted.
///
/// ``enqueue(_:)`` returns once its own operation has finished, so a caller can wait for its work
/// while still being ordered behind everything submitted before it.
final class SerialAsyncQueue: Sendable {
    private let tail = Locked<Task<Void, Never>?>(nil)

    func enqueue(_ operation: @escaping @Sendable () async -> Void) async {
        let task = tail.withLock { currentTail -> Task<Void, Never> in
            let previous = currentTail
            let task = Task {
                await previous?.value
                await operation()
            }
            currentTail = task
            return task
        }

        await task.value
    }
}
