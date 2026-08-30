import Foundation

/// How the collector is tuned. Not part of the public API: the defaults are what applications get.
struct TelemetryOptions: Sendable {
    var flushInterval: TimeInterval = 30
    var initialFlushDelay: TimeInterval = 5
    var queueLimit = 1000
}

/// Collects what the SDK reports back to ConfigDirector.
///
/// ``evaluatedConfig(_:)`` is called from the client's hot path, so implementations must return
/// without doing any appreciable work.
protocol TelemetryClient: Sendable {
    func evaluatedConfig(_ event: EvaluatedConfigEvent)

    /// Reports the events collected so far against the previous context, and attributes the ones
    /// collected from now on to `context`.
    func updateContext(_ context: ConfigDirectorContext?) async

    /// Reports everything collected so far without waiting for the next flush.
    func flush() async

    /// Reports whatever is left and releases every resource held.
    func close()
}

/// The default ``TelemetryClient``: it queues evaluations as they happen and hands them to an
/// ``EventReporter`` on an interval.
///
/// Collecting an event only appends it to a bounded in-memory queue, which is what keeps evaluating
/// a config cheap. Everything expensive happens in the reporter, on the cooperative pool.
final class TelemetryEventCollector: TelemetryClient {
    private struct State {
        var context: ConfigDirectorContext?
        var timer: Task<Void, Never>?
        var isCollecting = true
        var isClosed = false
    }

    private let reporter: any EventReporter
    private let logger: any ConfigDirectorLogger
    private let options: TelemetryOptions
    private let queue: EventQueue<EvaluatedConfigEvent>
    private let flushes = SerialAsyncQueue()
    private let state = Locked(State())

    init(
        reporter: any EventReporter,
        logger: any ConfigDirectorLogger,
        options: TelemetryOptions = TelemetryOptions()
    ) {
        self.reporter = reporter
        self.logger = logger
        self.options = options
        queue = EventQueue(limit: options.queueLimit)

        startTimer(after: options.initialFlushDelay)
    }

    /// What has been collected but not yet reported.
    var pendingEventCount: Int {
        queue.events.count
    }

    func evaluatedConfig(_ event: EvaluatedConfigEvent) {
        guard state.withLock({ $0.isCollecting }) else { return }
        queue.push(event)
    }

    func updateContext(_ context: ConfigDirectorContext?) async {
        guard !state.withLock({ $0.isClosed }) else { return }

        let pending = takeSnapshot()
        state.withLock { $0.context = context }
        await enqueueReport(pending)

        restartTimer()
    }

    func flush() async {
        guard !state.withLock({ $0.isClosed }) else { return }

        await enqueueReport(takeSnapshot())
        restartTimer()
    }

    func close() {
        let timer = state.withLock { state -> Task<Void, Never>? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            state.isCollecting = false
            let running = state.timer
            state.timer = nil
            return running
        }
        timer?.cancel()

        let pending = takeSnapshot()
        Task { [self] in
            await enqueueReport(pending)
            reporter.close()
            queue.clear()
        }
    }

    private func takeSnapshot() -> EventReport? {
        guard !queue.isEmpty else { return nil }
        return EventReport(snapshot: queue.takeSnapshot(), context: state.withLock { $0.context })
    }

    /// Sends `report` after whatever is already in flight, so batches reach the server in the order
    /// they were collected.
    private func enqueueReport(_ report: EventReport?) async {
        guard let report else { return }

        await flushes.enqueue { [self] in await send(report) }
    }

    private func send(_ report: EventReport) async {
        if await reporter.report(report) == .failedFatally {
            stopCollecting()
        }
    }

    private func stopCollecting() {
        let timer = state.withLock { state -> Task<Void, Never>? in
            state.isCollecting = false
            let running = state.timer
            state.timer = nil
            return running
        }
        timer?.cancel()

        queue.clear()
        reporter.close()
        logger.warn("""
        [TelemetryEventCollector] Received a fatal error while reporting telemetry. No longer \
        collecting events.
        """)
    }

    private func restartTimer() {
        guard state.withLock({ $0.isCollecting && !$0.isClosed }) else { return }
        startTimer(after: options.flushInterval)
    }

    private func startTimer(after delay: TimeInterval) {
        let timer = Task { [weak self] in
            var next = delay
            while !Task.isCancelled {
                let slept: Void? = try? await Task.sleep(nanoseconds: UInt64(max(0, next) * 1_000_000_000))
                guard slept != nil, let self else { return }

                await enqueueReport(takeSnapshot())
                next = options.flushInterval
            }
        }

        state.exchange(\.timer, with: timer)?.cancel()
    }
}
