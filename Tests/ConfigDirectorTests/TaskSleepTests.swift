@testable import ConfigDirector
import Foundation
import Testing

struct TaskSleepTests {
    @Test(arguments: [-1, 0, .nan, -.infinity] as [TimeInterval])
    func returnsAtOnceForAnIntervalThatIsNotPositive(seconds: TimeInterval) async throws {
        let started = Date()
        try await Task.sleep(seconds: seconds)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func sleepsForAPositiveInterval() async throws {
        let started = Date()
        try await Task.sleep(seconds: 0.05)
        #expect(Date().timeIntervalSince(started) >= 0.05)
    }

    @Test(arguments: [.infinity, .greatestFiniteMagnitude] as [TimeInterval])
    func sleepsWithoutTrappingForAnUnboundedInterval(seconds: TimeInterval) async {
        let sleeping = Task { try await Task.sleep(seconds: seconds) }
        await settle(0.05)
        sleeping.cancel()
        await #expect(throws: CancellationError.self) { try await sleeping.value }
    }
}
