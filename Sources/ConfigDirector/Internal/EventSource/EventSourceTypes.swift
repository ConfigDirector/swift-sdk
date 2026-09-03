import Foundation

struct EventSourceMessage: Sendable, Equatable {
    var id: String?
    var event: String?
    var data: String
}

enum EventSourceReadyState: Sendable, Equatable {
    case connecting
    case open
    case closed
}

/// What the connection looked like when it dropped, which decides whether and when to reconnect.
struct EventSourceReconnectionState: Sendable {
    /// 1 for the first attempt after a connection drops, growing while attempts keep failing, and
    /// reset once a connection delivers an event.
    var attempt: Int

    /// The delay the server last asked for through a `retry:` field.
    var serverReconnectionTime: TimeInterval

    var statusCode: Int?
    var error: (any Error)?
}

enum EventSourceError: Error, Equatable {
    /// The server closed the response stream.
    case streamClosed

    case serverError(statusCode: Int)

    /// The response was not HTTP.
    case invalidResponse

    /// A delay outside the range the spec allows, which is ignored in favour of the server's.
    case reconnectDelayOutOfRange(TimeInterval)
}
