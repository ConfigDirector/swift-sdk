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

    @Test func backsOffExponentiallyUpToACapOfUnderTenMinutes() {
        let delay = TransportOptions.exponentialRetryDelay

        #expect(delay(1) == 2)
        #expect(delay(2) == 4)
        #expect(delay(9) == 512)
        #expect(delay(10) == 512)
        #expect(delay(100) == 512)
    }

    @Test(arguments: [(200, false), (399, false), (400, true), (499, true), (500, false)])
    func treatsOnlyClientErrorsAsUnrecoverable(status: Int, isFatal: Bool) {
        #expect(status.isFatalHTTPStatus == isFatal)
    }
}
