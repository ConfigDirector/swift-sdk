@testable import ConfigDirector
import Foundation
import Testing

struct StreamingTransportTests {
    private func makeTransport(
        retryDelay: @escaping @Sendable (Int) -> TimeInterval = { _ in 0.01 }
    ) -> (fixture: TransportFixture, transport: StreamingTransport) {
        let fixture = TransportFixture(path: "client/sse/v1", retryDelay: retryDelay)
        return (fixture, StreamingTransport(options: fixture.options, onConfigSet: fixture.onConfigSet))
    }

    private func event(_ configSet: String) -> String {
        "data: \(configSet)\n\n"
    }

    @Test func postsThePayloadAndDeliversConfigStateFromTheStream() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.init(chunks: [event(configSetJSON(greeting: "hello"))], endsStream: false))

        try await transport.connect(context: ConfigDirectorContext(id: "user-1"), timeout: 1)

        #expect(await fixture.waitForConfigSets(1))
        #expect(fixture.received.first?.configs["greeting"]?.value == "hello")

        let request = try #require(fixture.recorded.first)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "text/event-stream")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

        let payload = try #require(request.payload)
        #expect(payload.clientSdkKey == "test-key")
        #expect(payload.instanceId == "instance-1")
        #expect(payload.givenContext.id == "user-1")
        #expect(payload.metaContext.sdkName == "swift-client-sdk")
        #expect(payload.metaContext.userAgent == "iOS")
        #expect(payload.lastUpdateTimestamp == nil)
    }

    @Test func returnsAsSoonAsTheStreamOpensRatherThanWaitingForConfigState() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.init(endsStream: false))

        let startedAt = Date()
        try await transport.connect(context: ConfigDirectorContext(), timeout: 5)

        #expect(Date().timeIntervalSince(startedAt) < 1, "connect waited for more than the stream opening")
        #expect(fixture.received.isEmpty)
        #expect(fixture.recorded.count == 1)
    }

    @Test func throwsAndStopsWhenTheServerRejectsTheConnection() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.init(statusCode: 401))

        let error = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }

        guard case let .connectionFailed(_, statusCode) = try #require(error) else {
            Issue.record("expected a connection failure, got \(String(describing: error))")
            return
        }
        #expect(statusCode == 401)

        await settle(0.2)
        #expect(fixture.recorded.count == 1, "a rejected connection must not be retried")
    }

    @Test func retriesAfterATransientFailure() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(
            .init(statusCode: 500),
            .init(chunks: [event(configSetJSON(greeting: "hello"))], endsStream: false)
        )

        try await transport.connect(context: ConfigDirectorContext(), timeout: 2)

        #expect(await fixture.waitForConfigSets(1))
        #expect(fixture.recorded.count == 2)
    }

    @Test func returnsWithoutThrowingWhenTheConnectionNeverOpensInTime() async throws {
        let (fixture, transport) = makeTransport(retryDelay: { _ in 5 })
        defer { transport.close() }
        fixture.enqueue(.init(statusCode: 500), .init(statusCode: 500))

        let startedAt = Date()
        try await transport.connect(context: ConfigDirectorContext(), timeout: 0.2)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 2, "connect waited past its timeout")
        #expect(fixture.received.isEmpty)
    }

    @Test func keepsStreamingWhenAConfigSetCannotBeParsed() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.init(
            chunks: [event("not json"), event(configSetJSON(greeting: "hello"))],
            endsStream: false
        ))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(await fixture.waitForConfigSets(1))
        await settle(0.1)
        #expect(fixture.received.map { $0.configs["greeting"]?.value } == ["hello"])
    }

    @Test func reconnectsWhenTheStreamDropsAndKeepsDelivering() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(
            .init(chunks: [event(configSetJSON(greeting: "first"))]),
            .init(chunks: [event(configSetJSON(greeting: "second"))], endsStream: false)
        )

        try await transport.connect(context: ConfigDirectorContext(), timeout: 2)

        #expect(await fixture.waitForConfigSets(2))
        #expect(fixture.received.map { $0.configs["greeting"]?.value } == ["first", "second"])
    }

    @Test func disconnectingStopsTheConnectionFromReconnecting() async throws {
        let (fixture, transport) = makeTransport(retryDelay: { _ in 0.2 })
        defer { transport.close() }
        fixture.enqueue(.init(chunks: [event(configSetJSON(greeting: "first"))]))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 2)
        transport.disconnect()

        await settle(0.8)
        #expect(fixture.recorded.count == 1)
    }

    @Test func connectsAgainAfterBeingDisconnected() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(
            .init(endsStream: false),
            .init(chunks: [event(configSetJSON(greeting: "hello"))], endsStream: false)
        )

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        transport.disconnect()
        try await transport.connect(context: ConfigDirectorContext(id: "user-2"), timeout: 1)

        #expect(await fixture.waitForConfigSets(1))
        #expect(fixture.recorded.count == 2)
        #expect(fixture.recorded.last?.payload?.givenContext.id == "user-2")
    }

    @Test func releasesThePreviousStreamWhenConnectingAgain() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.init(endsStream: false), .init(endsStream: false))

        try await transport.connect(context: ConfigDirectorContext(id: "user-1"), timeout: 1)
        try await transport.connect(context: ConfigDirectorContext(id: "user-2"), timeout: 1)

        #expect(await waitUntil { fixture.cancelled == 1 }, "the first stream was left connected")
        #expect(fixture.recorded.count == 2)
    }

    @Test func doesNotConnectAfterBeingClosed() async throws {
        let (fixture, transport) = makeTransport()
        fixture.enqueue(.init(endsStream: false))

        transport.close()
        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        await settle(0.2)
        #expect(fixture.recorded.isEmpty)
    }
}
