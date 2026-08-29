import Foundation

/// Serves a fixed config set so the public API can be exercised before the real transports exist.
///
/// The keys are the ones in the ConfigDirector sample project, so the sample app shows the same
/// values here that it will once it talks to a server.
struct StubTransport: Transport {
    private let onConfigSet: ConfigSetHandler

    init(options _: TransportOptions, onConfigSet: @escaping ConfigSetHandler) {
        self.onConfigSet = onConfigSet
    }

    func connect(context _: ConfigDirectorContext, timeout _: TimeInterval) async throws {
        onConfigSet(Self.configSet)
    }

    func close() {}

    func shutdown() {}

    static let configSet = ConfigSet(
        environmentID: "stub-environment",
        projectID: "stub-project",
        configs: [
            "temporary-feature-flag": ConfigState(
                id: "1",
                key: "temporary-feature-flag",
                type: .boolean,
                value: "true",
                valueID: "1-on"
            ),
            "permanent-kill-switch": ConfigState(
                id: "2",
                key: "permanent-kill-switch",
                type: .boolean,
                value: "false",
                valueID: "2-off"
            ),
            "integer-config": ConfigState(
                id: "3",
                key: "integer-config",
                type: .integer,
                value: "42",
                valueID: "3-forty-two"
            ),
            "day-of-the-week-config": ConfigState(
                id: "4",
                key: "day-of-the-week-config",
                type: .string,
                value: "Wednesday",
                valueID: "4-wednesday"
            ),
            "json-value-config": ConfigState(
                id: "5",
                key: "json-value-config",
                type: .json,
                value: ##"{"greeting":"Hello from ConfigDirector","retries":3}"##,
                valueID: "5-greeting"
            ),
        ]
    )
}
