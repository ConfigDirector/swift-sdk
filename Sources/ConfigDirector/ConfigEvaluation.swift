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

/// The outcome of evaluating a single config.
public struct ConfigEvaluation: Sendable {
    /// The key of the config that was evaluated.
    public let key: String

    /// The value the config evaluated to, which is the default value supplied by the caller when
    /// ``isDefaultValue`` is `true`. Cast it to the type the config was evaluated as.
    public let value: any Sendable

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
