import Foundation

struct TelemetryMetaContext: Sendable, Encodable {
    var sdkName: String
    var sdkVersion: String
}

struct EventReport: Sendable {
    var snapshot: EventQueueSnapshot<EvaluatedConfigEvent>
    var context: ConfigDirectorContext?
}

enum ReportOutcome: Sendable, Equatable {
    case succeeded
    case failed

    /// The server rejected the report in a way retrying cannot fix, so nothing more should be sent.
    case failedFatally
}

/// Turns collected events into a report the ConfigDirector server accepts, and sends it.
protocol EventReporter: Sendable {
    func report(_ report: EventReport) async -> ReportOutcome
    func close()
}

/// The default ``EventReporter``.
///
/// Everything expensive — hashing large values, aggregating, encoding, and the request itself —
/// happens here rather than where events are collected, so none of it runs on the caller's thread.
final class HTTPEventReporter: EventReporter {
    private struct State {
        var isStopped = false
    }

    private let clientSDKKey: String
    private let url: URL
    private let metaContext: TelemetryMetaContext
    private let logger: any ConfigDirectorLogger
    private let session: URLSession
    private let timeout: TimeInterval
    private let state = Locked(State())

    init(
        clientSDKKey: String,
        baseURL: URL,
        metaContext: TelemetryMetaContext,
        logger: any ConfigDirectorLogger,
        session: URLSession,
        timeout: TimeInterval = 5
    ) {
        self.clientSDKKey = clientSDKKey
        url = URL(string: "client/telemetry/v1", relativeTo: baseURL)?.absoluteURL ?? baseURL
        self.metaContext = metaContext
        self.logger = logger
        self.session = session
        self.timeout = timeout
    }

    func report(_ report: EventReport) async -> ReportOutcome {
        guard !state.withLock({ $0.isStopped }) else { return .failedFatally }

        let compacted = EventQueueSnapshot(
            startTime: report.snapshot.startTime,
            endTime: report.snapshot.endTime,
            events: report.snapshot.events.map { $0.compacted() },
            droppedCount: report.snapshot.droppedCount
        )
        let aggregated = aggregate(compacted)

        guard !aggregated.isEmpty || report.snapshot.droppedCount > 0 else { return .succeeded }

        let body: Data
        do {
            body = try JSONEncoder().encode(TelemetryPayload(
                clientSDKKey: clientSDKKey,
                metaContext: metaContext,
                context: report.context,
                aggregatedEvents: .init(evaluatedConfig: aggregated),
                droppedEvents: .init(evaluatedConfig: report.snapshot.droppedCount)
            ))
        } catch {
            logger.warn("[EventReporter] Error encoding telemetry data", error: error)
            return .failed
        }

        let outcome = await send(body)
        if outcome == .failedFatally {
            state.withLock { $0.isStopped = true }
        }
        return outcome
    }

    func close() {
        state.withLock { $0.isStopped = true }
    }

    private func send(_ body: Data) async -> ReportOutcome {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            logger.warn("[EventReporter] Timed out after \(timeout)s sending telemetry data.")
            return .failed
        } catch {
            logger.warn("[EventReporter] Error attempting to send telemetry data", error: error)
            return .failed
        }

        guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }

        if isStatusFatal(status) {
            logger.warn("""
            [EventReporter] Received a fatal status response (\(status)) from the telemetry endpoint. \
            No more telemetry data will be sent.
            """)
            return .failedFatally
        }

        return (200 ..< 300).contains(status) ? .succeeded : .failed
    }
}

private struct TelemetryPayload: Encodable {
    struct AggregatedEvents: Encodable {
        var evaluatedConfig: [AggregatedEvent<EvaluatedConfigEvent>]
    }

    struct DroppedEvents: Encodable {
        var evaluatedConfig: Int
    }

    var clientSDKKey: String
    var metaContext: TelemetryMetaContext
    var context: ConfigDirectorContext?
    var discreteEvents: [String: String] = [:]
    var aggregatedEvents: AggregatedEvents
    var droppedEvents: DroppedEvents

    enum CodingKeys: String, CodingKey {
        case metaContext, context, discreteEvents, aggregatedEvents, droppedEvents
        case clientSDKKey = "clientSdkKey"
    }
}
