@testable import ConfigDirector
import Foundation
import Testing

struct PollingTransportTests {
    private typealias Fixture = (fixture: TransportFixture, transport: PollingTransport)

    private func makeFixture(pollingInterval: TimeInterval = 60) -> TransportFixture {
        TransportFixture(path: "client/polling/v1", pollingInterval: pollingInterval)
    }

    private func makeTransport(pollingInterval: TimeInterval = 60) -> Fixture {
        let fixture = makeFixture(pollingInterval: pollingInterval)
        return (fixture, PollingTransport(options: fixture.options, onConfigSet: fixture.onConfigSet))
    }

    @Test func postsThePayloadAndDeliversConfigState() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.shutdown() }
        fixture.enqueue(.json(configSetJSON(greeting: "hello")))

        try await transport.connect(context: ConfigDirectorContext(id: "user-1"), timeout: 1)

        #expect(fixture.received.first?.configs["greeting"]?.value == "hello")

        let request = try #require(fixture.recorded.first)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeout == 1)

        let payload = try #require(request.payload)
        #expect(payload.clientSdkKey == "test-key")
        #expect(payload.instanceId == "instance-1")
        #expect(payload.givenContext.id == "user-1")
        #expect(payload.metaContext.sdkName == "swift-client-sdk")
        #expect(payload.lastUpdateTimestamp == nil)
    }

    @Test func refetchesOnThePollingInterval() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.shutdown() }
        for greeting in ["one", "two", "three", "four"] {
            fixture.enqueue(.json(configSetJSON(greeting: greeting)))
        }

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(await fixture.waitForConfigSets(3))
        #expect(fixture.received.map { $0.configs["greeting"]?.value }.prefix(3) == ["one", "two", "three"])
    }

    @Test func sendsTheTimestampFromThePreviousResponse() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.shutdown() }
        fixture.enqueue(
            .json(configSetJSON(greeting: "one", timestamp: "2026-08-29T00:00:00Z")),
            .json(configSetJSON(greeting: "two"))
        )

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(await fixture.waitForRequests(2))
        #expect(fixture.recorded.first?.payload?.lastUpdateTimestamp == nil)
        #expect(fixture.recorded.last?.payload?.lastUpdateTimestamp == "2026-08-29T00:00:00Z")
    }

    @Test func oneTimeFetchesOnConnectAndNeverPolls() async throws {
        let fixture = makeFixture(pollingInterval: 0.05)
        let transport = PollingTransport.oneTime(
            options: fixture.options,
            onConfigSet: fixture.onConfigSet
        )
        defer { transport.shutdown() }
        fixture.enqueue(.json(configSetJSON(greeting: "hello")), .json(configSetJSON(greeting: "again")))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        await settle(0.3)
        #expect(fixture.recorded.count == 1)
        #expect(fixture.received.count == 1)
    }

    @Test func throwsAndStopsPollingWhenTheServerRejectsTheRequest() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.shutdown() }
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

    @Test func ignoresLaterConnectAttemptsAfterAnUnrecoverableFailure() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.shutdown() }
        fixture.enqueue(.json("", statusCode: 403), .json(configSetJSON(greeting: "hello")))

        _ = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }
        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(fixture.recorded.count == 1)
        #expect(fixture.received.isEmpty)
    }

    @Test func keepsPollingAfterATransientFailure() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.shutdown() }
        fixture.enqueue(.json("", statusCode: 503), .json(configSetJSON(greeting: "hello")))

        let error = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }

        guard case let .connectionFailed(_, statusCode) = try #require(error) else {
            Issue.record("expected a connection failure, got \(String(describing: error))")
            return
        }
        #expect(statusCode == 503)

        #expect(await fixture.waitForConfigSets(1))
        #expect(fixture.received.first?.configs["greeting"]?.value == "hello")
    }

    @Test func throwsWhenTheResponseIsNotAConfigSet() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.shutdown() }
        fixture.enqueue(.json("not json"))

        _ = await #expect(throws: ConfigDirectorError.self) {
            try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        }

        #expect(fixture.received.isEmpty)
    }

    @Test func ignoresASuccessStatusThatCarriesNoConfigState() async throws {
        let (fixture, transport) = makeTransport()
        defer { transport.shutdown() }
        fixture.enqueue(.json("", statusCode: 204))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(fixture.received.isEmpty)
    }

    @Test func closeStopsPolling() async throws {
        let (fixture, transport) = makeTransport(pollingInterval: 0.05)
        defer { transport.shutdown() }
        fixture.enqueue(.json(configSetJSON(greeting: "hello")))

        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)
        transport.close()

        await settle(0.3)
        #expect(fixture.recorded.count == 1)
    }

    @Test func doesNotConnectAfterShutdown() async throws {
        let (fixture, transport) = makeTransport()
        fixture.enqueue(.json(configSetJSON(greeting: "hello")))

        transport.shutdown()
        try await transport.connect(context: ConfigDirectorContext(), timeout: 1)

        #expect(fixture.recorded.isEmpty)
    }
}
