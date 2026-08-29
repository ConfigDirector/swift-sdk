@testable import ConfigDirector
import Foundation
import Testing

/// Records what it was asked to report, and whether any of that work landed on the main thread.
private final class RecordingReporter: EventReporter, Sendable {
    private struct State {
        var reports: [EventReport] = []
        var sawMainThread = false
        var outcome = ReportOutcome.succeeded
    }

    private let state = Locked(State())

    var reports: [EventReport] {
        state.withLock { $0.reports }
    }

    var sawMainThread: Bool {
        state.withLock { $0.sawMainThread }
    }

    func failFatally() {
        state.withLock { $0.outcome = .failedFatally }
    }

    func report(_ report: EventReport) async -> ReportOutcome {
        // Compaction and aggregation happen inside the real reporter, so this is the thread they run
        // on there too.
        _ = report.snapshot.events.map { $0.compacted() }

        return state.withLock { state in
            state.reports.append(report)
            state.sawMainThread = state.sawMainThread || Thread.isMainThread
            return state.outcome
        }
    }

    func close() {}
}

struct TelemetryCollectorTests {
    private func makeEvent(key: String = "dark-mode") -> EvaluatedConfigEvent {
        EvaluatedConfigEvent(
            key: key,
            defaultValue: TelemetryValue(value: "false"),
            requestedType: "Bool",
            evaluatedValue: TelemetryValue(value: String(repeating: "a", count: 600)),
            usedDefault: false,
            evaluationReason: .foundMatch
        )
    }

    private func makeCollector(
        _ reporter: RecordingReporter,
        flushInterval: TimeInterval = 0.05
    ) -> TelemetryEventCollector {
        TelemetryEventCollector(
            reporter: reporter,
            logger: ConsoleLogger(level: .off),
            options: TelemetryOptions(flushInterval: flushInterval, initialFlushDelay: flushInterval)
        )
    }

    @MainActor
    @Test func neitherCollectsNorReportsOnTheMainThread() async {
        let reporter = RecordingReporter()
        let collector = makeCollector(reporter)
        defer { collector.close() }

        for _ in 0 ..< 50 {
            collector.evaluatedConfig(makeEvent())
        }

        #expect(await waitUntil { !reporter.reports.isEmpty })
        #expect(reporter.sawMainThread == false, "telemetry was aggregated and reported on the main thread")
    }

    @Test func reportsOnTheFlushInterval() async {
        let reporter = RecordingReporter()
        let collector = makeCollector(reporter)
        defer { collector.close() }

        collector.evaluatedConfig(makeEvent(key: "one"))
        #expect(await waitUntil { reporter.reports.count == 1 })

        collector.evaluatedConfig(makeEvent(key: "two"))
        #expect(await waitUntil { reporter.reports.count == 2 })
        #expect(reporter.reports.map { $0.snapshot.events.map(\.key) } == [["one"], ["two"]])
    }

    @Test func reportsNothingWhenNothingWasCollected() async {
        let reporter = RecordingReporter()
        let collector = makeCollector(reporter)
        defer { collector.close() }

        await settle(0.3)

        #expect(reporter.reports.isEmpty)
    }

    @Test func stopsCollectingAfterAFatalReport() async {
        let reporter = RecordingReporter()
        reporter.failFatally()
        let collector = makeCollector(reporter)
        defer { collector.close() }

        collector.evaluatedConfig(makeEvent())
        #expect(await waitUntil { reporter.reports.count == 1 })

        collector.evaluatedConfig(makeEvent())
        await settle(0.3)

        #expect(reporter.reports.count == 1)
    }

    @Test func reportsWhatIsLeftOnClose() async {
        let reporter = RecordingReporter()
        let collector = makeCollector(reporter, flushInterval: 60)

        collector.evaluatedConfig(makeEvent())
        collector.close()

        #expect(await waitUntil { reporter.reports.count == 1 })
        #expect(reporter.reports.first?.snapshot.events.count == 1)
    }

    @Test func collectsNothingOnceClosed() async {
        let reporter = RecordingReporter()
        let collector = makeCollector(reporter, flushInterval: 0.05)
        collector.close()

        collector.evaluatedConfig(makeEvent())
        await settle(0.3)

        #expect(reporter.reports.isEmpty)
        #expect(collector.pendingEventCount == 0, "events piled up with nothing left to report them")
    }

    @Test func collectsNothingAfterAFatalReport() async {
        let reporter = RecordingReporter()
        reporter.failFatally()
        let collector = makeCollector(reporter)
        defer { collector.close() }

        collector.evaluatedConfig(makeEvent())
        #expect(await waitUntil { reporter.reports.count == 1 })

        collector.evaluatedConfig(makeEvent())
        await settle(0.2)

        #expect(collector.pendingEventCount == 0, "events piled up with nothing left to report them")
    }
}
