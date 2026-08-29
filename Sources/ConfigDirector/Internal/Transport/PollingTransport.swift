import Foundation

/// A ``Transport`` that fetches config state on connect and then re-fetches it on a fixed interval.
///
/// A `nil` polling interval disables the interval, which is how the one-time transport fetches
/// config state on connect only.
final class PollingTransport: Transport {
    private struct State {
        var polling: Task<Void, Never>?
        var lastUpdateTimestamp: String?
        var hasFatalError = false
        var isShutDown = false
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

    /// A transport that fetches config state on connect only, never polling for updates afterwards.
    static func oneTime(
        options: TransportOptions,
        onConfigSet: @escaping ConfigSetHandler
    ) -> PollingTransport {
        PollingTransport(options: options, pollingInterval: nil, onConfigSet: onConfigSet)
    }

    func connect(context: ConfigDirectorContext, timeout: TimeInterval) async throws {
        let (isShutDown, hasFatalError) = state.withLock { ($0.isShutDown, $0.hasFatalError) }
        guard !isShutDown else { return }
        guard !hasFatalError else {
            options.logger.warn("""
            [PollingTransport] There was a prior unrecoverable error. Ignoring attempt to reconnect.
            """)
            return
        }

        close()

        // A transient failure on the first fetch must not leave the client without a connection:
        // polling starts regardless of how that fetch went.
        defer { schedulePolling(context: context, timeout: timeout) }

        try await fetch(context: context, timeout: timeout)
    }

    func close() {
        state.withLock { state in
            defer { state.polling = nil }
            return state.polling
        }?.cancel()
    }

    func shutdown() {
        state.withLock { $0.isShutDown = true }
        close()
    }

    private func schedulePolling(context: ConfigDirectorContext, timeout: TimeInterval) {
        guard let pollingInterval, pollingInterval > 0,
              !state.withLock({ $0.hasFatalError }) else { return }

        let polling = Task { [weak self] in
            while !Task.isCancelled {
                guard await (try? Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))) != nil,
                      let self else { return }

                do {
                    try await fetch(context: context, timeout: timeout)
                } catch {
                    options.logger.warn("[PollingTransport] Error during polling", error: error)
                }
            }
        }
        state.withLock { $0.polling = polling }
    }

    private func fetch(context: ConfigDirectorContext, timeout: TimeInterval) async throws {
        let lastUpdateTimestamp = state.withLock { $0.lastUpdateTimestamp }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        // A cached config set would serve stale values after a change in the dashboard.
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

        guard isStatusFatal(status) else {
            throw ConfigDirectorError.connectionFailed(
                message: "Connection failed with status: \(status)",
                statusCode: status
            )
        }

        state.withLock { $0.hasFatalError = true }
        close()

        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ConfigDirectorError.connectionFailed(
            message: """
            Connection failed with status: \(status)\(text.isEmpty ? "" : " (\(text))"). This is an \
            unrecoverable error, retry attempts will be ignored.
            """,
            statusCode: status
        )
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
