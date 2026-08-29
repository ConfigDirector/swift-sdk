@testable import ConfigDirector
import Foundation
import Testing

/// Exercises what the client does as the app leaves and returns to the foreground, driven through
/// the notifications the platform posts.
struct ConfigDirectorClientLifecycleTests {
    @Test func pausesTheConnectionWhenTheAppEntersTheBackground() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        fixture.enterBackground()

        #expect(client.isReady == false)
        #expect(await waitUntil { fixture.streamDisconnections == 1 })
        #expect(client.value(for: "dark-mode", default: false) == true, "config state is kept while paused")
    }

    @Test func resumesTheConnectionWhenTheAppReturnsToTheForeground() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        fixture.enterBackground()
        #expect(await waitUntil { client.isReady == false })

        fixture.returnToForeground()

        #expect(await waitUntil { client.isReady })
        #expect(fixture.streamRequests.compactMap { $0.payload?.givenContext.id } == ["user-123", "user-123"])
    }

    @Test func staysConnectedWhenPausingWhileBackgroundedIsOff() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient(pausesWhileBackgrounded: false)
        defer { client.close() }
        await client.initialize()

        fixture.enterBackground()

        await settle(0.2)
        #expect(client.isReady)
        #expect(fixture.streamDisconnections == 0)
    }

    @Test func doesNotConnectWhenTheAppIsBackgroundedBeforeTheClientEverConnected() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }

        fixture.enterBackground()
        fixture.returnToForeground()

        await settle(0.2)
        #expect(fixture.streamRequests.isEmpty)
        #expect(client.isReady == false)
    }

    @Test func doesNotResumeAConnectionItDidNotPause() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        client.pauseNetwork()
        fixture.returnToForeground()

        await settle(0.2)
        #expect(client.isReady == false)
        #expect(fixture.streamRequests.count == 1)
    }

    @Test func pausesOnceNoMatterHowOftenTheAppIsBackgrounded() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        fixture.enterBackground()
        #expect(await waitUntil { fixture.streamDisconnections == 1 })
        fixture.enterBackground()
        fixture.returnToForeground()

        #expect(await waitUntil { client.isReady })
        await settle(0.2)
        #expect(fixture.streamRequests.count == 2)
        #expect(fixture.streamDisconnections == 1)
    }

    @Test func stopsObservingTheAppLifecycleOnceClosed() throws {
        let fixture = ClientFixture()
        let observer = RecordingLifecycleObserver()
        let client = try fixture.makeClient(lifecycle: observer)

        #expect(observer.isObserving)

        client.close()

        #expect(observer.isObserving == false)
    }

    @Test func neverObservesTheAppLifecycleWhenPausingWhileBackgroundedIsOff() throws {
        let fixture = ClientFixture()
        let observer = RecordingLifecycleObserver()
        let client = try fixture.makeClient(pausesWhileBackgrounded: false, lifecycle: observer)
        defer { client.close() }

        #expect(observer.isObserving == false)
    }

    @Test func ignoresTheAppLifecycleOnceClosed() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        await client.initialize()

        client.close()
        #expect(await waitUntil { fixture.streamDisconnections == 1 })

        fixture.enterBackground()
        fixture.returnToForeground()

        await settle(0.2)
        #expect(fixture.streamRequests.count == 1)
        #expect(client.isReady == false)
    }
}
