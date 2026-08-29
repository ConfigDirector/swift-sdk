import Foundation

struct EvaluationResult<Value> {
    var value: Value
    var valueID: String?
    var usedDefault: Bool
    var reason: EvaluationReason
}

enum ConfigValueParser {
    /// Config types a boolean can be parsed from.
    private static let booleanSourceTypes: Set<ConfigType> = [.boolean, .string, .custom]

    /// Config types a number can be parsed from.
    private static let numericSourceTypes: Set<ConfigType> = [
        .integer, .float, .enumeration, .string, .custom,
    ]

    static func parse<Value: ConfigValue>(
        _ configState: ConfigState,
        default defaultValue: Value
    ) -> EvaluationResult<Value> {
        guard let rawValue = configState.value, !rawValue.isEmpty else {
            return .init(value: defaultValue, usedDefault: true, reason: .valueMissing)
        }

        // Every config value is a string on the wire, so a string default always matches regardless
        // of the config's declared type, including a JSON config served as its raw document.
        if Value.configValueKind == .string {
            return matched(rawValue, configState.valueID, default: defaultValue)
        }

        guard configState.type != .json else {
            return .init(value: defaultValue, usedDefault: true, reason: .typeMismatch)
        }

        switch Value.configValueKind.representation {
        case .boolean:
            guard booleanSourceTypes.contains(configState.type) else {
                return .init(value: defaultValue, usedDefault: true, reason: .typeMismatch)
            }
            guard let parsed = parseBool(rawValue) else {
                return .init(value: defaultValue, usedDefault: true, reason: .invalidBoolean)
            }
            return matched(parsed, configState.valueID, default: defaultValue)

        case .integer, .number:
            guard numericSourceTypes.contains(configState.type) else {
                return .init(value: defaultValue, usedDefault: true, reason: .typeMismatch)
            }
            let parsed: (any Sendable)? = Value.configValueKind == .integer
                ? parseInt(rawValue)
                : parseDouble(rawValue)
            guard let parsed else {
                return .init(value: defaultValue, usedDefault: true, reason: .invalidNumber)
            }
            return matched(parsed, configState.valueID, default: defaultValue)

        case .string:
            preconditionFailure("string values are served verbatim")
        }
    }

    static func parseJSON<Value: Decodable>(
        _ configState: ConfigState,
        as type: Value.Type,
        default defaultValue: Value
    ) -> EvaluationResult<Value> {
        guard let rawValue = configState.value, !rawValue.isEmpty else {
            return .init(value: defaultValue, usedDefault: true, reason: .valueMissing)
        }

        guard configState.type == .json else {
            return .init(value: defaultValue, usedDefault: true, reason: .typeMismatch)
        }

        guard let decoded = try? JSONDecoder().decode(type, from: Data(rawValue.utf8)) else {
            return .init(value: defaultValue, usedDefault: true, reason: .invalidJSON)
        }

        return .init(
            value: decoded,
            valueID: configState.valueID,
            usedDefault: false,
            reason: .foundMatch
        )
    }

    /// Reports a match when `parsed` is the type the caller asked for, and a type mismatch otherwise,
    /// which is what a type conformed to ``ConfigValue`` outside the SDK evaluates to.
    private static func matched<Value: ConfigValue>(
        _ parsed: any Sendable,
        _ valueID: String?,
        default defaultValue: Value
    ) -> EvaluationResult<Value> {
        guard let value = parsed as? Value else {
            return .init(value: defaultValue, usedDefault: true, reason: .typeMismatch)
        }
        return .init(value: value, valueID: valueID, usedDefault: false, reason: .foundMatch)
    }

    private static func parseBool(_ rawValue: String) -> Bool? {
        switch rawValue.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    /// Truncates values written as decimals so that a float config can still serve an `Int` default.
    private static func parseInt(_ rawValue: String) -> Int? {
        if let parsed = Int(rawValue) {
            return parsed
        }
        guard let parsed = parseDouble(rawValue) else { return nil }
        return Int(exactly: parsed.rounded(.towardZero))
    }

    private static func parseDouble(_ rawValue: String) -> Double? {
        guard let parsed = Double(rawValue), parsed.isFinite else { return nil }
        return parsed
    }
}
