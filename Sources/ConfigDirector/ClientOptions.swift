import Foundation

/// How the client connects to the ConfigDirector server.
public enum ConnectionMode: Sendable {
    /// Keeps a connection open and receives updates as soon as config state changes in the
    /// ConfigDirector dashboard.
    case streaming

    /// Fetches config state during initialization and then on a fixed interval.
    case polling

    /// Fetches config state during initialization and on context updates only.
    case oneTime
}

/// How the client connects to the ConfigDirector server.
public struct ConnectionOptions: Sendable {
    /// The connection mode to use.
    public var mode: ConnectionMode

    /// How often to re-fetch config state when ``mode`` is ``ConnectionMode/polling``. It has no
    /// effect in any other mode.
    public var pollingInterval: TimeInterval

    /// How long to wait for initialization and context updates.
    ///
    /// When streaming, the operation may still succeed after it times out, as long as no
    /// unrecoverable errors are encountered. In the other modes a timed-out operation is not
    /// retried.
    public var timeout: TimeInterval

    /// The base URL of the ConfigDirector SDK server. Set this only when routing through a proxy.
    public var baseURL: URL?

    /// Whether to pause the connection while the app is in the background and resume it when the app
    /// returns to the foreground.
    ///
    /// Mobile operating systems terminate background connections on their own, so this is enabled by
    /// default. Set it to `false` to manage the connection yourself with
    /// ``ConfigDirectorClient/pauseNetwork()`` and ``ConfigDirectorClient/resumeNetwork()``.
    ///
    /// It has no effect on macOS, where an app keeps running, and keeps its connections, once it
    /// leaves the foreground.
    public var pausesWhileBackgrounded: Bool

    public init(
        mode: ConnectionMode = .streaming,
        pollingInterval: TimeInterval = 60,
        timeout: TimeInterval = 3,
        baseURL: URL? = nil,
        pausesWhileBackgrounded: Bool = true
    ) {
        self.mode = mode
        self.pollingInterval = pollingInterval
        self.timeout = timeout
        self.baseURL = baseURL
        self.pausesWhileBackgrounded = pausesWhileBackgrounded
    }
}

/// Configuration for a ``ConfigDirectorClient``.
public struct ConfigDirectorClientOptions: Sendable {
    /// Metadata about your application that stays constant for the lifetime of the connection.
    public var metadata: ConfigDirectorMetaContext?

    /// Connection options.
    public var connection: ConnectionOptions

    /// Where the SDK writes its logs. Defaults to a ``ConsoleLogger`` at the
    /// ``ConfigDirectorLogLevel/warn`` level.
    ///
    /// ```swift
    /// ConfigDirectorClientOptions(logger: ConsoleLogger(level: .debug))
    /// ```
    public var logger: any ConfigDirectorLogger

    public init(
        metadata: ConfigDirectorMetaContext? = nil,
        connection: ConnectionOptions = ConnectionOptions(),
        logger: any ConfigDirectorLogger = ConsoleLogger()
    ) {
        self.metadata = metadata
        self.connection = connection
        self.logger = logger
    }
}
