@testable import ConfigDirector
import Foundation
import Testing

struct TransportOptionsTests {
    private func makeOptions(baseURL: String) -> TransportOptions {
        TransportOptions(
            clientSDKKey: "test-key",
            baseURL: URL(string: baseURL)!,
            metaContext: SDKMetaContext(sdkName: "swift-client-sdk", sdkVersion: "0.1.0"),
            instanceID: "instance-1",
            logger: ConsoleLogger(level: .off),
            pollingInterval: 60
        )
    }

    @Test(arguments: [
        ("https://example.test", "https://example.test/client/sse/v1"),
        ("https://example.test/", "https://example.test/client/sse/v1"),
        ("https://example.test/proxy/", "https://example.test/proxy/client/sse/v1"),
        ("https://example.test/proxy", "https://example.test/proxy/client/sse/v1"),
    ])
    func resolvesEndpointsAgainstTheBaseURL(baseURL: String, expected: String) {
        #expect(makeOptions(baseURL: baseURL).endpoint("client/sse/v1").absoluteString == expected)
    }

    @Test func omitsTheUpdateTimestampUntilTheServerHasSentOne() throws {
        let options = makeOptions(baseURL: "https://example.test")
        let context = ConfigDirectorContext(id: "user-1", name: "Ada", isAnonymous: true)

        let withoutTimestamp = try JSONDecoder().decode(
            SentPayload.self,
            from: options.payload(for: context)
        )
        let withTimestamp = try JSONDecoder().decode(
            SentPayload.self,
            from: options.payload(for: context, lastUpdateTimestamp: "stamp")
        )

        #expect(withoutTimestamp.lastUpdateTimestamp == nil)
        #expect(withTimestamp.lastUpdateTimestamp == "stamp")
        #expect(withoutTimestamp.givenContext.id == "user-1")
        #expect(withoutTimestamp.givenContext.name == "Ada")
        #expect(withoutTimestamp.givenContext.anonymous == true)
    }

    @Test(arguments: [
        (1, 1.0 ... 2.0),
        (2, 2.0 ... 4.0),
        (9, 256.0 ... 512.0),
        (10, 256.0 ... 512.0),
        (100, 256.0 ... 512.0),
    ])
    func backsOffExponentiallyUpToACapOfUnderTenMinutes(attempt: Int, expected: ClosedRange<TimeInterval>) {
        let delay = TransportOptions.exponentialRetryDelay

        for _ in 0 ..< 100 {
            #expect(expected.contains(delay(attempt)))
        }
    }

    @Test func spreadsReconnectsOutWithJitter() {
        let delay = TransportOptions.exponentialRetryDelay

        let samples = Set((0 ..< 100).map { _ in delay(5) })

        #expect(samples.count > 1, "every client would reconnect at the same instant")
    }

    @Test(arguments: [(200, false), (399, false), (400, true), (499, true), (500, false)])
    func treatsOnlyClientErrorsAsUnrecoverable(status: Int, isFatal: Bool) {
        #expect(status.isFatalHTTPStatus == isFatal)
    }
}
