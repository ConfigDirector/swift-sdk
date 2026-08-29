import Foundation

/// A type a config can be evaluated as.
///
/// The SDK conforms `Bool`, `String`, `Int`, and `Double`. Configs holding JSON documents are read
/// with ``ConfigDirectorClient/value(for:as:default:)`` instead, which decodes into any `Decodable`
/// type.
public protocol ConfigValue: Sendable, Equatable {
    /// How the SDK parses a served config value into this type.
    static var configValueKind: ConfigValueKind { get }
}

/// The kinds of value a ``ConfigValue`` can be parsed as.
public struct ConfigValueKind: Sendable, Equatable {
    enum Representation {
        case boolean
        case string
        case integer
        case number
    }

    let representation: Representation

    /// Parsed from `true` or `false`, case-insensitively.
    public static let boolean = ConfigValueKind(representation: .boolean)

    /// Served verbatim: every config value is a string on the wire.
    public static let string = ConfigValueKind(representation: .string)

    /// Parsed as a whole number, truncating a value written as a decimal.
    public static let integer = ConfigValueKind(representation: .integer)

    /// Parsed as a finite floating-point number.
    public static let number = ConfigValueKind(representation: .number)
}

extension Bool: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .boolean
    }
}

extension String: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .string
    }
}

extension Int: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .integer
    }
}

extension Double: ConfigValue {
    public static var configValueKind: ConfigValueKind {
        .number
    }
}
