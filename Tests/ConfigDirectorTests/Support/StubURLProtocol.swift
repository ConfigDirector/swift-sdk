@testable import ConfigDirector
import Foundation

/// Serves scripted HTTP responses, one per connection attempt, so reconnection behavior can be
/// driven from a test. Responses can be left open to model a stream that is still connected.
///
/// Everything is keyed by URL. A client whose reconnect loop is still winding down at the end of a
/// test would otherwise consume the response the next test just queued.
final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var statusCode = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [String] = []

        /// When false the response is left open, the way a healthy server-sent events stream is.
        var endsStream = true
    }

    struct RecordedRequest: Sendable {
        var method: String?
        var headers: [String: String]
        var body: String?
        var timeout: TimeInterval
    }

    private struct State {
        var queues: [String: [Response]] = [:]
        var recorded: [String: [RecordedRequest]] = [:]
        var cancelled: [String: Int] = [:]
    }

    private static let state = Locked(State())

    static func enqueue(_ responses: [Response], for url: URL) {
        state.withLock { $0.queues[url.absoluteString, default: []].append(contentsOf: responses) }
    }

    static func recorded(for url: URL) -> [RecordedRequest] {
        state.withLock { $0.recorded[url.absoluteString] ?? [] }
    }

    /// How many connections to `url` were cancelled by the client rather than ended by the server.
    static func cancelled(for url: URL) -> Int {
        state.withLock { $0.cancelled[url.absoluteString] ?? 0 }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.next(recording: request)

        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: response.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }

        if response.endsStream {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        let key = request.url?.absoluteString ?? ""
        Self.state.withLock { $0.cancelled[key, default: 0] += 1 }
    }

    /// Takes the next scripted response, defaulting to one that stays open so a client that
    /// reconnects more often than the test scripted does not spin.
    private static func next(recording request: URLRequest) -> Response {
        let key = request.url?.absoluteString ?? ""

        return state.withLock { state in
            state.recorded[key, default: []].append(
                RecordedRequest(
                    method: request.httpMethod,
                    headers: request.allHTTPHeaderFields ?? [:],
                    body: body(of: request),
                    timeout: request.timeoutInterval
                )
            )

            guard var queue = state.queues[key], !queue.isEmpty else {
                return Response(endsStream: false)
            }
            let response = queue.removeFirst()
            state.queues[key] = queue
            return response
        }
    }

    /// URLSession turns a request body into a stream before a protocol sees it, so both have to be
    /// handled to read back what was sent.
    private static func body(of request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(decoding: body, as: UTF8.self)
        }

        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }

        return String(decoding: data, as: UTF8.self)
    }
}
