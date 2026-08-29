import Foundation

/// Serves a fixed config set so the public API can be exercised before the real transports exist.
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
            "dark-mode": ConfigState(
                id: "1", key: "dark-mode", type: .boolean, value: "true", valueID: "1-on"
            ),
            "welcome-message": ConfigState(
                id: "2",
                key: "welcome-message",
                type: .string,
                value: "Hello from ConfigDirector",
                valueID: "2-greeting"
            ),
            "max-retries": ConfigState(
                id: "3", key: "max-retries", type: .integer, value: "3", valueID: "3-three"
            ),
            "discount-rate": ConfigState(
                id: "4", key: "discount-rate", type: .float, value: "0.15", valueID: "4-fifteen"
            ),
            "theme": ConfigState(
                id: "5",
                key: "theme",
                type: .json,
                value: ##"{"primaryColor":"#3366FF","cornerRadius":8}"##,
                valueID: "5-blue"
            ),
        ]
    )
}
