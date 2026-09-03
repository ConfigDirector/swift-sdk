import ConfigDirector
import Foundation
import Testing

/// Exercises config evaluation and watching through the public API against a stubbed ConfigDirector
/// server, with nothing inside the SDK replaced.
struct ConfigDirectorClientTests {
    @Test func servesDefaultsBeforeInitialization() throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }

        #expect(client.isReady == false)
        #expect(client.isInitializing == false)
        #expect(client.value(for: "dark-mode", default: false) == false)
        #expect(fixture.streamRequests.isEmpty)
    }

    @Test func reportsThatTheClientWasNotReadyYet() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        let evaluations = StreamReader(client.evaluations)

        _ = client.value(for: "dark-mode", default: false)

        let evaluation = try #require(await evaluations.next())
        #expect(evaluation.key == "dark-mode")
        #expect(evaluation.isDefaultValue)
        #expect(evaluation.reason == .clientNotReady)
    }

    @Test func servesConfigValuesTheServerSent() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
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
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        let evaluations = StreamReader(client.evaluations)
        #expect(client.value(for: "missing", default: "fallback") == "fallback")

        let evaluation = try #require(await evaluations.next())
        #expect(evaluation.reason == .configStateMissing)
    }

    @Test func publishesReadyConfigsUpdatedAndContextUpdated() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
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
        #expect(seenKeys?.sorted() == [
            "dark-mode",
            "discount-rate",
            "max-retries",
            "theme",
            "welcome-message",
        ])
        #expect(seenContext == ConfigDirectorContext(id: "user-123"))
    }

    @Test func lifecycleEventsSurviveABurstOfEvaluations() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }

        // Subscribed but not consumed yet, the way a view that has not been scheduled behaves.
        let events = StreamReader(client.events)

        await client.initialize()

        // What a handful of configs read from a SwiftUI body produces in a second or so.
        for _ in 0 ..< 300 {
            _ = client.value(for: "dark-mode", default: false)
        }

        let ready = await events.next(timeout: 1) {
            if case .ready = $0 {
                true
            } else {
                false
            }
        }
        #expect(ready != nil, "the ready event was evicted by evaluation events")
    }

    @Test func watchYieldsTheCurrentValueAndThenEveryChange() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }

        let values = StreamReader(client.values(for: "dark-mode", default: false))
        #expect(await values.next() == false)

        await client.initialize()
        #expect(await values.next() == true)

        fixture.pushToStream(deltaConfigSet([ServedConfig("dark-mode", "boolean", "false")]))
        #expect(await values.next() == false)
    }

    @Test func watchFallsBackWhenAFullUpdateNoLongerCarriesTheConfig() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        let values = StreamReader(client.values(for: "welcome-message", default: "fallback"))
        #expect(await values.next() == "Hello")

        fixture.pushToStream(configSetJSON([ServedConfig("dark-mode", "boolean", "false")]))
        #expect(await values.next() == "fallback")
    }

    @Test func watchDoesNotRepeatIdenticalValues() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        let collected = client.values(for: "welcome-message", default: "").collectUntilFinished()
        await settle()

        await client.initialize()
        await settle()

        fixture.pushToStream(deltaConfigSet([ServedConfig("welcome-message", "string", "Hello")]))
        await settle()

        fixture.pushToStream(deltaConfigSet([ServedConfig("welcome-message", "string", "Goodbye")]))
        await settle()

        client.close()
        #expect(await withTimeout { await collected.value } == ["", "Hello", "Goodbye"])
    }

    @Test func watchAlsoFollowsAJSONConfig() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        let fallback = Theme(primaryColor: "", cornerRadius: 0)

        let values = StreamReader(client.values(for: "theme", as: Theme.self, default: fallback))
        #expect(await values.next() == fallback)

        await client.initialize()
        #expect(await values.next() == Theme(primaryColor: "blue", cornerRadius: 8))
    }

    @Test func deltaUpdatesMergeIntoTheConfigsAlreadyReceived() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        fixture.pushToStream(deltaConfigSet([ServedConfig("max-retries", "integer", "9")]))

        #expect(await waitUntil { client.value(for: "max-retries", default: 0) == 9 })
        #expect(client.value(for: "welcome-message", default: "") == "Hello")
    }

    @Test func fullUpdatesReplaceTheConfigsAlreadyReceived() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        fixture.pushToStream(configSetJSON([ServedConfig("max-retries", "integer", "9")]))

        #expect(await waitUntil { client.value(for: "max-retries", default: 0) == 9 })
        #expect(client.value(for: "welcome-message", default: "fallback") == "fallback")
    }
}
