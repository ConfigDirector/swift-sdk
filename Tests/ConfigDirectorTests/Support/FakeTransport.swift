@testable import ConfigDirector
import Foundation

final class FakeTransport: Transport {
    struct Recording: Sendable {
        var connectedContexts: [ConfigDirectorContext] = []
        var closeCount = 0
        var shutdownCount = 0
    }

    private struct State {
        var handler: ConfigSetHandler?
        var configSetOnConnect: ConfigSet?
        var connectError: (any Error)?
        var recording = Recording()
    }

    private let state = Locked(State())

    init(deliveringOnConnect configSet: ConfigSet? = nil) {
        state.withLock { $0.configSetOnConnect = configSet }
    }

    var factory: TransportFactory {
        { [self] _, handler in
            state.withLock { $0.handler = handler }
            return self
        }
    }

    var recording: Recording {
        state.withLock { $0.recording }
    }

    func failNextConnect(with error: any Error) {
        state.withLock { $0.connectError = error }
    }

    func deliver(_ configSet: ConfigSet) {
        state.withLock { $0.handler }?(configSet)
    }

    func connect(context: ConfigDirectorContext, timeout _: TimeInterval) async throws {
        let (error, configSet) = state.withLock { state -> ((any Error)?, ConfigSet?) in
            state.recording.connectedContexts.append(context)
            defer { state.connectError = nil }
            return (state.connectError, state.configSetOnConnect)
        }

        if let error {
            throw error
        }
        if let configSet {
            deliver(configSet)
        }
    }

    func close() {
        state.withLock { $0.recording.closeCount += 1 }
    }

    func shutdown() {
        state.withLock { $0.recording.shutdownCount += 1 }
    }
}

extension ConfigState {
    static func make(
        key: String,
        type: ConfigType,
        value: String?,
        valueID: String? = nil
    ) -> ConfigState {
        ConfigState(id: key, key: key, type: type, value: value, valueID: valueID)
    }
}

extension ConfigSet {
    static func make(_ configs: [ConfigState], kind: ConfigSetKind = .full) -> ConfigSet {
        ConfigSet(
            configs: Dictionary(uniqueKeysWithValues: configs.map { ($0.key, $0) }),
            kind: kind
        )
    }
}

struct Theme: Codable, Equatable {
    var primaryColor: String
    var cornerRadius: Int
}

extension ConfigDirectorClientOptions {
    static func test(timeout: TimeInterval = 1) -> ConfigDirectorClientOptions {
        ConfigDirectorClientOptions(
            connection: ConnectionOptions(timeout: timeout),
            logger: ConsoleLogger(level: .off)
        )
    }
}
