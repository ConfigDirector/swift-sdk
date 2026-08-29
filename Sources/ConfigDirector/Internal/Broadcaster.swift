import Foundation

/// Fans a stream of elements out to every subscriber that asks for one.
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Locked(State())
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(256)) {
        self.bufferingPolicy = bufferingPolicy
    }

    func subscribe() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            let isFinished = state.withLock { state -> Bool in
                guard !state.isFinished else { return true }
                state.subscribers[id] = continuation
                return false
            }

            guard !isFinished else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.subscribers[id] = nil }
            }
        }
    }

    func emit(_ element: Element) {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers {
            subscriber.yield(element)
        }
    }

    func finish() {
        let subscribers = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.isFinished = true
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }
}
