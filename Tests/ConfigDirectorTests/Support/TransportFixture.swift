@testable import ConfigDirector
import Foundation

/// One transport under test, on a base URL of its own so the stub keeps it apart from every other
/// test, together with the config sets the transport handed back.
final class TransportFixture: Sendable {
    let options: TransportOptions
    let endpoint: URL

    private let configSets = Locked<[ConfigSet]>([])

    init(
        path: String,
        pollingInterval: TimeInterval = 60,
        retryDelay: @escaping @Sendable (Int) -> TimeInterval = { _ in 0.01 }
    ) {
        let baseURL = URL(string: "https://example.test/\(UUID().uuidString)/")!
        options = TransportOptions(
            clientSDKKey: "test-key",
            baseURL: baseURL,
            metaContext: SDKMetaContext(
                sdkName: "swift-client-sdk",
                sdkVersion: "0.1.0",
                appName: "Sample",
                appVersion: "1.0",
                userAgent: "iOS"
            ),
            instanceID: "instance-1",
            logger: ConsoleLogger(level: .off),
            pollingInterval: pollingInterval,
            session: StubURLProtocol.makeSession(),
            retryDelay: retryDelay
        )
        endpoint = options.endpoint(path)
    }

    var onConfigSet: ConfigSetHandler {
        { [configSets] configSet in configSets.withLock { $0.append(configSet) } }
    }

    var received: [ConfigSet] {
        configSets.withLock { $0 }
    }

    var recorded: [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.recorded(for: endpoint)
    }

    var cancelled: Int {
        StubURLProtocol.cancelled(for: endpoint)
    }

    func enqueue(_ responses: StubURLProtocol.Response...) {
        StubURLProtocol.enqueue(responses, for: endpoint)
    }

    func waitForConfigSets(_ count: Int, timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) { [self] in received.count >= count }
    }

    func waitForRequests(_ count: Int, timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) { [self] in recorded.count >= count }
    }
}

/// The payload every transport posts to the server, read back from a recorded request.
struct SentPayload: Decodable, Sendable {
    struct Context: Decodable, Sendable {
        var id: String?
        var name: String?
        var anonymous: Bool?
    }

    struct Meta: Decodable, Sendable {
        var sdkName: String
        var sdkVersion: String
        var appName: String?
        var appVersion: String?
        var userAgent: String?
    }

    var givenContext: Context
    var metaContext: Meta
    var clientSdkKey: String
    var instanceId: String
    var lastUpdateTimestamp: String?
}

extension StubURLProtocol.RecordedRequest {
    var payload: SentPayload? {
        body.flatMap { try? JSONDecoder().decode(SentPayload.self, from: Data($0.utf8)) }
    }
}

extension StubURLProtocol.Response {
    static func json(_ body: String, statusCode: Int = 200) -> Self {
        Self(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            chunks: body.isEmpty ? [] : [body]
        )
    }
}

/// A config in a config set the stubbed server serves.
struct ServedConfig: Sendable {
    var key: String
    var type: String
    var value: String?
    var valueID: String?

    init(_ key: String, _ type: String, _ value: String?, valueID: String? = nil) {
        self.key = key
        self.type = type
        self.value = value
        self.valueID = valueID
    }
}

/// The JSON body of a config set, as the ConfigDirector server sends it.
func configSetJSON(
    _ configs: [ServedConfig],
    kind: String = "full",
    timestamp: String? = nil
) -> String {
    let encoded = try? JSONEncoder().encode(ServedConfigSet(
        kind: kind,
        timestamp: timestamp,
        configs: Dictionary(uniqueKeysWithValues: configs.map { config in
            (config.key, ServedConfigSet.Config(
                id: config.key,
                key: config.key,
                type: config.type,
                value: config.value,
                valueId: config.valueID
            ))
        })
    ))

    return encoded.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

/// A config set carrying a single string config, which is all the transport tests need to tell one
/// config set from the next.
func configSetJSON(greeting: String, timestamp: String? = nil) -> String {
    configSetJSON([ServedConfig("greeting", "string", greeting, valueID: "v1")], timestamp: timestamp)
}

/// One server-sent event carrying `configSet`.
func sseEvent(_ configSet: String) -> String {
    "data: \(configSet)\n\n"
}

private struct ServedConfigSet: Encodable {
    struct Config: Encodable {
        var id: String
        var key: String
        var type: String
        var value: String?
        var valueId: String?
    }

    var environmentId = "env"
    var projectId = "proj"
    var kind: String
    var timestamp: String?
    var configs: [String: Config]
}
