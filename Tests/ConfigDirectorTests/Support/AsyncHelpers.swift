import Foundation

func withTimeout<Value: Sendable>(
    _ seconds: TimeInterval = 2,
    operation: @escaping @Sendable () async -> Value
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next().flatMap(\.self)
        group.cancelAll()
        return result
    }
}

/// Reads an `AsyncStream` one element at a time, giving up rather than hanging the test run.
final class StreamReader<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncStream<Element>.AsyncIterator

    init(_ stream: AsyncStream<Element>) {
        iterator = stream.makeAsyncIterator()
    }

    func next(timeout: TimeInterval = 2) async -> Element? {
        await withTimeout(timeout) { [self] in await iterator.next() }.flatMap(\.self)
    }

    func next(
        timeout: TimeInterval = 2,
        where matches: @escaping @Sendable (Element) -> Bool
    ) async -> Element? {
        while let element = await next(timeout: timeout) {
            if matches(element) {
                return element
            }
        }
        return nil
    }
}

extension AsyncStream where Element: Sendable {
    /// Collects every element the stream yields until it finishes.
    func collectUntilFinished() -> Task<[Element], Never> {
        Task {
            var elements: [Element] = []
            for await element in self {
                elements.append(element)
            }
            return elements
        }
    }
}

/// Gives already-scheduled work a chance to run before the test looks at the result.
func settle(_ seconds: TimeInterval = 0.15) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

extension Array where Element: Sendable {
    /// Drains an `AsyncStream` into an array. Paired with `withTimeout` so a stream that never
    /// finishes fails the test instead of hanging the run.
    init(_ stream: AsyncStream<Element>) async {
        self.init()
        for await element in stream {
            append(element)
        }
    }
}

/// Polls `condition` until it holds, rather than sleeping for a fixed time and hoping.
func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        await settle(0.01)
    }
    return condition()
}
