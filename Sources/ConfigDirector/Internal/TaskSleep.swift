import Foundation

/// Ten years, which stands in for an infinite or absurdly long sleep so that converting the interval
/// to nanoseconds can never trap.
private let longestSleep: TimeInterval = 10 * 365 * 24 * 60 * 60

extension Task where Success == Never, Failure == Never {
    /// Sleeps for `seconds`, treating a negative, NaN, or infinite interval as no wait or the
    /// longest wait rather than trapping the way `UInt64(Double)` does.
    static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await sleep(nanoseconds: UInt64(min(seconds, longestSleep) * 1_000_000_000))
    }
}
