import Foundation

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// Replaces the value at `keyPath`, returning what was there before.
    func exchange<Member>(_ keyPath: WritableKeyPath<Value, Member>, with newValue: Member) -> Member {
        withLock { value in
            let previous = value[keyPath: keyPath]
            value[keyPath: keyPath] = newValue
            return previous
        }
    }
}
