@testable import ConfigDirector
import Foundation
import Testing

struct EventReporterTests {
    private struct Fixture {
        let reporter: HTTPEventReporter
        let url: URL

        var requests: [StubURLProtocol.RecordedRequest] {
            StubURLProtocol.recorded(for: url)
        }

        func enqueue(_ statusCodes: Int...) {
            StubURLProtocol.enqueue(statusCodes.map { .json("{}", statusCode: $0) }, for: url)
        }
    }

    private func makeFixture() -> Fixture {
        let baseURL = URL(string: "https://example.test/\(UUID().uuidString)/")!

        return Fixture(
            reporter: HTTPEventReporter(
                clientSDKKey: "sdk-key",
                baseURL: baseURL,
                metaContext: TelemetryMetaContext(sdkName: "swift-client-sdk", sdkVersion: "0.1.0"),
                logger: ConsoleLogger(level: .off),
                session: StubURLProtocol.makeSession()
            ),
            url: URL(string: "client/telemetry/v1", relativeTo: baseURL)!.absoluteURL
        )
    }

    private func makeReport(events: Int = 1, droppedCount: Int = 0) -> EventReport {
        let event = EvaluatedConfigEvent(
            contextID: "user-1",
            key: "dark-mode",
            type: .boolean,
            defaultValue: TelemetryValue(value: "false", type: .boolean),
            requestedType: "Bool",
            evaluatedValue: TelemetryValue(value: "true", type: .boolean),
            usedDefault: false,
            evaluationReason: .foundMatch
        )

        return EventReport(
            snapshot: EventQueueSnapshot(
                startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 1),
                events: Array(repeating: event, count: events),
                droppedCount: droppedCount
            ),
            context: ConfigDirectorContext(id: "user-1")
        )
    }

    @Test func postsTheAggregatedReportToTheTelemetryEndpoint() async throws {
        let fixture = makeFixture()
        fixture.enqueue(202)

        #expect(await fixture.reporter.report(makeReport(events: 3)) == .succeeded)

        let request = try #require(fixture.requests.first)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(request.body)
        let report = try JSONDecoder().decode(TelemetryReport.self, from: Data(body.utf8))
        #expect(report.clientSdkKey == "sdk-key")
        #expect(report.metaContext.sdkName == "swift-client-sdk")
        #expect(report.context?.id == "user-1")
        #expect(report.aggregatedEvents.evaluatedConfig.count == 1)
        #expect(report.aggregatedEvents.evaluatedConfig.first?.count == 3)
        #expect(report.aggregatedEvents.evaluatedConfig.first?.startTime == "1970-01-01T00:00:00.000Z")
        #expect(report.aggregatedEvents.evaluatedConfig.first?.endTime == "1970-01-01T00:00:01.000Z")
        #expect(report.droppedEvents.evaluatedConfig == 0)
    }

    @Test func reportsHowManyEventsWereDropped() async throws {
        let fixture = makeFixture()
        fixture.enqueue(202)

        _ = await fixture.reporter.report(makeReport(events: 0, droppedCount: 7))

        let body = try #require(fixture.requests.first?.body)
        let report = try JSONDecoder().decode(TelemetryReport.self, from: Data(body.utf8))
        #expect(report.droppedEvents.evaluatedConfig == 7)
        #expect(report.aggregatedEvents.evaluatedConfig.isEmpty)
    }

    @Test func sendsNothingWhenThereIsNothingToReport() async {
        let fixture = makeFixture()
        fixture.enqueue(202)

        #expect(await fixture.reporter.report(makeReport(events: 0)) == .succeeded)

        #expect(fixture.requests.isEmpty)
    }

    @Test(arguments: [
        (500, ReportOutcome.failed),
        (503, .failed),
        (401, .failedFatally),
        (404, .failedFatally)
    ])
    func classifiesTheServerResponse(statusCode: Int, expected: ReportOutcome) async {
        let fixture = makeFixture()
        fixture.enqueue(statusCode)

        #expect(await fixture.reporter.report(makeReport()) == expected)
    }

    @Test func retriesAfterATransientFailureButNotAfterAFatalOne() async {
        let fixture = makeFixture()
        fixture.enqueue(500, 202)

        #expect(await fixture.reporter.report(makeReport()) == .failed)
        #expect(await fixture.reporter.report(makeReport()) == .succeeded)
        #expect(fixture.requests.count == 2)

        fixture.enqueue(401)
        #expect(await fixture.reporter.report(makeReport()) == .failedFatally)
        #expect(await fixture.reporter.report(makeReport()) == .failedFatally)
        #expect(fixture.requests.count == 3, "nothing is sent after a fatal response")
    }

    @Test func sendsNothingOnceClosed() async {
        let fixture = makeFixture()
        fixture.enqueue(202)

        fixture.reporter.close()

        #expect(await fixture.reporter.report(makeReport()) == .failedFatally)
        #expect(fixture.requests.isEmpty)
    }
}
