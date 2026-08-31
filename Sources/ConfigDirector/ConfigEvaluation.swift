import Foundation

/// Why a config evaluated to the value it did.
public enum EvaluationReason: String, Sendable {
    /// The config state was found and its value matched the requested type.
    case foundMatch = "found-match"

    /// No state was received for the config key.
    case configStateMissing = "config-state-missing"

    /// The client had not received config state yet.
    case clientNotReady = "client-not-ready"

    /// The config's type is incompatible with the requested type.
    case typeMismatch = "type-mismatch"

    /// The config has no value for the current context.
    case valueMissing = "value-missing"

    /// The config value could not be parsed as a number.
    case invalidNumber = "invalid-number"

    /// The config value could not be parsed as JSON.
    case invalidJSON = "invalid-json"

    /// The config value could not be parsed as a boolean.
    case invalidBoolean = "invalid-boolean"
}

/// The value a config evaluated to.
///
/// It holds the value as the type the config was read as, which ``as(_:)`` hands back, alongside a
/// textual form for logging. Two values are equal when their textual forms match.
public struct ConfigEvaluationValue: Sendable, Equatable, CustomStringConvertible {
    /// A textual form of the value, the same one the SDK reports in telemetry.
    public let description: String

    private let value: any Sendable

    init(_ value: some Sendable) {
        self.value = value
        description = String(describing: value)
    }

    /// The value as `type`, or `nil` when the config was evaluated as a different type.
    ///
    /// ```swift
    /// for await evaluation in client.evaluations {
    ///     if let isOn = evaluation.value.as(Bool.self) {
    ///         logger.debug("'\(evaluation.key)' is \(isOn)")
    ///     }
    /// }
    /// ```
    public func `as`<Value: Sendable>(_ type: Value.Type) -> Value? {
        value as? Value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.description == rhs.description
    }
}

/// The outcome of evaluating a single config.
public struct ConfigEvaluation: Sendable, Equatable {
    /// The key of the config that was evaluated.
    public let key: String

    /// The value the config evaluated to, which is the default value supplied by the caller when
    /// ``isDefaultValue`` is `true`.
    public let value: ConfigEvaluationValue

    /// Identifies the specific config value that was served, for telemetry. It is `nil` when the
    /// default value was returned.
    public let valueID: String?

    /// Whether the default value provided by the caller was returned.
    public let isDefaultValue: Bool

    /// Why the config evaluated to ``value``.
    public let reason: EvaluationReason

    /// The context the config was evaluated against, if one was set.
    public let context: ConfigDirectorContext?
}
