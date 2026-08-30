import Foundation

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result {
        LockNesting.willAcquire(self, file, line)
        lock.lock()
        defer {
            LockNesting.didRelease()
            lock.unlock()
        }
        return try body(&value)
    }

    /// Replaces the value at `keyPath`, returning what was there before.
    func exchange<Member>(
        _ keyPath: WritableKeyPath<Value, Member>,
        with newValue: Member,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Member {
        withLock(file: file, line: line) { value in
            let previous = value[keyPath: keyPath]
            value[keyPath: keyPath] = newValue
            return previous
        }
    }
}

/// Enforces, in debug builds, that a thread never holds more than one ``Locked`` at a time.
///
/// Deadlock needs a thread to hold one lock while waiting for another. While no thread ever holds
/// two, no wait-for cycle can form and the SDK cannot deadlock on its own locks. That invariant
/// holds today only because every call-out is hoisted out of the critical section, which nothing
/// would otherwise stop a later change from undoing — silently, since the symptom is a hang rather
/// than a test failure. This turns that hang into an immediate report naming both call sites.
enum LockNesting {
    #if DEBUG
        private struct Acquisition {
            let lock: ObjectIdentifier
            let file: StaticString
            let line: UInt

            var site: String {
                "\(file):\(line)"
            }
        }

        private final class Held {
            var entries: [Acquisition] = []
        }

        private static let threadKey = "com.configdirector.Locked.held"

        private static var held: Held {
            if let existing = Thread.current.threadDictionary[threadKey] as? Held {
                return existing
            }
            let fresh = Held()
            Thread.current.threadDictionary[threadKey] = fresh
            return fresh
        }
    #endif

    static func willAcquire(_ lock: AnyObject, _ file: StaticString, _ line: UInt) {
        #if DEBUG
            let acquiring = Acquisition(lock: ObjectIdentifier(lock), file: file, line: line)
            let held = held
            if let outer = held.entries.last {
                report(outer: outer, inner: acquiring)
            }
            held.entries.append(acquiring)
        #endif
    }

    static func didRelease() {
        #if DEBUG
            let held = held
            if !held.entries.isEmpty {
                held.entries.removeLast()
            }
        #endif
    }

    #if DEBUG
        private static func report(outer: Acquisition, inner: Acquisition) -> Never {
            let cause = outer.lock == inner.lock
                ? """
                The same Locked was acquired twice on one thread, which NSLock cannot satisfy: this \
                call would have hung here.
                """
                : """
                A second Locked was acquired while the first was still held. Should another thread \
                ever take those two in the opposite order, the pair deadlocks.
                """

            preconditionFailure("""
            Lock nesting detected: \(inner.site) ran while \(outer.site) still held its lock.
            \(cause)
            Hoist the call out of the critical section: copy what you need out under the lock, let \
            `withLock` return, then do the work.
            """)
        }
    #endif
}
