import Foundation

/// A server-sent events client: connects, publishes what the server sends, and reconnects when the
/// connection drops for a reason the caller says is worth retrying.
final class EventSourceClient: Sendable {
    struct Configuration: Sendable {
        var url: URL
        var method = "GET"
        var headers: [String: String] = [:]
        var body: Data?
        var lastEventID: String?

        /// Long by design: a server-sent events connection is idle by nature, and a request timeout
        /// would drop a healthy stream that simply has nothing to say. A connection that actually
        /// fails is reported by the session without waiting for this.
        var requestTimeout: TimeInterval = 86400

        var shouldReconnect: @Sendable (EventSourceReconnectionState) -> Bool = { _ in true }

        var reconnectDelay: @Sendable (EventSourceReconnectionState) -> TimeInterval = {
            $0.serverReconnectionTime
        }
    }

    enum Event: Sendable {
        case open
        case message(EventSourceMessage)
        case comment(String)
        case error(any Error)
    }

    private struct State {
        var readyState = EventSourceReadyState.closed
        var lastEventID: String?
        var serverReconnectionTime: TimeInterval = 2
        var task: Task<Void, Never>?
        var isClosed = false
    }

    /// The range the spec allows a reconnect delay to fall in.
    private static let allowedReconnectDelay: ClosedRange<TimeInterval> = 0.001 ... 3600

    private let configuration: Configuration
    private let session: URLSession
    private let state: Locked<State>

    init(configuration: Configuration, session: URLSession) {
        self.configuration = configuration
        self.session = session
        state = Locked(State(lastEventID: configuration.lastEventID))
    }

    var readyState: EventSourceReadyState {
        state.withLock { $0.readyState }
    }

    var lastEventID: String? {
        state.withLock { $0.lastEventID }
    }

    /// Starts connecting and publishes everything that follows. The stream finishes once the client
    /// stops for good, whether from ``close()`` or because reconnecting was declined.
    func start() -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let canStart = state.withLock { state in
                state.task == nil && !state.isClosed
            }

            guard canStart else {
                continuation.finish()
                return
            }

            let task = Task { await run(continuation) }
            state.withLock { $0.task = task }

            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
    }

    /// Stops the client for good. It cannot be restarted.
    func close() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isClosed = true
            state.readyState = .closed
            let running = state.task
            state.task = nil
            return running
        }
        task?.cancel()
    }

    private func run(_ continuation: AsyncStream<Event>.Continuation) async {
        var attempt = 0

        while !Task.isCancelled {
            let outcome = await connectOnce(continuation)

            guard case let .ended(statusCode, error, didOpen) = outcome else {
                // 204 is the server saying not to reconnect.
                break
            }

            // A connection that opened starts the count over, so a long-lived stream dropping once
            // does not inherit the backoff of whatever failed before it.
            if didOpen {
                attempt = 0
            }
            attempt += 1

            if let error {
                continuation.yield(.error(error))
            }

            let reconnection = EventSourceReconnectionState(
                attempt: attempt,
                serverReconnectionTime: state.withLock { $0.serverReconnectionTime },
                statusCode: statusCode,
                error: error
            )

            guard !Task.isCancelled, configuration.shouldReconnect(reconnection) else { break }

            setReadyState(.connecting)

            var delay = configuration.reconnectDelay(reconnection)
            if !Self.allowedReconnectDelay.contains(delay) {
                continuation.yield(.error(EventSourceError.reconnectDelayOutOfRange(delay)))
                delay = reconnection.serverReconnectionTime
            }

            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(delay))
            } catch {
                break
            }
        }

        setReadyState(.closed)
        continuation.finish()
    }

    private enum ConnectionOutcome {
        /// The server returned 204, which means it does not want the client to come back.
        case noContent
        case ended(statusCode: Int?, error: (any Error)?, didOpen: Bool)
    }

    private func connectOnce(_ continuation: AsyncStream<Event>.Continuation) async -> ConnectionOutcome {
        setReadyState(.connecting)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: makeRequest())
        } catch {
            return .ended(statusCode: nil, error: error, didOpen: false)
        }

        guard let response = response as? HTTPURLResponse else {
            return .ended(statusCode: nil, error: EventSourceError.invalidResponse, didOpen: false)
        }

        if response.statusCode == 204 {
            return .noContent
        }

        guard response.statusCode < 400 else {
            return .ended(
                statusCode: response.statusCode,
                error: EventSourceError.serverError(statusCode: response.statusCode),
                didOpen: false
            )
        }

        setReadyState(.open)
        continuation.yield(.open)

        var parser = EventSourceParser()
        do {
            for try await byte in bytes {
                guard let output = parser.consume(byte) else { continue }
                deliver(output, to: continuation)
            }
        } catch {
            parser.finish()
            return .ended(statusCode: response.statusCode, error: error, didOpen: true)
        }

        parser.finish()
        return .ended(
            statusCode: response.statusCode,
            error: EventSourceError.streamClosed,
            didOpen: true
        )
    }

    private func deliver(
        _ output: EventSourceParser.Output,
        to continuation: AsyncStream<Event>.Continuation
    ) {
        switch output {
        case let .message(message):
            if let id = message.id {
                state.withLock { $0.lastEventID = id }
            }
            continuation.yield(.message(message))
        case let .comment(comment):
            continuation.yield(.comment(comment))
        case let .retry(interval):
            state.withLock { $0.serverReconnectionTime = interval }
        }
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: configuration.url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = configuration.method
        request.httpBody = configuration.body
        // A cached response would replay an old stream instead of opening a new one.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        for (name, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let lastEventID = state.withLock({ $0.lastEventID }) {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }

        return request
    }

    /// Converting a `TimeInterval` to nanoseconds traps on a negative value, and the delay can come
    /// from a caller's closure, so it is clamped to the range the spec allows rather than trusted.
    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > allowedReconnectDelay.lowerBound else { return 0 }
        return UInt64(min(seconds, allowedReconnectDelay.upperBound) * 1_000_000_000)
    }

    private func setReadyState(_ readyState: EventSourceReadyState) {
        state.withLock { $0.readyState = readyState }
    }
}
