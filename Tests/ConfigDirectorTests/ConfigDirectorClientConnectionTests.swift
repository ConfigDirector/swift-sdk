import ConfigDirector
import Foundation
import Testing

/// Exercises how the client connects, reconnects, and disconnects through the public API against a
/// stubbed ConfigDirector server, with nothing inside the SDK replaced.
struct ConfigDirectorClientConnectionTests {
    @Test func rejectsABlankClientSDKKey() {
        #expect(throws: ConfigDirectorError.missingClientSDKKey) {
            try ConfigDirectorClient(clientSDKKey: "   ", options: .test())
        }
    }

    /// The compiler is the assertion: `error` is a `ConfigDirectorError`, not an `any Error` that
    /// would have to be cast before it could be compared.
    @Test func failsToBeCreatedWithATypedError() {
        do {
            _ = try ConfigDirectorClient(clientSDKKey: "", options: .test())
            Issue.record("expected a blank SDK key to be rejected")
        } catch {
            #expect(error == .missingClientSDKKey)
        }
    }

    @Test func closesItselfWhenReleased() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)

        do {
            let client = try fixture.makeClient()
            await client.initialize()
            #expect(client.isReady)
        }

        #expect(
            await waitUntil { fixture.streamDisconnections == 1 },
            "a released client left its connection open"
        )
    }

    @Test func warnsWhenTheBaseURLWouldSendTheSDKKeyInPlainText() throws {
        let logger = RecordingLogger()
        var options = ConfigDirectorClientOptions.test()
        options.connection.baseURL = URL(string: "http://example.test")
        options.logger = logger

        let client = try ConfigDirectorClient(clientSDKKey: "sdk-key", options: options)
        defer { client.close() }

        #expect(logger.recorded.contains { $0.contains("not HTTPS") })
    }

    @Test func doesNotWarnAboutAnHTTPSBaseURL() throws {
        let logger = RecordingLogger()
        var options = ConfigDirectorClientOptions.test()
        options.connection.baseURL = URL(string: "https://example.test")
        options.logger = logger

        let client = try ConfigDirectorClient(clientSDKKey: "sdk-key", options: options)
        defer { client.close() }

        #expect(logger.recorded.contains { $0.contains("not HTTPS") } == false)
    }

    @Test func rejectsABaseURLThatIsNotAbsolute() throws {
        let baseURL = try #require(URL(string: "/client"))
        var options = ConfigDirectorClientOptions.test()
        options.connection.baseURL = baseURL

        #expect(throws: ConfigDirectorError.invalidBaseURL(baseURL)) {
            try ConfigDirectorClient(clientSDKKey: "sdk-key", options: options)
        }
    }

    @Test func sendsTheSDKKeyContextAndSDKMetadataToTheServer() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }

        await client.initialize(context: ConfigDirectorContext(id: "user-123", name: "Ada"))

        let request = try #require(fixture.streamRequests.first)
        #expect(request.method == "POST")

        let payload = try #require(request.payload)
        #expect(payload.clientSdkKey == "sdk-key")
        #expect(payload.givenContext.id == "user-123")
        #expect(payload.givenContext.name == "Ada")
        #expect(payload.metaContext.sdkName == "swift-client-sdk")
        #expect(payload.metaContext.sdkVersion.isEmpty == false)
        #expect(payload.metaContext.userAgent?.isEmpty == false)
    }

    @Test func updateContextReconnectsWithTheNewContext() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        let events = StreamReader(client.events)
        await client.updateContext(ConfigDirectorContext(id: "user-456", traits: ["plan": "pro"]))

        #expect(client.context?.id == "user-456")
        #expect(client.context?.traits == ["plan": .string("pro")])
        #expect(fixture.streamRequests.compactMap { $0.payload?.givenContext.id } == ["user-123", "user-456"])

        let ready = await events.next {
            if case .ready = $0 {
                true
            } else {
                false
            }
        }
        guard case let .ready(reason) = ready else {
            Issue.record("expected a ready event, got \(String(describing: ready))")
            return
        }
        #expect(reason == .contextUpdate)
    }

    @Test func initializationGivesUpWaitingWhenNoConfigStateArrives() async throws {
        let fixture = ClientFixture()
        fixture.serveStream()
        let client = try fixture.makeClient(timeout: 0.3)
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

    @Test func aRejectedConnectionLeavesTheClientUnready() async throws {
        let fixture = ClientFixture()
        fixture.rejectStream(statusCode: 401)
        let client = try fixture.makeClient()
        defer { client.close() }

        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        #expect(client.isReady == false)
        #expect(client.context == nil)
        #expect(fixture.streamRequests.count == 1, "an invalid SDK key must not be retried")
    }

    @Test func pauseNetworkDisconnectsAndResumeReconnects() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        client.pauseNetwork()
        #expect(client.isReady == false)
        #expect(await waitUntil { fixture.streamDisconnections == 1 })

        await client.resumeNetwork()
        #expect(client.isReady)
        #expect(fixture.streamRequests.compactMap { $0.payload?.givenContext.id } == ["user-123", "user-123"])
    }

    @Test func closeFinishesEveryStreamAndDisconnects() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        await client.initialize()

        let events = client.events
        let evaluations = client.evaluations
        let values = client.values(for: "dark-mode", default: false)
        let drained = Task {
            for await _ in events {}
            for await _ in evaluations {}
            for await _ in values {}
            return true
        }

        client.close()

        #expect(await withTimeout { await drained.value } == true)
        #expect(await waitUntil { fixture.streamDisconnections == 1 })
    }

    @Test func closingTwiceDisconnectsOnlyOnce() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        await client.initialize()

        client.close()
        client.close()

        #expect(await waitUntil { fixture.streamDisconnections == 1 })
        await settle(0.2)
        #expect(fixture.streamDisconnections == 1)
    }

    @Test func streamingModeAcceptsAnInfiniteTimeout() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient(timeout: .infinity)
        defer { client.close() }

        await client.initialize()

        #expect(client.isReady)
    }

    @Test func pollingModeAcceptsAnInfiniteTimeoutAndInterval() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet)
        let client = try fixture.makeClient(mode: .polling, timeout: .infinity, pollingInterval: .infinity)
        defer { client.close() }

        await client.initialize()
        await settle()

        #expect(client.isReady)
        #expect(fixture.pollRequests.count == 1)
    }

    @Test func pollingModeFetchesFromThePollingEndpoint() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet)
        let client = try fixture.makeClient(mode: .polling, pollingInterval: 0.05)
        defer { client.close() }

        await client.initialize()

        #expect(client.isReady)
        #expect(client.value(for: "dark-mode", default: false) == true)
        #expect(fixture.streamRequests.isEmpty)
    }

    @Test func pollingModePicksUpChangesOnTheInterval() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet, deltaConfigSet([ServedConfig("dark-mode", "boolean", "false")]))
        let client = try fixture.makeClient(mode: .polling, pollingInterval: 0.05)
        defer { client.close() }

        await client.initialize()
        #expect(client.value(for: "dark-mode", default: false) == true)

        #expect(await waitUntil { client.value(for: "dark-mode", default: true) == false })
        #expect(client.value(for: "welcome-message", default: "") == "Hello")
    }

    @Test func oneTimeModeFetchesOnConnectOnly() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet, deltaConfigSet([ServedConfig("dark-mode", "boolean", "false")]))
        let client = try fixture.makeClient(mode: .oneTime, pollingInterval: 0.05)
        defer { client.close() }

        await client.initialize()

        await settle(0.3)
        #expect(fixture.pollRequests.count == 1)
        #expect(client.value(for: "dark-mode", default: false) == true)
    }

    @Test func pollingModeAppliesTheNewContextWhenItsFirstFetchFailsTransiently() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet)
        let client = try fixture.makeClient(mode: .polling, pollingInterval: 0.05)
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "before"))

        StubURLProtocol.enqueue([.json("", statusCode: 503)], for: fixture.pollURL)
        fixture.servePolling(servedConfigSet)
        let events = StreamReader(client.events)

        await client.updateContext(ConfigDirectorContext(id: "after"))

        #expect(client.context?.id == "after")
        let contextUpdated = await events.next {
            if case .contextUpdated = $0 {
                true
            } else {
                false
            }
        }
        #expect(contextUpdated != nil)
        let ready = await events.next {
            if case .ready(.contextUpdate) = $0 {
                true
            } else {
                false
            }
        }
        #expect(ready != nil)
        #expect(fixture.pollRequests.last?.payload?.givenContext.id == "after")
    }

    @Test func oneTimeModeKeepsThePreviousContextWhenAnUpdateFails() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet)
        let client = try fixture.makeClient(mode: .oneTime)
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "before"))

        StubURLProtocol.enqueue([.json("", statusCode: 503)], for: fixture.pollURL)
        await client.updateContext(ConfigDirectorContext(id: "after"))

        #expect(client.context?.id == "before")
        #expect(client.value(for: "dark-mode", default: false) == true)
    }
}
