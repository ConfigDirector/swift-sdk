import Foundation

final class StreamingTransport: Transport {
    private struct State {
        var eventSource: EventSourceClient?
        var isClosed = false
    }

    private let options: TransportOptions
    private let url: URL
    private let onConfigSet: ConfigSetHandler
    private let state = Locked(State())

    init(options: TransportOptions, onConfigSet: @escaping ConfigSetHandler) {
        self.options = options
        self.onConfigSet = onConfigSet
        url = options.endpoint("client/sse/v1")
    }

    func connect(context: ConfigDirectorContext, timeout: TimeInterval) async throws {
        let connected = ConnectionGate()
        var configuration = EventSourceClient.Configuration(url: url)
        configuration.method = "POST"
        configuration.headers = ["Content-Type": "application/json"]
        configuration.body = try options.payload(for: context)
        configuration.shouldReconnect = { [weak self] in
            self?.shouldReconnect($0, connected) ?? false
        }
        configuration.reconnectDelay = { [options] in
            let delay = options.retryDelay($0.attempt)
            let message = "[StreamingTransport] Scheduling reconnect attempt #\($0.attempt) in \(delay)s."
            if $0.attempt <= 5 {
                options.logger.info(message)
            } else {
                options.logger.warn(message)
            }
            return delay
        }

        let eventSource = EventSourceClient(configuration: configuration, session: options.session)
        let (isClosed, previous) = state.withLock { state -> (Bool, EventSourceClient?) in
            guard !state.isClosed else { return (true, nil) }
            let previous = state.eventSource
            state.eventSource = eventSource
            return (false, previous)
        }
        previous?.close()
        guard !isClosed else { return }

        let events = eventSource.start()
        Task { [weak self] in
            for await event in events {
                self?.handle(event, connected)
            }
        }

        try await connected.wait(timeout: timeout)
    }

    func disconnect() {
        state.withLock { $0.eventSource }?.close()
    }

    func close() {
        state.withLock { $0.isClosed = true }
        release()
    }

    private func release() {
        state.exchange(\.eventSource, with: nil)?.close()
    }

    private func handle(_ event: EventSourceClient.Event, _ connected: ConnectionGate) {
        switch event {
        case .open:
            options.logger.debug("[StreamingTransport] Connected")
            connected.settle()
        case let .message(message):
            dispatch(message.data)
        case let .error(error):
            options.logger.debug("[StreamingTransport] Error", error: error)
        case .comment:
            break
        }
    }

    private func shouldReconnect(
        _ reconnection: EventSourceReconnectionState,
        _ connected: ConnectionGate
    ) -> Bool {
        guard reconnection.statusCode?.isFatalHTTPStatus == true else { return true }

        let error = Self.fatalError(reconnection)
        if !connected.settle(.failure(error)) {
            options.logger.error("[StreamingTransport] \(error.localizedDescription)")
        }
        return false
    }

    private func dispatch(_ data: String) {
        do {
            let configSet = try JSONDecoder().decode(ConfigSet.self, from: Data(data.utf8))
            onConfigSet(configSet)
        } catch {
            options.logger.error(
                "[StreamingTransport] Error parsing and dispatching the config state update",
                error: error
            )
        }
    }

    private static func fatalError(_ reconnection: EventSourceReconnectionState) -> ConfigDirectorError {
        let status = reconnection.statusCode.map(String.init) ?? "unknown"
        let errorLine = reconnection.error.map { " Error: \($0)." } ?? ""
        return .connectionFailed(
            message: """
            Connection failed with status: \(status).\(errorLine) This is an unrecoverable error, \
            will not attempt to reconnect.
            """,
            statusCode: reconnection.statusCode
        )
    }
}
