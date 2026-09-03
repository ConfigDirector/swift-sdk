import ConfigDirector
import Foundation
import Testing

/// Hammers the client from many tasks at once. Run under the thread sanitizer, this is what says the
/// lock-protected state holds up; run without, it still catches a crash or a torn read.
///
/// Every stream a task consumes is subscribed before the group starts. One created inside the group
/// could be registered after everything it was waiting for has already been published, and then wait
/// forever.
struct ConfigDirectorClientConcurrencyTests {
    private static let fallbackTheme = Theme(primaryColor: "red", cornerRadius: 0)

    @Test func servesConsistentValuesWhileBeingReadFromEverywhereAtOnce() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        let evaluations = client.evaluations
        let watched = client.values(for: "dark-mode", default: false)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var consistent = true
                    for _ in 0 ..< 250 {
                        consistent = consistent
                            && client.value(for: "dark-mode", default: false)
                            && client.value(for: "welcome-message", default: "") == "Hello"
                            && client.value(for: "max-retries", default: 0) == 3
                            && client.value(for: "theme", as: Theme.self, default: Self.fallbackTheme)
                            == Theme(primaryColor: "blue", cornerRadius: 8)
                    }
                    return consistent
                }
            }

            group.addTask {
                await withTimeout { await Array(watched.prefix(1)).count == 1 } ?? false
            }

            group.addTask {
                await withTimeout { await Array(evaluations.prefix(20)).count == 20 } ?? false
            }

            #expect(await group.allSatisfy(\.self))
        }

        #expect(client.isReady)
        #expect(client.value(for: "dark-mode", default: false) == true)
    }

    @Test func survivesUpdatesArrivingWhileConfigsAreBeingRead() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        let watched = client.values(for: "max-retries", default: -1)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for round in 0 ..< 40 {
                    fixture.pushToStream(
                        deltaConfigSet([ServedConfig("max-retries", "integer", String(round))])
                    )
                    await settle(0.002)
                }
            }

            for _ in 0 ..< 6 {
                group.addTask {
                    for _ in 0 ..< 300 {
                        _ = client.value(for: "max-retries", default: -1)
                        _ = client.value(for: "welcome-message", default: "")
                    }
                }
            }

            group.addTask {
                _ = await withTimeout { await Array(watched.prefix(2)).count }
            }
        }

        #expect(client.value(for: "welcome-message", default: "") == "Hello")
    }

    @Test func toleratesPausingAndResumingWhileConfigsAreBeingRead() async throws {
        let fixture = ClientFixture()
        for _ in 0 ..< 6 {
            fixture.serveStream(servedConfigSet)
        }
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0 ..< 5 {
                    client.pauseNetwork()
                    await client.resumeNetwork()
                }
            }

            for _ in 0 ..< 4 {
                group.addTask {
                    for _ in 0 ..< 300 {
                        _ = client.value(for: "dark-mode", default: false)
                    }
                }
            }
        }

        #expect(client.isReady)
    }

    @Test func closingWhileConfigsAreBeingReadFinishesEveryStream() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        await client.initialize()

        let watched = client.values(for: "dark-mode", default: false).collectUntilFinished()
        let events = client.events.collectUntilFinished()
        let evaluations = client.evaluations.collectUntilFinished()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask {
                    for _ in 0 ..< 200 {
                        _ = client.value(for: "dark-mode", default: false)
                    }
                }
            }
            group.addTask {
                await settle(0.01)
                client.close()
            }
        }

        #expect(await withTimeout { await watched.value } != nil, "a watch stream was left open")
        #expect(await withTimeout { await events.value } != nil, "an event stream was left open")
        #expect(
            await withTimeout { await evaluations.value } != nil,
            "an evaluation stream was left open"
        )
    }

    @Test func overlappingContextUpdatesApplyInTheOrderTheyWereMade() async throws {
        let fixture = ClientFixture()
        fixture.servePolling(servedConfigSet)
        let client = try fixture.makeClient(mode: .polling, timeout: 0.2)
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "first"))

        StubURLProtocol.enqueue([.init(chunks: [], endsStream: false)], for: fixture.pollURL)
        fixture.servePolling(servedConfigSet)
        let events = StreamReader(client.events)

        async let slow: Void = client.updateContext(ConfigDirectorContext(id: "slow"))
        await settle(0.05)
        async let fast: Void = client.updateContext(ConfigDirectorContext(id: "fast"))
        _ = await (slow, fast)

        #expect(client.context?.id == "fast")
        #expect(fixture.pollRequests.map(\.payload?.givenContext.id) == ["first", "slow", "fast"])

        var updatedContexts: [String?] = []
        while let event = await events.next(timeout: 0.1) {
            if case let .contextUpdated(context) = event {
                updatedContexts.append(context?.id)
            }
        }
        #expect(updatedContexts == ["slow", "fast"])
    }
}
