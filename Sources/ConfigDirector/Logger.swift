import Foundation
import os

/// The verbosity of a ``ConfigDirectorLogger``.
public enum ConfigDirectorLogLevel: Int, Sendable, Comparable, CaseIterable {
    /// Drops every message.
    case off = -1

    /// Failures the SDK could not recover from.
    case error = 0

    /// Recoverable problems, such as a connection that is being retried. This is the default level.
    case warn = 1

    /// Lifecycle milestones, such as the client becoming ready.
    case info = 2

    /// Per-request and per-evaluation detail. Useful when diagnosing a problem, but noisy in
    /// production.
    case debug = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The logging sink used by the SDK. Implement this to route SDK logs into your application's own
/// logging infrastructure.
public protocol ConfigDirectorLogger: Sendable {
    /// Messages more verbose than this level are never passed to ``log(_:message:error:)``.
    var level: ConfigDirectorLogLevel { get }

    /// Writes `message`, along with `error` when one is given.
    func log(_ level: ConfigDirectorLogLevel, message: String, error: (any Error)?)
}

public extension ConfigDirectorLogger {
    func debug(_ message: @autoclosure () -> String, error: (any Error)? = nil) {
        write(.debug, message(), error)
    }

    func info(_ message: @autoclosure () -> String, error: (any Error)? = nil) {
        write(.info, message(), error)
    }

    func warn(_ message: @autoclosure () -> String, error: (any Error)? = nil) {
        write(.warn, message(), error)
    }

    func error(_ message: @autoclosure () -> String, error: (any Error)? = nil) {
        write(.error, message(), error)
    }

    private func write(
        _ messageLevel: ConfigDirectorLogLevel,
        _ message: @autoclosure () -> String,
        _ error: (any Error)?
    ) {
        guard messageLevel <= level else { return }
        log(messageLevel, message: message(), error: error)
    }
}

/// The default logger, which writes to the unified logging system under the
/// `com.configdirector.sdk` subsystem.
///
/// Debug messages carry per-evaluation detail, config values included, so they are written as
/// private and redacted outside a debugging session. Warnings and errors are written as public.
public struct ConsoleLogger: ConfigDirectorLogger {
    public let level: ConfigDirectorLogLevel

    private let logger = Logger(subsystem: "com.configdirector.sdk", category: "ConfigDirector")

    public init(level: ConfigDirectorLogLevel = .warn) {
        self.level = level
    }

    public func log(_ level: ConfigDirectorLogLevel, message: String, error: (any Error)?) {
        let text = error.map { "\(message): \($0.localizedDescription)" } ?? message
        if level == .debug {
            logger.debug("\(text, privacy: .private)")
        } else {
            logger.log(level: level.osLogType, "\(text, privacy: .public)")
        }
    }
}

private extension ConfigDirectorLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .off, .error: .error
        case .warn: .default
        case .info: .info
        case .debug: .debug
        }
    }
}
