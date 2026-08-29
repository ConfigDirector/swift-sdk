@testable import ConfigDirector
import Foundation

/// One client under test against a stubbed ConfigDirector server on a base URL of its own, so the
/// stub keeps it apart from every other test.
final class ClientFixture: Sendable {
    let baseURL: URL
    let streamURL: URL
    let pollURL: URL

    private let session = StubURLProtocol.makeSession()

    init() {
        baseURL = URL(string: "https://example.test/\(UUID().uuidString)/")!
        streamURL = URL(string: "client/sse/v1", relativeTo: baseURL)!.absoluteURL
        pollURL = URL(string: "client/polling/v1", relativeTo: baseURL)!.absoluteURL
    }

    func makeClient(
        mode: ConnectionMode = .streaming,
        timeout: TimeInterval = 1,
        pollingInterval: TimeInterval = 60
    ) throws -> ConfigDirectorClient {
        try ConfigDirectorClient(
            clientSDKKey: "sdk-key",
            options: ConfigDirectorClientOptions(
                connection: ConnectionOptions(
                    mode: mode,
                    pollingInterval: pollingInterval,
                    timeout: timeout,
                    baseURL: baseURL
                ),
                logger: ConsoleLogger(level: .off)
            ),
            session: session
        )
    }

    /// Opens a server-sent events stream that sends `configSets` and then stays connected.
    func serveStream(_ configSets: String...) {
        StubURLProtocol.enqueue(
            [.init(chunks: configSets.map(sseEvent), endsStream: false)],
            for: streamURL
        )
    }

    func rejectStream(statusCode: Int) {
        StubURLProtocol.enqueue([.init(statusCode: statusCode)], for: streamURL)
    }

    /// Sends another config set down the open stream, the way the server pushes an update.
    func pushToStream(_ configSet: String) {
        StubURLProtocol.push(sseEvent(configSet), to: streamURL)
    }

    func servePolling(_ configSets: String...) {
        StubURLProtocol.enqueue(configSets.map { .json($0) }, for: pollURL)
    }

    var streamRequests: [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.recorded(for: streamURL)
    }

    var pollRequests: [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.recorded(for: pollURL)
    }

    var streamDisconnections: Int {
        StubURLProtocol.cancelled(for: streamURL)
    }
}

/// The config set the stubbed server serves, covering every config type the SDK evaluates.
let servedConfigSet = configSetJSON([
    ServedConfig("dark-mode", "boolean", "true", valueID: "on"),
    ServedConfig("welcome-message", "string", "Hello"),
    ServedConfig("max-retries", "integer", "3"),
    ServedConfig("discount-rate", "float", "0.15"),
    ServedConfig("theme", "json", #"{"primaryColor":"blue","cornerRadius":8}"#),
])

/// A config set carrying only the configs that changed.
func deltaConfigSet(_ configs: [ServedConfig]) -> String {
    configSetJSON(configs, kind: "delta")
}

extension ConfigDirectorClientOptions {
    static func test(timeout: TimeInterval = 1) -> ConfigDirectorClientOptions {
        ConfigDirectorClientOptions(
            connection: ConnectionOptions(timeout: timeout),
            logger: ConsoleLogger(level: .off)
        )
    }
}

struct Theme: Codable, Equatable {
    var primaryColor: String
    var cornerRadius: Int
}
