import ConfigDirector
import Foundation
import Testing

/// Exercises what an application sees when a served value cannot be read as the type it asked for,
/// through the public API against a stubbed ConfigDirector server.
struct ConfigDirectorClientEvaluationTests {
    /// One config per way an evaluation can fail, alongside one that reads cleanly.
    private static let unreadable = configSetJSON([
        ServedConfig("dark-mode", "boolean", "yes", valueID: "broken-bool"),
        ServedConfig("max-retries", "integer", "not-a-number", valueID: "broken-number"),
        ServedConfig("theme", "json", "{oops", valueID: "broken-json"),
        ServedConfig("banner", "string", nil, valueID: "no-value"),
        ServedConfig("rollout-percent", "integer", "42", valueID: "forty-two"),
        ServedConfig("welcome-message", "string", "Hello", valueID: "hello"),
    ])

    private func makeReadyClient(_ fixture: ClientFixture) async throws -> ConfigDirectorClient {
        fixture.serveStream(Self.unreadable)
        let client = try fixture.makeClient()
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))
        return client
    }

    /// Reads a config and returns both what the caller got and the evaluation the client published.
    private func read<Value: Sendable>(
        from client: ConfigDirectorClient,
        _ body: (ConfigDirectorClient) -> Value
    ) async -> (value: Value, evaluation: ConfigEvaluation?) {
        let evaluations = StreamReader(client.evaluations)
        let value = body(client)

        return await (value, evaluations.next())
    }

    @Test func servesTheDefaultWhenAValueDoesNotSpellABoolean() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let (value, evaluation) = await read(from: client) { $0.value(for: "dark-mode", default: true) }

        #expect(value == true)
        #expect(evaluation?.key == "dark-mode")
        #expect(evaluation?.isDefaultValue == true)
        #expect(evaluation?.reason == .invalidBoolean)
        #expect(evaluation?.valueID == nil, "a default value is not attributed to a served value")
    }

    @Test func servesTheDefaultWhenAValueDoesNotSpellANumber() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let (value, evaluation) = await read(from: client) { $0.value(for: "max-retries", default: 3) }

        #expect(value == 3)
        #expect(evaluation?.isDefaultValue == true)
        #expect(evaluation?.reason == .invalidNumber)
    }

    @Test func servesTheDefaultWhenADocumentDoesNotDecode() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }
        let fallback = Theme(primaryColor: "red", cornerRadius: 0)

        let (value, evaluation) = await read(from: client) {
            $0.value(for: "theme", as: Theme.self, default: fallback)
        }

        #expect(value == fallback)
        #expect(evaluation?.isDefaultValue == true)
        #expect(evaluation?.reason == .invalidJSON)
    }

    @Test func servesTheDefaultWhenTheConfigHasNoValueForTheContext() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let (value, evaluation) = await read(from: client) { $0.value(for: "banner", default: "none") }

        #expect(value == "none")
        #expect(evaluation?.isDefaultValue == true)
        #expect(evaluation?.reason == .valueMissing)
    }

    @Test func servesTheDefaultWhenTheConfigIsADifferentTypeEntirely() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let (value, evaluation) = await read(from: client) {
            $0.value(for: "rollout-percent", default: false)
        }

        #expect(value == false)
        #expect(evaluation?.isDefaultValue == true)
        #expect(evaluation?.reason == .typeMismatch)
    }

    @Test func servesTheDefaultWhenAJSONConfigIsReadAsAPrimitive() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let (value, evaluation) = await read(from: client) { $0.value(for: "theme", default: 0) }

        #expect(value == 0)
        #expect(evaluation?.reason == .typeMismatch)
    }

    @Test func servesTheRawDocumentWhenAJSONConfigIsReadAsAString() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let (value, evaluation) = await read(from: client) { $0.value(for: "theme", default: "") }

        #expect(value == "{oops")
        #expect(evaluation?.isDefaultValue == false)
        #expect(evaluation?.reason == .foundMatch)
    }

    @Test func keepsServingTheConfigsThatDoRead() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        #expect(client.value(for: "dark-mode", default: true) == true)
        #expect(client.value(for: "welcome-message", default: "") == "Hello")
        #expect(client.value(for: "rollout-percent", default: 0) == 42)
        #expect(client.isReady, "an unreadable value is not a connection failure")
    }

    @Test func aWatchStreamNeverEmitsAValueItCannotRead() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(Self.unreadable)
        let client = try fixture.makeClient()

        let collected = client.values(for: "max-retries", default: 3).collectUntilFinished()
        await settle()

        await client.initialize()
        await settle()

        client.close()
        #expect(await withTimeout { await collected.value } == [3], "the stream emitted an unread value")
    }

    @Test func aWatchStreamFallsBackWhenAnUpdateBreaksAValueItWasServing() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(configSetJSON([ServedConfig("max-retries", "integer", "9")]))
        let client = try fixture.makeClient()
        defer { client.close() }

        let values = StreamReader(client.values(for: "max-retries", default: 3))
        #expect(await values.next() == 3)

        await client.initialize()
        #expect(await values.next() == 9)

        fixture.pushToStream(deltaConfigSet([ServedConfig("max-retries", "integer", "broken")]))

        #expect(await values.next() == 3, "the stream did not fall back when the value stopped reading")
    }

    @Test func reportsWhyAnEvaluationFellBackToItsDefault() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        _ = client.value(for: "dark-mode", default: true)

        _ = await waitUntil {
            fixture.telemetryReports().contains { !$0.evaluations(of: "dark-mode").isEmpty }
        }
        let reported = try #require(
            fixture.telemetryReports().lazy.compactMap { $0.evaluations(of: "dark-mode").first }.first
        )

        #expect(reported.event.usedDefault)
        #expect(reported.event.evaluationReason == "invalid-boolean")
        #expect(reported.event.type == "boolean", "the config's declared type is still reported")
        #expect(reported.event.evaluatedValue.value == "true", "the default is what the caller got")
        #expect(reported.event.evaluatedValueId == nil)
    }
}
