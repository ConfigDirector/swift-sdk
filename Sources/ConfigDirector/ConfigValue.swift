import Foundation

/// A type a config can be evaluated as.
///
/// The SDK conforms `Bool`, `String`, `Int`, and `Double`. Configs holding JSON documents are read
/// with ``ConfigDirectorClient/value(for:as:default:)`` instead, which decodes into any `Decodable`
/// type.
///
/// Conform your own type to read a config as it: a config value arrives as the string the server
/// served, and ``ConfigValueKind`` decides which configs the type can be read from.
///
/// ```swift
/// extension Locale: ConfigValue {
///     public static var configValueKind: ConfigValueKind { .string }
///
///     public init?(configValue: String) {
///         self.init(identifier: configValue)
///     }
/// }
/// ```
public protocol ConfigValue: Sendable, Equatable {
    /// Which configs this type can be read from, and how a value that cannot be read is reported.
    static var configValueKind: ConfigValueKind { get }

    /// Reads the value the server served, returning `nil` when it cannot be represented as this
    /// type. The config evaluates to the caller's default value when it does.
    init?(configValue: String)
}

/// Which configs a ``ConfigValue`` can be read from.
public struct ConfigValueKind: Sendable, Equatable {
    let sourceTypes: Set<ConfigType>
    let unreadableValueReason: EvaluationReason

    /// Read from boolean configs, and from any config whose value spells `true` or `false`.
    public static let boolean = ConfigValueKind(
        sourceTypes: [.boolean, .string, .custom],
        unreadableValueReason: .invalidBoolean
    )

    /// Read from every config: each value is a string on the wire, including a JSON config's raw
    /// document.
    public static let string = ConfigValueKind(
        sourceTypes: Set(ConfigType.allCases),
        unreadableValueReason: .typeMismatch
    )

    /// Read from numeric configs, and from any config whose value spells a finite number.
    public static let number = ConfigValueKind(
        sourceTypes: [.integer, .float, .enumeration, .string, .custom],
        unreadableValueReason: .invalidNumber
    )
}

extension Bool: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .boolean
    }

    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "true": self = true
        case "false": self = false
        default: return nil
        }
    }
}

extension String: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .string
    }

    public init?(configValue: String) {
        self = configValue
    }
}

extension Int: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .number
    }

    /// Truncates a value written as a decimal, so that a float config can still serve an `Int`.
    public init?(configValue: String) {
        if let whole = Int(configValue) {
            self = whole
            return
        }

        guard let parsed = Double(configValue: configValue),
              let truncated = Int(exactly: parsed.rounded(.towardZero))
        else { return nil }

        self = truncated
    }
}

extension Double: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .number
    }

    public init?(configValue: String) {
        guard let parsed = Double(configValue), parsed.isFinite else { return nil }
        self = parsed
    }
}
