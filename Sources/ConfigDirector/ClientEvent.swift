import Foundation

/// What prompted the client to (re)connect.
public enum ConnectReason: Sendable {
    /// The client connected for the first time, from ``ConfigDirectorClient/initialize(context:)``.
    case initialization

    /// The client reconnected to re-evaluate configs against a new context.
    case contextUpdate

    /// The client reconnected after the network was resumed.
    case networkResume
}

/// Something the client did, published on ``ConfigDirectorClient/events``.
public enum ClientEvent: Sendable {
    /// The client became ready after connecting.
    case ready(ConnectReason)

    /// Config state was received from the server, carrying the keys it contained. On a delta update
    /// these are only the configs that changed.
    case configsUpdated([String])

    /// A new context has taken effect.
    case contextUpdated(ConfigDirectorContext?)

    /// A config was evaluated, whether by ``ConfigDirectorClient/value(for:default:)`` or by a
    /// ``ConfigDirectorClient/values(for:default:)`` stream.
    case configEvaluated(ConfigEvaluation)
}

extension ConnectReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .initialization: "initialization"
        case .contextUpdate: "context update"
        case .networkResume: "network resume"
        }
    }
}
