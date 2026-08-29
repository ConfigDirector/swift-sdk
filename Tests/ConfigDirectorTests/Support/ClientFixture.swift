@testable import ConfigDirector
import Foundation

/// One client under test against a stubbed ConfigDirector server on a base URL of its own, so the
/// stub keeps it apart from every other test.
final class ClientFixture: Sendable {
    let baseURL: URL
    let streamURL: URL
    let pollURL: URL

    private let session = StubURLProtocol.makeSession()
    private let notifications = NotificationCenter()

    init() {
        baseURL = URL(string: "https://example.test/\(UUID().uuidString)/")!
        streamURL = URL(string: "client/sse/v1", relativeTo: baseURL)!.absoluteURL
        pollURL = URL(string: "client/polling/v1", relativeTo: baseURL)!.absoluteURL
    }

    func makeClient(
        mode: ConnectionMode = .streaming,
        timeout: TimeInterval = 1,
        pollingInterval: TimeInterval = 60,
        pausesWhileBackgrounded: Bool = true,
        lifecycle: (any AppLifecycleObserver)? = nil
    ) throws -> ConfigDirectorClient {
        try ConfigDirectorClient(
            clientSDKKey: "sdk-key",
            options: ConfigDirectorClientOptions(
                connection: ConnectionOptions(
                    mode: mode,
                    pollingInterval: pollingInterval,
                    timeout: timeout,
                    baseURL: baseURL,
                    pausesWhileBackgrounded: pausesWhileBackgrounded
                ),
                logger: ConsoleLogger(level: .off)
            ),
            session: session,
            lifecycle: lifecycle ?? NotificationCenterLifecycleObserver(
                center: notifications,
                backgroundNotification: .testDidEnterBackground,
                foregroundNotification: .testWillEnterForeground
            )
        )
    }

    func enterBackground() {
        notifications.post(name: .testDidEnterBackground, object: nil)
    }

    func returnToForeground() {
        notifications.post(name: .testWillEnterForeground, object: nil)
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

/// Reports whether the client is observing the app lifecycle, which no notification can show: the
/// client ignores what it receives after being closed whether or not it stopped observing.
final class RecordingLifecycleObserver: AppLifecycleObserver {
    private let observing = Locked(false)

    var isObserving: Bool {
        observing.withLock { $0 }
    }

    func start(onChange _: @escaping @Sendable (AppLifecyclePhase) -> Void) {
        observing.withLock { $0 = true }
    }

    func stop() {
        observing.withLock { $0 = false }
    }
}

extension Notification.Name {
    static let testDidEnterBackground = Notification.Name("test.didEnterBackground")
    static let testWillEnterForeground = Notification.Name("test.willEnterForeground")
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
