import Foundation

typealias ConfigSetHandler = @Sendable (ConfigSet) -> Void

/// Everything a ``Transport`` needs to reach the ConfigDirector server.
struct TransportOptions: Sendable {
    var clientSDKKey: String
    var baseURL: URL
    var metaContext: SDKMetaContext
    var instanceID: String
    var logger: any ConfigDirectorLogger
    var pollingInterval: TimeInterval
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

    /// Closes the connection without releasing the transport. It can be reconnected by calling
    /// ``connect(context:timeout:)`` again.
    func close()

    /// Closes the connection and releases every resource the transport holds.
    func shutdown()
}
