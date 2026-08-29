import ConfigDirector
import Foundation
import Testing

/// Exercises what the SDK reports back to ConfigDirector, read from the requests it posts to the
/// stubbed telemetry endpoint.
struct ConfigDirectorClientTelemetryTests {
    private func firstReport(
        _ fixture: ClientFixture,
        containing key: String
    ) async -> TelemetryReport.Aggregated? {
        _ = await waitUntil { fixture.telemetryReports().contains { !$0.evaluations(of: key).isEmpty } }
        return fixture.telemetryReports().lazy.compactMap { $0.evaluations(of: key).first }.first
    }

    @Test func reportsEvaluationsToTheTelemetryEndpoint() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))

        _ = client.value(for: "dark-mode", default: false)

        let evaluation = try #require(await firstReport(fixture, containing: "dark-mode"))
        #expect(evaluation.event.contextId == "user-123")
        #expect(evaluation.event.type == "boolean")
        #expect(evaluation.event.requestedType == "Bool")
        #expect(evaluation.event.defaultValue.value == "false")
        #expect(evaluation.event.evaluatedValue.value == "true")
        #expect(evaluation.event.evaluatedValueId == "on")
        #expect(evaluation.event.usedDefault == false)
        #expect(evaluation.event.evaluationReason == "found-match")

        let report = try #require(fixture.telemetryReports().first)
        #expect(report.clientSdkKey == "sdk-key")
        #expect(report.metaContext.sdkName == "swift-client-sdk")
        #expect(report.context?.id == "user-123")
        #expect(report.droppedEvents.evaluatedConfig == 0)

        let request = try #require(fixture.telemetryRequests.first)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    @Test func reportsRepeatedEvaluationsOnceWithACount() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        for _ in 0 ..< 5 {
            _ = client.value(for: "welcome-message", default: "")
        }

        let evaluation = try #require(await firstReport(fixture, containing: "welcome-message"))
        #expect(evaluation.count == 5)
        #expect(evaluation.startTime <= evaluation.endTime)
    }

    @Test func reportsAnEvaluationThatFellBackToItsDefault() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        _ = client.value(for: "missing", default: "fallback")

        let evaluation = try #require(await firstReport(fixture, containing: "missing"))
        #expect(evaluation.event.usedDefault)
        #expect(evaluation.event.evaluationReason == "config-state-missing")
        #expect(evaluation.event.type == nil, "there is no config state to take a type from")
        #expect(evaluation.event.evaluatedValue.value == "fallback")
    }

    @Test func reportsAJSONConfigByTheValueIDTheServerSent() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(configSetJSON([
            ServedConfig("theme", "json", #"{"primaryColor":"blue","cornerRadius":8}"#, valueID: "theme-1"),
        ]))
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        _ = client.value(for: "theme", as: Theme.self, default: Theme(primaryColor: "", cornerRadius: 0))

        let evaluation = try #require(await firstReport(fixture, containing: "theme"))
        #expect(evaluation.event.evaluatedValue.valueId == "theme-1")
        #expect(evaluation.event.evaluatedValue.value == nil, "a JSON document is never sent inline")
        #expect(evaluation.event.requestedType == "Theme")
    }

    @Test func reportsALongValueByADerivedIDRatherThanInline() async throws {
        let long = String(repeating: "a", count: 600)
        let fixture = ClientFixture()
        fixture.serveStream(configSetJSON([ServedConfig("banner", "string", long)]))
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        _ = client.value(for: "banner", default: "")

        let evaluation = try #require(await firstReport(fixture, containing: "banner"))
        #expect(evaluation.event.evaluatedValue.value == nil)
        #expect(evaluation.event.evaluatedValue.valueId == "5fN8d72HXaUK6VkcOwuKTN")
    }

    @Test func attributesEvaluationsToTheContextTheyWereMadeAgainst() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize(context: ConfigDirectorContext(id: "user-123"))
        _ = client.value(for: "dark-mode", default: false)

        await client.updateContext(ConfigDirectorContext(id: "user-456"))
        _ = client.value(for: "welcome-message", default: "")

        let byContext = await waitUntil {
            fixture.telemetryReports().contains { $0.context?.id == "user-456" }
        }
        #expect(byContext)

        let first = try #require(fixture.telemetryReports()
            .first { !$0.evaluations(of: "dark-mode").isEmpty })
        let second = try #require(
            fixture.telemetryReports().first { !$0.evaluations(of: "welcome-message").isEmpty }
        )
        #expect(first.context?.id == "user-123")
        #expect(first.evaluations(of: "dark-mode").first?.event.contextId == "user-123")
        #expect(second.context?.id == "user-456")
        #expect(second.evaluations(of: "welcome-message").first?.event.contextId == "user-456")
    }

    @Test func reportsWhatIsLeftWhenTheAppEntersTheBackground() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient(telemetryFlushInterval: 60)
        defer { client.close() }
        await client.initialize()
        _ = client.value(for: "dark-mode", default: false)

        #expect(fixture.telemetryRequests.isEmpty, "nothing is due yet")

        fixture.enterBackground()

        #expect(await firstReport(fixture, containing: "dark-mode") != nil)
    }

    @Test func reportsWhatIsLeftWhenTheClientIsClosed() async throws {
        let fixture = ClientFixture()
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient(telemetryFlushInterval: 60)
        await client.initialize()
        _ = client.value(for: "dark-mode", default: false)

        client.close()

        #expect(await firstReport(fixture, containing: "dark-mode") != nil)
    }

    @Test func neverWaitsOnTelemetryWhenConnecting() async throws {
        let fixture = ClientFixture(telemetryStatus: nil)
        fixture.serveStream(servedConfigSet)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        _ = client.value(for: "dark-mode", default: false)
        #expect(await waitUntil { fixture.telemetryRequests.count == 1 }, "no report was in flight")

        // Collected behind the report that is stuck, so the update has something waiting on it.
        _ = client.value(for: "welcome-message", default: "")

        let startedAt = Date()
        await client.updateContext(ConfigDirectorContext(id: "user-456"))

        #expect(Date().timeIntervalSince(startedAt) < 1, "the context update waited on telemetry")
        #expect(client.isReady)
    }

    @Test func stopsCollectingOnceTheServerRejectsAReport() async throws {
        let fixture = ClientFixture(telemetryStatus: 401)
        fixture.serveStream(servedConfigSet)
        let client = try fixture.makeClient()
        defer { client.close() }
        await client.initialize()

        _ = client.value(for: "dark-mode", default: false)
        #expect(await waitUntil { fixture.telemetryRequests.count == 1 })

        for _ in 0 ..< 5 {
            _ = client.value(for: "welcome-message", default: "")
        }

        await settle(0.4)
        #expect(fixture.telemetryRequests.count == 1, "an invalid SDK key must not be retried")
    }
}
