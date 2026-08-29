import Foundation

typealias TransportFactory = @Sendable (TransportOptions, @escaping ConfigSetHandler) -> any Transport

/// The ConfigDirector SDK client.
///
/// Applications should create a single instance and initialize it during startup.
///
/// ```swift
/// let client = try ConfigDirectorClient(clientSDKKey: "YOUR-SDK-KEY")
/// await client.initialize(context: ConfigDirectorContext(id: "user-123"))
///
/// let darkMode = client.value(for: "dark-mode", default: false)
/// ```
///
/// After initialization, call ``updateContext(_:)`` to re-evaluate configs against a new context,
/// and ``close()`` when the client is no longer needed.
public final class ConfigDirectorClient: Sendable {
    private struct ConnectionState {
        var isInitializing = false
        var isClosed = false
    }

    private let logger: any ConfigDirectorLogger
    private let timeout: TimeInterval
    private let store: ConfigStore
    private let transport: any Transport
    private let connectionState = Locked(ConnectionState())

    /// Creates a client for `clientSDKKey`, the client SDK key from the ConfigDirector dashboard.
    ///
    /// The client cannot serve config values until ``initialize(context:)`` completes. Until then,
    /// every config evaluates to its default value.
    ///
    /// - Throws: ``ConfigDirectorError/missingClientSDKKey`` when the key is blank, and
    ///   ``ConfigDirectorError/invalidBaseURL(_:)`` when ``ConnectionOptions/baseURL`` is not
    ///   absolute.
    public convenience init(
        clientSDKKey: String,
        options: ConfigDirectorClientOptions = ConfigDirectorClientOptions()
    ) throws {
        try self.init(
            clientSDKKey: clientSDKKey,
            options: options,
            transportFactory: StubTransport.init
        )
    }

    init(
        clientSDKKey: String,
        options: ConfigDirectorClientOptions,
        transportFactory: TransportFactory
    ) throws {
        guard !clientSDKKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigDirectorError.missingClientSDKKey
        }

        let baseURL = try Self.resolveBaseURL(options.connection.baseURL)
        let store = ConfigStore(logger: options.logger)

        logger = options.logger
        timeout = options.connection.timeout
        self.store = store
        transport = transportFactory(
            TransportOptions(
                clientSDKKey: clientSDKKey,
                baseURL: baseURL,
                metaContext: AppInfo.metaContext(metadata: options.metadata),
                instanceID: UUID().uuidString,
                logger: options.logger,
                pollingInterval: options.connection.pollingInterval
            ),
            { [store] configSet in store.handleConfigSet(configSet) }
        )
    }

    /// The context the client is currently evaluating configs against, or `nil` when there is none.
    ///
    /// This does not change the moment ``updateContext(_:)`` is called: configs are evaluated against
    /// the previous context until the underlying connection succeeds or times out.
    public var context: ConfigDirectorContext? {
        store.context
    }

    /// Whether the client is ready, meaning the connection to the server succeeded and config state
    /// was received.
    public var isReady: Bool {
        store.isReady
    }

    /// Whether the client is currently initializing. It is `false` on creation, `true` after
    /// ``initialize(context:)`` is called, and `false` again once initialization completes.
    public var isInitializing: Bool {
        connectionState.withLock { $0.isInitializing }
    }

    /// Every event the client publishes, from the moment this stream is created.
    ///
    /// Each access returns an independent stream; the client publishes to all of them.
    ///
    /// ```swift
    /// for await event in client.events {
    ///     if case let .configsUpdated(keys) = event { print(keys) }
    /// }
    /// ```
    public var events: AsyncStream<ClientEvent> {
        store.events.subscribe()
    }

    /// Connects to ConfigDirector to retrieve config evaluations. Until initialization succeeds,
    /// every config returns the default value passed to ``value(for:default:)`` or
    /// ``values(for:default:)``.
    ///
    /// If the connection fails or is interrupted by a transient error the client keeps trying to
    /// connect. If it fails with a persistent error, such as an invalid SDK key, the client stops
    /// trying and logs an error.
    ///
    /// - Parameter context: The current user's context, used to evaluate targeting rules.
    public func initialize(context: ConfigDirectorContext? = nil) async {
        connectionState.withLock { $0.isInitializing = true }
        await connect(context: context, reason: .initialization)
        connectionState.withLock { $0.isInitializing = false }
    }

    /// Updates the user's context and re-evaluates every config against it.
    public func updateContext(_ context: ConfigDirectorContext) async {
        await connect(context: context, reason: .contextUpdate)
    }

    /// Evaluates `key` against the current context and targeting rules.
    ///
    /// Returns `defaultValue` when config state is unavailable — for instance when called before
    /// initialization completes, or when the served value cannot be represented as `Value`.
    public func value<Value: ConfigValue>(for key: String, default defaultValue: Value) -> Value {
        store.value(for: key, default: defaultValue)
    }

    /// Evaluates a JSON config, decoding it into `type`.
    ///
    /// Returns `defaultValue` when config state is unavailable, when the config is not a JSON config,
    /// or when its document cannot be decoded into `type`.
    ///
    /// ```swift
    /// let theme = client.value(for: "theme", as: Theme.self, default: .fallback)
    /// ```
    public func value<Value: Decodable & Sendable>(
        for key: String,
        as type: Value.Type,
        default defaultValue: Value
    ) -> Value {
        store.value(for: key, as: type, default: defaultValue)
    }

    /// Watches `key` for changes, which can come from an update in the ConfigDirector dashboard or
    /// from a call to ``updateContext(_:)``.
    ///
    /// The stream yields the config's current value immediately and then every time the evaluated
    /// value changes. Consecutive identical values are not re-emitted. Cancelling the consuming task
    /// stops watching.
    ///
    /// ```swift
    /// .task {
    ///     for await darkMode in client.values(for: "dark-mode", default: false) {
    ///         self.darkMode = darkMode
    ///     }
    /// }
    /// ```
    public func values<Value: ConfigValue>(
        for key: String,
        default defaultValue: Value
    ) -> AsyncStream<Value> {
        store.values(for: key, default: defaultValue)
    }

    /// Watches a JSON config for changes, decoding each value into `type`.
    public func values<Value: Decodable & Sendable & Equatable>(
        for key: String,
        as type: Value.Type,
        default defaultValue: Value
    ) -> AsyncStream<Value> {
        store.values(for: key, as: type, default: defaultValue)
    }

    /// Pauses the network connection without discarding config state, event streams, or watch
    /// streams. Call ``resumeNetwork()`` to re-establish the connection.
    public func pauseNetwork() {
        logger.debug("pauseNetwork() called, pausing the transport connection")
        transport.close()
        store.markNotReady()
    }

    /// Resumes a connection paused by ``pauseNetwork()``, reusing the last context given to
    /// ``initialize(context:)`` or ``updateContext(_:)``.
    public func resumeNetwork() async {
        await connect(context: store.context, reason: .networkResume)
    }

    /// Closes the connection, every watch stream, and every event stream.
    ///
    /// Call this when your application shuts down. The client cannot be used afterwards.
    public func close() {
        let wasClosed = connectionState.withLock { state -> Bool in
            defer { state.isClosed = true }
            return state.isClosed
        }
        guard !wasClosed else { return }

        logger.debug("close() called, closing the connection to the server and removing all observers")
        store.close()
        transport.shutdown()
    }

    private func connect(context: ConfigDirectorContext?, reason: ConnectReason) async {
        store.beginConnect(reason: reason)
        let startedAt = Date()

        do {
            try await transport.connect(context: context ?? ConfigDirectorContext(), timeout: timeout)
        } catch {
            logger.error("An error occurred during \(reason)", error: error)
            return
        }

        store.setContext(context)

        // The transport may have spent part of the budget connecting; only the remainder is left to
        // wait for the first config set.
        let remaining = timeout - Date().timeIntervalSince(startedAt)
        if remaining > 0 {
            await store.waitUntilReady(timeout: remaining)
        }

        guard store.isReady else {
            logger.warn("""
            Timed out waiting for \(reason) after \(timeout)s. The client will keep retrying as long \
            as no fatal errors are detected. Configs return their default value until the connection \
            succeeds.
            """)
            return
        }
    }

    private static func resolveBaseURL(_ baseURL: URL?) throws -> URL {
        guard let baseURL else { return Constants.clientBaseURL }
        guard baseURL.scheme != nil, baseURL.host != nil else {
            throw ConfigDirectorError.invalidBaseURL(baseURL)
        }
        return baseURL
    }
}
