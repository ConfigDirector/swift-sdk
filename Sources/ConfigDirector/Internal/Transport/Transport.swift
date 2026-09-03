import Foundation

typealias ConfigSetHandler = @Sendable (ConfigSet) -> Void

struct TransportOptions: Sendable {
    var clientSDKKey: String
    var baseURL: URL
    var metaContext: SDKMetaContext
    var instanceID: String
    var logger: any ConfigDirectorLogger
    var pollingInterval: TimeInterval
    var session: URLSession = .shared

    var retryDelay: @Sendable (Int) -> TimeInterval = TransportOptions.exponentialRetryDelay

    /// 2^9 seconds is a little over 8 minutes, which caps the backoff to under 10.
    private static let maxExponentialDelay = 9

    /// Half of each delay is fixed and the other half is random, so that every client that lost the
    /// same server does not come back at the same instant.
    static let exponentialRetryDelay: @Sendable (Int) -> TimeInterval = { attempt in
        let ceiling = pow(2, TimeInterval(min(attempt, maxExponentialDelay)))
        return ceiling / 2 + TimeInterval.random(in: 0 ... ceiling / 2)
    }

    func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    func payload(
        for context: ConfigDirectorContext,
        lastUpdateTimestamp: String? = nil
    ) throws -> Data {
        try JSONEncoder().encode(TransportPayload(
            givenContext: context,
            metaContext: metaContext,
            clientSDKKey: clientSDKKey,
            instanceID: instanceID,
            lastUpdateTimestamp: lastUpdateTimestamp
        ))
    }
}

private struct TransportPayload: Encodable {
    var givenContext: ConfigDirectorContext
    var metaContext: SDKMetaContext
    var clientSDKKey: String
    var instanceID: String
    var lastUpdateTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case givenContext, metaContext, lastUpdateTimestamp
        case clientSDKKey = "clientSdkKey"
        case instanceID = "instanceId"
    }
}

/// Retrieves config state from the ConfigDirector server and hands each set it receives to the
/// handler it was created with.
protocol Transport: Sendable {
    /// Connects using `context`, returning once the connection is established or once `timeout`
    /// elapses.
    ///
    /// Returning does not imply config state was received; that arrives on the handler. Throws
    /// ``ConfigDirectorError/connectionFailed(message:statusCode:)`` when the connection fails in a
    /// way that retrying cannot fix.
    func connect(context: ConfigDirectorContext, timeout: TimeInterval) async throws

    /// Drops the connection without releasing the transport. It can be reconnected by calling
    /// ``connect(context:timeout:)`` again.
    func disconnect()

    /// Drops the connection and releases every resource the transport holds.
    func close()
}

extension Int {
    /// Whether an HTTP status means the request itself is wrong, an invalid SDK key for instance, so
    /// retrying it would fail the same way.
    var isFatalHTTPStatus: Bool {
        (400 ..< 500).contains(self)
    }
}
