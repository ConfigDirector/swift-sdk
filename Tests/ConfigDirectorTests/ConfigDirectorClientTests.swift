@testable import ConfigDirector
import Foundation
import Testing

struct ConfigDirectorClientTests {
    private static let served = ConfigSet.make([
        .make(key: "dark-mode", type: .boolean, value: "true", valueID: "on"),
        .make(key: "welcome-message", type: .string, value: "Hello"),
        .make(key: "max-retries", type: .integer, value: "3"),
        .make(key: "discount-rate", type: .float, value: "0.15"),
        .make(key: "theme", type: .json, value: #"{"primaryColor":"blue","cornerRadius":8}"#),
    ])

    private func makeClient(
        transport: FakeTransport,
        timeout: TimeInterval = 1
    ) throws -> ConfigDirectorClient {
        try ConfigDirectorClient(
            clientSDKKey: "sdk-key",
            options: .test(timeout: timeout),
            transportFactory: transport.factory
        )
    }

    @Test func rejectsABlankClientSDKKey() {
        #expect(throws: ConfigDirectorError.missingClientSDKKey) {
            try ConfigDirectorClient(clientSDKKey: "   ", options: .test())
        }
    }

    @Test func rejectsABaseURLThatIsNotAbsolute() throws {
        let baseURL = try #require(URL(string: "/client"))
        var options = ConfigDirectorClientOptions.test()
        options.connection.baseURL = baseURL

        #expect(throws: ConfigDirectorError.invalidBaseURL(baseURL)) {
            try ConfigDirectorClient(clientSDKKey: "sdk-key", options: options)
        }
    }

    @Test func servesDefaultsBeforeInitialization() throws {
        let client = try makeClient(transport: FakeTransport(deliveringOnConnect: Self.served))
        defer { client.close() }

        #expect(client.isReady == false)
        #expect(client.isInitializing == false)
        #expect(client.value(for: "dark-mode", default: false) == false)
    }

    @Test func reportsThatTheClientWasNotReadyYet() async throws {
        let client = try makeClient(transport: FakeTransport(deliveringOnConnect: Self.served))
        defer { client.close() }
        let events = StreamReader(client.events)

        _ = client.value(for: "dark-mode", default: false)

        let event = await events.next()
        guard case let .configEvaluated(evaluation) = event else {
            Issue.record("expected a configEvaluated event, got \(String(describing: event))")
            return
        }
        #expect(evaluation.key == "dark-mode")
        #expect(evaluation.isDefaultValue)
        #expect(evaluation.reason == .clientNotReady)
    }

    @Test func servesConfigValuesOnceInitialized() async throws {
        let client = try makeClient(transport: FakeTransport(deliveringOnConnect: Self.served))
        defer { client.close() }

        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        #expect(client.isReady)
        #expect(client.isInitializing == false)
        #expect(client.context == ConfigDirectorContext(id: "user-123"))
        #expect(client.value(for: "dark-mode", default: false) == true)
        #expect(client.value(for: "welcome-message", default: "") == "Hello")
        #expect(client.value(for: "max-retries", default: 0) == 3)
        #expect(client.value(for: "discount-rate", default: 0.0) == 0.15)
        #expect(
            client.value(for: "theme", as: Theme.self, default: Theme(primaryColor: "", cornerRadius: 0))
                == Theme(primaryColor: "blue", cornerRadius: 8)
        )
    }

    @Test func reportsAKeyTheServerDidNotSend() async throws {
        let client = try makeClient(transport: FakeTransport(deliveringOnConnect: Self.served))
        defer { client.close() }
        await client.initialize()

        let events = StreamReader(client.events)
        #expect(client.value(for: "missing", default: "fallback") == "fallback")

        let event = await events.next()
        guard case let .configEvaluated(evaluation) = event else {
            Issue.record("expected a configEvaluated event, got \(String(describing: event))")
            return
        }
        #expect(evaluation.reason == .configStateMissing)
    }

    @Test func publishesReadyConfigsUpdatedAndContextUpdated() async throws {
        let client = try makeClient(transport: FakeTransport(deliveringOnConnect: Self.served))
        defer { client.close() }
        let events = StreamReader(client.events)

        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        var seenReason: ConnectReason?
        var seenKeys: [String]?
        var seenContext: ConfigDirectorContext??
        for _ in 0 ..< 3 {
            switch await events.next() {
            case let .ready(reason): seenReason = reason
            case let .configsUpdated(keys): seenKeys = keys
            case let .contextUpdated(context): seenContext = context
            default: break
            }
        }

        #expect(seenReason == .initialization)
        #expect(seenKeys?.sorted() == Self.served.configs.keys.sorted())
        #expect(seenContext == ConfigDirectorContext(id: "user-123"))
    }

    @Test func watchYieldsTheCurrentValueAndThenEveryChange() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        defer { client.close() }

        let values = StreamReader(client.values(for: "dark-mode", default: false))
        #expect(await values.next() == false)

        await client.initialize()
        #expect(await values.next() == true)

        transport.deliver(.make([.make(key: "dark-mode", type: .boolean, value: "false")], kind: .delta))
        #expect(await values.next() == false)
    }

    @Test func watchDoesNotRepeatIdenticalValues() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        let collected = client.values(for: "welcome-message", default: "").collectUntilFinished()
        await settle()

        await client.initialize()
        await settle()

        transport.deliver(.make([.make(key: "welcome-message", type: .string, value: "Hello")], kind: .delta))
        await settle()

        transport.deliver(.make(
            [.make(key: "welcome-message", type: .string, value: "Goodbye")],
            kind: .delta
        ))
        await settle()

        client.close()
        #expect(await withTimeout { await collected.value } == ["", "Hello", "Goodbye"])
    }

    @Test func watchAlsoFollowsAJSONConfig() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        defer { client.close() }
        let fallback = Theme(primaryColor: "", cornerRadius: 0)

        let values = StreamReader(client.values(for: "theme", as: Theme.self, default: fallback))
        #expect(await values.next() == fallback)

        await client.initialize()
        #expect(await values.next() == Theme(primaryColor: "blue", cornerRadius: 8))
    }

    @Test func updateContextReconnectsAndReevaluates() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        let events = StreamReader(client.events)
        await client.updateContext(ConfigDirectorContext(id: "user-456", traits: ["plan": "pro"]))

        #expect(client.context?.id == "user-456")
        #expect(client.context?.traits == ["plan": .string("pro")])
        #expect(transport.recording.connectedContexts.map(\.id) == ["user-123", "user-456"])
        let ready = await events.next {
            if case .ready = $0 {
                true
            } else {
                false
            }
        }
        #expect(ready != nil)
        guard case let .ready(reason) = ready else { return }
        #expect(reason == .contextUpdate)
    }

    @Test func deltaUpdatesMergeIntoTheConfigsAlreadyReceived() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        defer { client.close() }
        await client.initialize()

        transport.deliver(.make([.make(key: "max-retries", type: .integer, value: "9")], kind: .delta))

        #expect(client.value(for: "max-retries", default: 0) == 9)
        #expect(client.value(for: "welcome-message", default: "") == "Hello")
    }

    @Test func fullUpdatesReplaceTheConfigsAlreadyReceived() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        defer { client.close() }
        await client.initialize()

        transport.deliver(.make([.make(key: "max-retries", type: .integer, value: "9")], kind: .full))

        #expect(client.value(for: "max-retries", default: 0) == 9)
        #expect(client.value(for: "welcome-message", default: "fallback") == "fallback")
    }

    @Test func initializationGivesUpWaitingWhenNoConfigStateArrives() async throws {
        let client = try makeClient(transport: FakeTransport(), timeout: 0.3)
        defer { client.close() }

        let startedAt = Date()
        await client.initialize()
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed >= 0.25)
        #expect(elapsed < 2)
        #expect(client.isReady == false)
        #expect(client.isInitializing == false)
        #expect(client.value(for: "dark-mode", default: false) == false)
    }

    @Test func aFailedConnectionLeavesTheClientUnready() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        transport.failNextConnect(with: ConfigDirectorError.connectionFailed(message: "no", statusCode: 401))
        let client = try makeClient(transport: transport)
        defer { client.close() }

        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        #expect(client.isReady == false)
        #expect(client.context == nil)
    }

    @Test func pauseNetworkClosesTheConnectionAndResumeReconnects() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        client.pauseNetwork()
        #expect(transport.recording.closeCount == 1)
        #expect(client.isReady == false)

        await client.resumeNetwork()
        #expect(client.isReady)
        #expect(transport.recording.connectedContexts.map(\.id) == ["user-123", "user-123"])
    }

    @Test func closeFinishesEveryStreamAndReleasesTheTransport() async throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)
        await client.initialize()

        let events = client.events
        let values = client.values(for: "dark-mode", default: false)
        let drained = Task {
            for await _ in events {}
            for await _ in values {}
            return true
        }

        client.close()

        #expect(await withTimeout { await drained.value } == true)
        #expect(transport.recording.shutdownCount == 1)
    }

    @Test func closingTwiceReleasesTheTransportOnlyOnce() throws {
        let transport = FakeTransport(deliveringOnConnect: Self.served)
        let client = try makeClient(transport: transport)

        client.close()
        client.close()

        #expect(transport.recording.shutdownCount == 1)
    }

    @Test func servesTheStubbedConfigSetThroughThePublicAPI() async throws {
        let client = try ConfigDirectorClient(clientSDKKey: "sdk-key", options: .test())
        defer { client.close() }

        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        #expect(client.isReady)
        #expect(client.value(for: "temporary-feature-flag", default: false) == true)
        #expect(client.value(for: "permanent-kill-switch", default: true) == false)
        #expect(client.value(for: "integer-config", default: 0) == 42)
        #expect(client.value(for: "day-of-the-week-config", default: "") == "Wednesday")
        #expect(
            client.value(
                for: "json-value-config",
                as: Greeting.self,
                default: Greeting(greeting: "", retries: 0)
            )
                == Greeting(greeting: "Hello from ConfigDirector", retries: 3)
        )
    }
}
