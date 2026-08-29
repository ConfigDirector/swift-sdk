import Foundation

struct EvaluationResult<Value> {
    var value: Value
    var valueID: String?
    var usedDefault: Bool
    var reason: EvaluationReason

    static func matched(_ value: Value, valueID: String?) -> Self {
        Self(value: value, valueID: valueID, usedDefault: false, reason: .foundMatch)
    }

    static func usedDefault(_ value: Value, reason: EvaluationReason) -> Self {
        Self(value: value, usedDefault: true, reason: reason)
    }
}

enum ConfigValueParser {
    static func parse<Value: ConfigValue>(
        _ configState: ConfigState,
        default defaultValue: Value
    ) -> EvaluationResult<Value> {
        guard let rawValue = configState.value, !rawValue.isEmpty else {
            return .usedDefault(defaultValue, reason: .valueMissing)
        }

        let kind = Value.configValueKind
        guard kind.sourceTypes.contains(configState.type) else {
            return .usedDefault(defaultValue, reason: .typeMismatch)
        }

        guard let value = Value(configValue: rawValue) else {
            return .usedDefault(defaultValue, reason: kind.unreadableValueReason)
        }

        return .matched(value, valueID: configState.valueID)
    }

    static func parseJSON<Value: Decodable>(
        _ configState: ConfigState,
        as type: Value.Type,
        default defaultValue: Value
    ) -> EvaluationResult<Value> {
        guard let rawValue = configState.value, !rawValue.isEmpty else {
            return .usedDefault(defaultValue, reason: .valueMissing)
        }

        guard configState.type == .json else {
            return .usedDefault(defaultValue, reason: .typeMismatch)
        }

        guard let decoded = try? JSONDecoder().decode(type, from: Data(rawValue.utf8)) else {
            return .usedDefault(defaultValue, reason: .invalidJSON)
        }

        return .matched(decoded, valueID: configState.valueID)
    }
}
