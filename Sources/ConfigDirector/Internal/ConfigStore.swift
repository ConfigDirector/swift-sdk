import Foundation

/// Holds the config state the client evaluates against, and everything that observes it: the ready
/// signal, the event broadcaster, and the active watch streams.
final class ConfigStore: Sendable {
    let events = Broadcaster<ClientEvent>()

    private struct Watcher: Sendable {
        let reevaluate: @Sendable () -> Void
        let finish: @Sendable () -> Void
    }

    private struct State {
        var configs: [String: ConfigState] = [:]
        var hasReceivedConfigSet = false
        var context: ConfigDirectorContext?
        var isReady = false
        var isClosed = false
        var pendingReason: ConnectReason = .initialization
        var readyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var watchers: [String: [UUID: Watcher]] = [:]
    }

    private let logger: any ConfigDirectorLogger
    private let state = Locked(State())

    init(logger: any ConfigDirectorLogger) {
        self.logger = logger
    }

    var isReady: Bool {
        state.withLock { $0.isReady }
    }

    var context: ConfigDirectorContext? {
        state.withLock { $0.context }
    }

    func beginConnect(reason: ConnectReason) {
        state.withLock {
            $0.isReady = false
            $0.pendingReason = reason
        }
    }

    func setContext(_ context: ConfigDirectorContext?) {
        state.withLock { $0.context = context }
        events.emit(.contextUpdated(context))
    }

    func markNotReady() {
        state.withLock { $0.isReady = false }
    }

    /// Waits until config state arrives, at most `timeout` seconds.
    func waitUntilReady(timeout: TimeInterval) async {
        let id = UUID()
        let timeoutTask = Locked<Task<Void, Never>?>(nil)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSettled = state.withLock { state -> Bool in
                guard !state.isReady, !state.isClosed else { return true }
                state.readyWaiters[id] = continuation
                return false
            }

            guard !isSettled else {
                continuation.resume()
                return
            }

            timeoutTask.withLock {
                $0 = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    self?.resumeReadyWaiter(id)
                }
            }
        }

        timeoutTask.withLock { $0 }?.cancel()
    }

    func handleConfigSet(_ configSet: ConfigSet) {
        let keys = Array(configSet.configs.keys)
        let watchers = state.withLock { state -> [Watcher] in
            if state.hasReceivedConfigSet, configSet.kind == .delta {
                state.configs.merge(configSet.configs) { _, updated in updated }
            } else {
                state.configs = configSet.configs
            }
            state.hasReceivedConfigSet = true
            return keys.flatMap { key in state.watchers[key].map { Array($0.values) } ?? [] }
        }

        markReady()
        events.emit(.configsUpdated(keys))
        for watcher in watchers {
            watcher.reevaluate()
        }
        logger.debug("Config state received from the server: \(keys)")
    }

    func value<Value: ConfigValue>(for key: String, default defaultValue: Value) -> Value {
        evaluate(key: key, default: defaultValue) {
            ConfigValueParser.parse($0, default: defaultValue)
        }
    }

    func value<Value: Decodable & Sendable>(
        for key: String,
        as type: Value.Type,
        default defaultValue: Value
    ) -> Value {
        evaluate(key: key, default: defaultValue) {
            ConfigValueParser.parseJSON($0, as: type, default: defaultValue)
        }
    }

    func values<Value: ConfigValue>(
        for key: String,
        default defaultValue: Value
    ) -> AsyncStream<Value> {
        stream(for: key) { [weak self] in
            self?.value(for: key, default: defaultValue) ?? defaultValue
        }
    }

    func values<Value: Decodable & Sendable & Equatable>(
        for key: String,
        as type: Value.Type,
        default defaultValue: Value
    ) -> AsyncStream<Value> {
        stream(for: key) { [weak self] in
            self?.value(for: key, as: type, default: defaultValue) ?? defaultValue
        }
    }

    func close() {
        let (watchers, waiters) = state.withLock { state -> ([Watcher], [CheckedContinuation<Void, Never>]) in
            state.isClosed = true
            state.isReady = false
            let watchers = state.watchers.values.flatMap { Array($0.values) }
            let waiters = Array(state.readyWaiters.values)
            state.watchers.removeAll()
            state.readyWaiters.removeAll()
            return (watchers, waiters)
        }

        for waiter in waiters {
            waiter.resume()
        }
        for watcher in watchers {
            watcher.finish()
        }
        events.finish()
    }

    private func evaluate<Value: Sendable>(
        key: String,
        default defaultValue: Value,
        parse: (ConfigState) -> EvaluationResult<Value>
    ) -> Value {
        let (configState, isReady, context) = state.withLock {
            ($0.configs[key], $0.isReady, $0.context)
        }

        let result = configState.map(parse) ?? EvaluationResult(
            value: defaultValue,
            usedDefault: true,
            reason: isReady ? .configStateMissing : .clientNotReady
        )

        events.emit(.configEvaluated(ConfigEvaluation(
            key: key,
            value: result.value,
            valueID: result.valueID,
            isDefaultValue: result.usedDefault,
            reason: result.reason,
            context: context
        )))
        logger.debug("Evaluated '\(key)' to '\(result.value)' (\(result.reason.rawValue))")

        return result.value
    }

    private func stream<Value: Equatable & Sendable>(
        for key: String,
        evaluate: @escaping @Sendable () -> Value
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let lastEmitted = Locked<Value?>(nil)

            let emitIfChanged: @Sendable () -> Void = {
                let value = evaluate()
                let hasChanged = lastEmitted.withLock { last -> Bool in
                    guard last != value else { return false }
                    last = value
                    return true
                }
                if hasChanged {
                    continuation.yield(value)
                }
            }

            let isClosed = state.withLock { state -> Bool in
                guard !state.isClosed else { return true }
                state.watchers[key, default: [:]][id] = Watcher(
                    reevaluate: emitIfChanged,
                    finish: { continuation.finish() }
                )
                return false
            }

            guard !isClosed else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.watchers[key]?[id] = nil }
            }

            emitIfChanged()
        }
    }

    private func markReady() {
        let (waiters, reason) = state.withLock { state -> (
            [CheckedContinuation<Void, Never>],
            ConnectReason?
        ) in
            guard !state.isReady, !state.isClosed else { return ([], nil) }
            state.isReady = true
            let waiters = Array(state.readyWaiters.values)
            state.readyWaiters.removeAll()
            return (waiters, state.pendingReason)
        }

        guard let reason else { return }

        for waiter in waiters {
            waiter.resume()
        }
        events.emit(.ready(reason))
        logger.debug("Received config state from the server, the client is ready")
    }

    private func resumeReadyWaiter(_ id: UUID) {
        state.withLock { $0.readyWaiters.removeValue(forKey: id) }?.resume()
    }
}
