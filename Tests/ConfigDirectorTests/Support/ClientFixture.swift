@testable import ConfigDirector
import Foundation

/// One client under test against a stubbed ConfigDirector server on a base URL of its own, so the
/// stub keeps it apart from every other test.
final class ClientFixture: Sendable {
    let baseURL: URL
    let streamURL: URL
    let pollURL: URL
    let telemetryURL: URL

    private let session = StubURLProtocol.makeSession()
    private let notifications = NotificationCenter()

    /// `basePath` is appended to the base URL without a trailing slash, the way an application
    /// routing through a proxy is likely to write it.
    init(telemetryStatus: Int? = 202, basePath: String? = nil) {
        let root = "https://example.test/\(UUID().uuidString)" + (basePath ?? "")
        baseURL = URL(string: basePath == nil ? root + "/" : root)!
        streamURL = URL(string: root + "/client/sse/v1")!
        pollURL = URL(string: root + "/client/polling/v1")!
        telemetryURL = URL(string: root + "/client/telemetry/v1")!

        // Telemetry goes out on its own schedule in every test, so the endpoint always answers.
        // A nil status leaves it unresponsive, which is how a test proves nothing waits on it.
        if let telemetryStatus {
            StubURLProtocol.enqueue(
                Array(repeating: .json("{}", statusCode: telemetryStatus), count: 20),
                for: telemetryURL
            )
        }
    }

    func makeClient(
        mode: ConnectionMode = .streaming,
        timeout: TimeInterval = 1,
        pollingInterval: TimeInterval = 60,
        pausesWhileBackgrounded: Bool = true,
        lifecycle: (any AppLifecycleObserver)? = nil,
        telemetryFlushInterval: TimeInterval = 0.05,
        logger: any ConfigDirectorLogger = ConsoleLogger(level: .off)
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
                logger: logger
            ),
            session: session,
            lifecycle: lifecycle ?? NotificationCenterLifecycleObserver(
                center: notifications,
                backgroundNotification: .testDidEnterBackground,
                foregroundNotification: .testWillEnterForeground
            ),
            telemetryOptions: TelemetryOptions(
                flushInterval: telemetryFlushInterval,
                initialFlushDelay: telemetryFlushInterval
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

    var telemetryRequests: [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.recorded(for: telemetryURL)
    }

    func telemetryReports() -> [TelemetryReport] {
        telemetryRequests.compactMap { request in
            request.body.flatMap { try? JSONDecoder().decode(TelemetryReport.self, from: Data($0.utf8)) }
        }
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

/// Keeps what the SDK logged, so a test can assert on a warning an application would see.
final class RecordingLogger: ConfigDirectorLogger {
    let level = ConfigDirectorLogLevel.debug

    private let messages = Locked<[String]>([])

    var recorded: [String] {
        messages.withLock { $0 }
    }

    func log(_: ConfigDirectorLogLevel, message: String, error _: (any Error)?) {
        messages.withLock { $0.append(message) }
    }
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

/// A telemetry report, read back from the request the SDK posted.
struct TelemetryReport: Decodable, Sendable {
    struct Aggregated: Decodable, Sendable {
        var startTime: String
        var endTime: String
        var count: Int
        var event: ReportedEvaluation
    }

    struct ReportedValue: Decodable, Sendable {
        var value: String?
        var valueId: String?
        var type: String?
    }

    struct ReportedEvaluation: Decodable, Sendable {
        var contextId: String?
        var key: String
        var type: String?
        var defaultValue: ReportedValue
        var requestedType: String
        var evaluatedValue: ReportedValue
        var evaluatedValueId: String?
        var usedDefault: Bool
        var evaluationReason: String
    }

    struct Events: Decodable, Sendable {
        var evaluatedConfig: [Aggregated]
    }

    struct Dropped: Decodable, Sendable {
        var evaluatedConfig: Int
    }

    struct Meta: Decodable, Sendable {
        var sdkName: String
        var sdkVersion: String
    }

    var clientSdkKey: String
    var metaContext: Meta
    var context: SentPayload.Context?
    var aggregatedEvents: Events
    var droppedEvents: Dropped

    /// The reported evaluations, keyed by config, so a test can assert on one without depending on
    /// the order the others happen to come back in.
    func evaluations(of key: String) -> [Aggregated] {
        aggregatedEvents.evaluatedConfig.filter { $0.event.key == key }
    }
}
