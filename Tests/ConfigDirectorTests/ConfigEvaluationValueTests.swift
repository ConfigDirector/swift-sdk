import ConfigDirector
import Foundation
import Testing

/// Exercises the value carried on a published evaluation, through the public API against a stubbed
/// ConfigDirector server.
struct ConfigEvaluationValueTests {
    private static let served = configSetJSON([
        ServedConfig("dark-mode", "boolean", "true", valueID: "on"),
        ServedConfig("rollout-percent", "integer", "42", valueID: "forty-two"),
        ServedConfig("theme", "json", #"{"primaryColor":"blue","cornerRadius":8}"#, valueID: "blue"),
        ServedConfig("banner", "string", nil, valueID: "no-value"),
    ])

    private func makeReadyClient(_ fixture: ClientFixture) async throws -> ConfigDirectorClient {
        fixture.serveStream(Self.served)
        let client = try fixture.makeClient()
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))
        return client
    }

    private func read(
        from client: ConfigDirectorClient,
        _ body: (ConfigDirectorClient) -> some Sendable
    ) async -> ConfigEvaluation? {
        let evaluations = StreamReader(client.evaluations)
        _ = body(client)

        return await evaluations.next()
    }

    @Test func readsBackAsTheTypeTheConfigWasEvaluatedAs() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let evaluation = await read(from: client) { $0.value(for: "dark-mode", default: false) }

        #expect(evaluation?.value.as(Bool.self) == true)
    }

    @Test func readsBackAsNilForATypeTheConfigWasNotEvaluatedAs() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let evaluation = await read(from: client) { $0.value(for: "dark-mode", default: false) }

        #expect(evaluation?.value.as(String.self) == nil)
    }

    /// A JSON config is read as a `Decodable` type, which is not a ``ConfigValue``, so the value has
    /// to carry those back too.
    @Test func readsBackADecodedDocument() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }
        let fallback = Theme(primaryColor: "red", cornerRadius: 0)

        let evaluation = await read(from: client) {
            $0.value(for: "theme", as: Theme.self, default: fallback)
        }

        #expect(evaluation?.value.as(Theme.self) == Theme(primaryColor: "blue", cornerRadius: 8))
    }

    @Test func describesTheValueItCarries() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }

        let evaluation = await read(from: client) { $0.value(for: "rollout-percent", default: 0) }

        #expect(evaluation?.value.description == "42")
    }

    @Test func evaluationsOfTheSameReadAreEqual() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }
        let evaluations = StreamReader(client.evaluations)

        _ = client.value(for: "dark-mode", default: false)
        _ = client.value(for: "dark-mode", default: false)

        #expect(await evaluations.next() == evaluations.next())
    }

    /// `banner` is served without a value, so both reads fall back and every other field on the
    /// evaluation matches. That leaves the value as the only thing equality can turn on.
    @Test func evaluationsThatDifferOnlyInTheirValueAreNotEqual() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }
        let evaluations = StreamReader(client.evaluations)

        _ = client.value(for: "banner", default: "first")
        _ = client.value(for: "banner", default: "second")

        let first = await evaluations.next()
        let second = await evaluations.next()

        #expect(first?.key == second?.key)
        #expect(first?.valueID == second?.valueID)
        #expect(first?.isDefaultValue == second?.isDefaultValue)
        #expect(first?.reason == second?.reason)
        #expect(first != second, "only the value differs, so equality has to turn on it")
    }

    @Test func evaluationsOfDifferentConfigsAreNotEqual() async throws {
        let fixture = ClientFixture()
        let client = try await makeReadyClient(fixture)
        defer { client.close() }
        let evaluations = StreamReader(client.evaluations)

        _ = client.value(for: "dark-mode", default: false)
        _ = client.value(for: "rollout-percent", default: 0)

        #expect(await evaluations.next() != evaluations.next())
    }
}
