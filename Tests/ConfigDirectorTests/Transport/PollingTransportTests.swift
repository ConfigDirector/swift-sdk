@testable import ConfigDirector
import Foundation
import Testing

struct PollingTransportTests {
    private typealias Fixture = (fixture: TransportFixture, transport: PollingTransport)

    private func makeTransport(pollingInterval: TimeInterval = 60) -> Fixture {
        let fixture = TransportFixture(path: "client/polling/v1", pollingInterval: pollingInterval)
        return (fixture, PollingTransport(options: fixture.options, onConfigSet: fixture.onConfigSet))
    }

    @Test func postsThePayloadAndDeliversConfigState() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.json(configSetJSON(greeting: "hello")))

        try await transport.connect(context: ConfigDirectorContext(id: "user-1"), timeout: 1)

        #expect(fixture.received.first?.configs["greeting"]?.value == "hello")

        let request = try #require(fixture.recorded.first)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeout == 1)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

        let payload = try #require(request.payload)
        #expect(payload.clientSdkKey == "test-key")
        #expect(payload.instanceId == "instance-1")
        #expect(payload.givenContext.id == "user-1")
        #expect(payload.metaContext.sdkName == "swift-client-sdk")
        #expect(payload.lastUpdateTimestamp == nil)
    }

    @Test func refetchesOnThePollingInterval() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        for greeting in ["one", "two", "three", "four"] {
            fixture.enqueue(.json(configSetJSON(greeting: greeting)))
        }

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(await fixture.waitForConfigSets(3))
        #expect(fixture.received.map { $0.configs["greeting"]?.value }.prefix(3) == ["one", "two", "three"])
    }

    @Test func sendsTheTimestampFromThePreviousResponse() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        fixture.enqueue(
            .json(configSetJSON(greeting: "one", timestamp: "2026-08-29T00:00:00Z")),
            .json(configSetJSON(greeting: "two"))
        )

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(await fixture.waitForRequests(2))
        #expect(fixture.recorded.first?.payload?.lastUpdateTimestamp == nil)
        #expect(fixture.recorded.last?.payload?.lastUpdateTimestamp == "2026-08-29T00:00:00Z")
    }

    @Test func throwsAndStopsPollingWhenTheServerRejectsTheRequest() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        fixture.enqueue(.json("invalid client sdk key", statusCode: 401))

        let error = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }

        guard case let .connectionFailed(message, statusCode) = try #require(error) else {
            Issue.record("expected a connection failure, got \(String(describing: error))")
            return
        }
        #expect(statusCode == 401)
        #expect(message.contains("invalid client sdk key"))

        await settle(0.3)
        #expect(fixture.recorded.count == 1, "a rejected request must not be retried")
    }

    @Test func truncatesALongResponseBodyInTheErrorMessage() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.json(String(repeating: "x", count: 1000), statusCode: 400))

        let error = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }

        guard case let .connectionFailed(message, _) = try #require(error) else {
            Issue.record("expected a connection failure, got \(String(describing: error))")
            return
        }
        #expect(message.contains(String(repeating: "x", count: 200) + "…"))
        #expect(message.contains(String(repeating: "x", count: 201)) == false)
    }

    @Test func rejectsLaterConnectAttemptsAfterAnUnrecoverableFailure() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.json("", statusCode: 403), .json(configSetJSON(greeting: "hello")))

        _ = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }
        let error = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }

        guard case let .connectionFailed(message, statusCode) = try #require(error) else {
            Issue.record("expected a connection failure, got \(String(describing: error))")
            return
        }
        #expect(statusCode == 403)
        #expect(message.contains("unrecoverable"))
        #expect(fixture.recorded.count == 1)
        #expect(fixture.received.isEmpty)
    }

    @Test func keepsPollingAfterATransientFailureWithoutThrowing() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        fixture.enqueue(.json("", statusCode: 503), .json(configSetJSON(greeting: "hello")))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(await fixture.waitForConfigSets(1))
        #expect(fixture.received.first?.configs["greeting"]?.value == "hello")
    }

    @Test func deliversNothingAndKeepsPollingWhenTheResponseIsNotAConfigSet() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        fixture.enqueue(.json("not json"), .json(configSetJSON(greeting: "hello")))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(fixture.received.isEmpty)
        #expect(await fixture.waitForConfigSets(1))
        #expect(fixture.received.first?.configs["greeting"]?.value == "hello")
    }

    @Test func ignoresASuccessStatusThatCarriesNoConfigState() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.close() }
        fixture.enqueue(.json("", statusCode: 204))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(fixture.received.isEmpty)
    }

    @Test func overlappingConnectsLeaveASinglePollingLoop() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        StubURLProtocol.enqueue(
            Array(repeating: .json(configSetJSON(greeting: "hello")), count: 40),
            for: fixture.endpoint
        )

        async let first: Void = transport.connect(context: ConfigDirectorContext(id: "a"), timeout: 1)
        async let second: Void = transport.connect(context: ConfigDirectorContext(id: "b"), timeout: 1)
        _ = try await (first, second)

        transport.disconnect()
        await settle(0.05)
        let requestsWhenDisconnected = fixture.recorded.count
        await settle(0.3)
        #expect(fixture.recorded.count == requestsWhenDisconnected, "a polling loop survived disconnect")
    }

    @Test func disconnectingDuringConnectPreventsPolling() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        fixture.enqueue(.init(chunks: [], endsStream: false))
        StubURLProtocol.enqueue(
            Array(repeating: .json(configSetJSON(greeting: "hello")), count: 40),
            for: fixture.endpoint
        )

        let connecting = Task { try await transport.connect(context: ConfigDirectorContext(), timeout: 0.2) }
        #expect(await fixture.waitForRequests(1))
        transport.disconnect()
        try await connecting.value

        await settle(0.3)
        #expect(fixture.recorded.count == 1, "polling started after the transport was disconnected")
    }

    @Test func disconnectingStopsPolling() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.close() }
        fixture.enqueue(.json(configSetJSON(greeting: "hello")))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        transport.disconnect()

        await settle(0.3)
        #expect(fixture.recorded.count == 1)
    }

    @Test func doesNotConnectAfterBeingClosed() async throws {
        let (fixture, transport) = makeTransport()
        fixture.enqueue(.json(configSetJSON(greeting: "hello")))

        transport.close()
        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(fixture.recorded.isEmpty)
    }
}
