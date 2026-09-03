import Foundation

final class PollingTransport: Transport {
    private struct State {
        var polling: Task<Void, Never>?
        var connectionGeneration = 0
        var lastUpdateTimestamp: String?
        var fatalError: ConfigDirectorError?
        var isClosed = false
    }

    private let options: TransportOptions
    private let url: URL
    private let pollingInterval: TimeInterval?
    private let onConfigSet: ConfigSetHandler
    private let state = Locked(State())

    init(
        options: TransportOptions,
        pollingInterval: TimeInterval?,
        onConfigSet: @escaping ConfigSetHandler
    ) {
        self.options = options
        self.pollingInterval = pollingInterval
        self.onConfigSet = onConfigSet
        url = options.endpoint("client/polling/v1")
    }

    convenience init(options: TransportOptions, onConfigSet: @escaping ConfigSetHandler) {
        self.init(
            options: options,
            pollingInterval: options.pollingInterval,
            onConfigSet: onConfigSet
        )
    }

    static func oneTime(
        options: TransportOptions,
        onConfigSet: @escaping ConfigSetHandler
    ) -> PollingTransport {
        PollingTransport(options: options, pollingInterval: nil, onConfigSet: onConfigSet)
    }

    func connect(context: ConfigDirectorContext, timeout: TimeInterval) async throws {
        let (isClosed, fatalError) = state.withLock { ($0.isClosed, $0.fatalError) }
        guard !isClosed else { return }
        if let fatalError {
            options.logger.warn("""
            [PollingTransport] There was a prior unrecoverable error. Ignoring attempt to reconnect.
            """)
            throw fatalError
        }

        let generation = endCurrentConnection()
        defer { schedulePolling(context: context, timeout: timeout, generation: generation) }

        do {
            try await fetch(context: context, timeout: timeout)
        } catch let error where willRetryOnInterval {
            options.logger.warn(
                "[PollingTransport] Error fetching config state, polling continues on the interval",
                error: error
            )
        }
    }

    func disconnect() {
        endCurrentConnection()
    }

    func close() {
        state.withLock { $0.isClosed = true }
        disconnect()
    }

    @discardableResult
    private func endCurrentConnection() -> Int {
        let (polling, generation) = state.withLock { state -> (Task<Void, Never>?, Int) in
            state.connectionGeneration += 1
            let running = state.polling
            state.polling = nil
            return (running, state.connectionGeneration)
        }
        polling?.cancel()
        return generation
    }

    private var willRetryOnInterval: Bool {
        guard let pollingInterval, pollingInterval > 0 else { return false }
        return state.withLock { $0.fatalError == nil }
    }

    private func schedulePolling(context: ConfigDirectorContext, timeout: TimeInterval, generation: Int) {
        guard let pollingInterval, willRetryOnInterval else { return }

        let polling = Task { [weak self] in
            while !Task.isCancelled {
                guard await (try? Task.sleep(seconds: pollingInterval)) != nil, let self else { return }

                do {
                    try await fetch(context: context, timeout: timeout)
                } catch {
                    options.logger.warn("[PollingTransport] Error during polling", error: error)
                }
            }
        }
        let superseded = state.withLock { state -> Task<Void, Never>? in
            guard state.connectionGeneration == generation else { return polling }
            let previous = state.polling
            state.polling = polling
            return previous
        }
        superseded?.cancel()
    }

    private func fetch(context: ConfigDirectorContext, timeout: TimeInterval) async throws {
        let lastUpdateTimestamp = state.withLock { $0.lastUpdateTimestamp }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try options.payload(for: context, lastUpdateTimestamp: lastUpdateTimestamp)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await options.session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ConfigDirectorError.connectionFailed(
                message: "Connection timed out after \(timeout)s.",
                statusCode: nil
            )
        } catch {
            throw ConfigDirectorError.connectionFailed(
                message: "Connection failed with error: \(error).",
                statusCode: nil
            )
        }

        guard let response = response as? HTTPURLResponse else {
            throw ConfigDirectorError.connectionFailed(
                message: "The server responded with an unexpected payload.",
                statusCode: nil
            )
        }

        try throwOnErrorStatus(response, body: data)

        guard response.statusCode == 200 else { return }

        try dispatch(data)
    }

    private func throwOnErrorStatus(_ response: HTTPURLResponse, body: Data) throws {
        let status = response.statusCode
        guard !(200 ..< 300).contains(status) else { return }

        guard status.isFatalHTTPStatus else {
            throw ConfigDirectorError.connectionFailed(
                message: "Connection failed with status: \(status)",
                statusCode: status
            )
        }

        disconnect()

        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = ConfigDirectorError.connectionFailed(
            message: """
            Connection failed with status: \(status)\(text.isEmpty ? "" : " (\(text))"). This is an \
            unrecoverable error, retry attempts will be ignored.
            """,
            statusCode: status
        )
        state.withLock { $0.fatalError = error }
        throw error
    }

    private func dispatch(_ data: Data) throws {
        let configSet: ConfigSet
        do {
            configSet = try JSONDecoder().decode(ConfigSet.self, from: data)
        } catch {
            throw ConfigDirectorError.connectionFailed(
                message: "Failed to parse the response from the server: \(error)",
                statusCode: nil
            )
        }

        state.withLock { $0.lastUpdateTimestamp = configSet.timestamp }
        onConfigSet(configSet)
    }
}
