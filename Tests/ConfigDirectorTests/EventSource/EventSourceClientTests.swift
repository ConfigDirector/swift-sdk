@testable import ConfigDirector
import Foundation
import Testing

struct EventSourceClientTests {
    /// One client under test, on a URL of its own so the stub keeps it apart from every other test.
    private struct Fixture {
        let client: EventSourceClient
        let url: URL

        func enqueue(_ responses: StubURLProtocol.Response...) {
            StubURLProtocol.enqueue(responses, for: url)
        }

        var recorded: [StubURLProtocol.RecordedRequest] {
            StubURLProtocol.recorded(for: url)
        }
    }

    private func makeFixture(
        configure: (inout EventSourceClient.Configuration) -> Void = { _ in }
    ) -> Fixture {
        let url = URL(string: "https://example.test/client/sse/v1/\(UUID().uuidString)")!
        var configuration = EventSourceClient.Configuration(url: url)
        configuration.reconnectDelay = { _ in 0.01 }
        configure(&configuration)

        return Fixture(
            client: EventSourceClient(configuration: configuration, session: StubURLProtocol.makeSession()),
            url: url
        )
    }

    private func collect(
        _ reader: StreamReader<EventSourceClient.Event>,
        messages wanted: Int
    ) async -> (messages: [EventSourceMessage], opens: Int) {
        var messages: [EventSourceMessage] = []
        var opens = 0

        while messages.count < wanted, let event = await reader.next() {
            switch event {
            case .open: opens += 1
            case let .message(message): messages.append(message)
            default: break
            }
        }

        return (messages, opens)
    }

    @Test func deliversMessagesFromTheServer() async {
        let fixture = makeFixture()
        let client = fixture.client
        fixture.enqueue(.init(chunks: ["data: one\n\n", "data: two\n\n"], endsStream: false))
        defer { client.close() }

        let reader = StreamReader(client.start())
        let (messages, opens) = await collect(reader, messages: 2)

        #expect(opens == 1)
        #expect(messages == [EventSourceMessage(data: "one"), EventSourceMessage(data: "two")])
        #expect(client.readyState == .open)
    }

    @Test func deliversAMessageSplitAcrossReads() async {
        let fixture = makeFixture()
        let client = fixture.client
        fixture.enqueue(.init(chunks: ["data: hel", "lo\n", "\n"], endsStream: false))
        defer { client.close() }

        let reader = StreamReader(client.start())
        let (messages, _) = await collect(reader, messages: 1)

        #expect(messages == [EventSourceMessage(data: "hello")])
    }

    @Test func reconnectsAfterTheStreamEnds() async {
        let fixture = makeFixture()
        let client = fixture.client
        fixture.enqueue(
            .init(chunks: ["data: one\n\n"]),
            .init(chunks: ["data: two\n\n"], endsStream: false)
        )
        defer { client.close() }

        let reader = StreamReader(client.start())
        let (messages, opens) = await collect(reader, messages: 2)

        #expect(messages == [EventSourceMessage(data: "one"), EventSourceMessage(data: "two")])
        #expect(opens == 2)
        #expect(fixture.recorded.count == 2)
    }

    @Test func sendsTheLastEventIDWhenItReconnects() async {
        let fixture = makeFixture()
        let client = fixture.client
        fixture.enqueue(
            .init(chunks: ["id: 42\ndata: one\n\n"]),
            .init(chunks: ["data: two\n\n"], endsStream: false)
        )
        defer { client.close() }

        let reader = StreamReader(client.start())
        _ = await collect(reader, messages: 2)

        #expect(fixture.recorded.first?.headers["Last-Event-ID"] == nil)
        #expect(fixture.recorded.last?.headers["Last-Event-ID"] == "42")
        #expect(client.lastEventID == "42")
    }

    @Test func stopsWhenReconnectingIsDeclined() async {
        let observed = Locked<[Int?]>([])
        let fixture = makeFixture { configuration in
            configuration.shouldReconnect = { state in
                observed.withLock { $0.append(state.statusCode) }
                return false
            }
        }
        let client = fixture.client
        fixture.enqueue(.init(statusCode: 401))

        let stream = client.start()
        let events = await withTimeout { await Array(stream) }

        #expect(events != nil, "the client kept reconnecting instead of stopping")
        #expect(observed.withLock { $0 } == [401])
        #expect(fixture.recorded.count == 1)
        #expect(client.readyState == .closed)
        guard case let .error(error) = events?.last else {
            Issue.record("expected an error event, got \(String(describing: events))")
            return
        }
        #expect(error as? EventSourceError == .serverError(statusCode: 401))
    }

    @Test func doesNotReconnectAfterNoContent() async {
        let fixture = makeFixture()
        let client = fixture.client
        fixture.enqueue(.init(statusCode: 204))

        let stream = client.start()
        let events = await withTimeout { await Array(stream) }

        #expect(events != nil, "the client reconnected instead of stopping")
        #expect(fixture.recorded.count == 1)
        #expect(client.readyState == .closed)
    }

    @Test func honoursTheRetryIntervalTheServerAsksFor() async {
        let observed = Locked<[TimeInterval]>([])
        let fixture = makeFixture { configuration in
            configuration.reconnectDelay = { state in
                observed.withLock { $0.append(state.serverReconnectionTime) }
                return 0.01
            }
        }
        let client = fixture.client
        fixture.enqueue(
            .init(chunks: ["retry: 50\ndata: one\n\n"]),
            .init(chunks: ["data: two\n\n"], endsStream: false)
        )
        defer { client.close() }

        let reader = StreamReader(client.start())
        _ = await collect(reader, messages: 2)

        #expect(observed.withLock { $0 }.first == 0.05)
    }

    @Test func fallsBackToTheServerIntervalWhenTheDelayIsOutOfRange() async {
        let fixture = makeFixture { configuration in
            configuration.reconnectDelay = { _ in -1 }
        }
        let client = fixture.client
        fixture.enqueue(
            .init(chunks: ["retry: 10\ndata: one\n\n"]),
            .init(chunks: ["data: two\n\n"], endsStream: false)
        )
        defer { client.close() }

        let reader = StreamReader(client.start())
        var sawOutOfRange = false
        var messages = 0

        while messages < 2, let event = await reader.next() {
            switch event {
            case let .error(error) where error as? EventSourceError == .reconnectDelayOutOfRange(-1):
                sawOutOfRange = true
            case .message:
                messages += 1
            default:
                break
            }
        }

        #expect(sawOutOfRange)
        #expect(messages == 2)
    }

    @Test func sendsTheConfiguredMethodBodyAndHeaders() async {
        let fixture = makeFixture { configuration in
            configuration.method = "POST"
            configuration.body = Data(#"{"clientSdkKey":"key"}"#.utf8)
            configuration.headers = ["Content-Type": "application/json"]
        }
        let client = fixture.client
        fixture.enqueue(.init(chunks: ["data: one\n\n"], endsStream: false))
        defer { client.close() }

        let reader = StreamReader(client.start())
        _ = await collect(reader, messages: 1)

        let request = fixture.recorded.first
        #expect(request?.method == "POST")
        #expect(request?.body == #"{"clientSdkKey":"key"}"#)
        #expect(request?.headers["Content-Type"] == "application/json")
        #expect(request?.headers["Accept"] == "text/event-stream")
    }

    @Test func keepsBackingOffWhenTheServerOpensButDeliversNothing() async {
        let attempts = Locked<[Int]>([])
        let fixture = makeFixture { configuration in
            configuration.shouldReconnect = { state in
                attempts.withLock { $0.append(state.attempt) }
                return true
            }
        }
        let client = fixture.client
        fixture.enqueue(
            .init(chunks: []),
            .init(chunks: []),
            .init(chunks: []),
            .init(chunks: ["data: one\n\n"], endsStream: false)
        )
        defer { client.close() }

        let reader = StreamReader(client.start())
        _ = await collect(reader, messages: 1)

        #expect(attempts.withLock { $0 } == [1, 2, 3])
    }

    @Test func startsTheAttemptCountOverOnceAConnectionDeliversAnEvent() async {
        let attempts = Locked<[Int]>([])
        let fixture = makeFixture { configuration in
            configuration.shouldReconnect = { state in
                attempts.withLock { $0.append(state.attempt) }
                return true
            }
        }
        let client = fixture.client
        fixture.enqueue(
            .init(statusCode: 500),
            .init(statusCode: 500),
            .init(chunks: ["data: one\n\n"]),
            .init(chunks: ["data: two\n\n"], endsStream: false)
        )
        defer { client.close() }

        let reader = StreamReader(client.start())
        _ = await collect(reader, messages: 2)

        // Two failures before anything opened, then a connection that opened and dropped, which
        // starts the backoff over rather than inheriting the earlier failures.
        #expect(attempts.withLock { $0 } == [1, 2, 1])
    }

    @Test func closeFinishesTheStream() async {
        let fixture = makeFixture()
        let client = fixture.client
        fixture.enqueue(.init(chunks: ["data: one\n\n"], endsStream: false))

        let stream = client.start()
        let drained = Task {
            for await _ in stream {}
            return true
        }
        await settle(0.2)

        client.close()

        #expect(await withTimeout { await drained.value } == true)
        #expect(client.readyState == .closed)
    }
}
