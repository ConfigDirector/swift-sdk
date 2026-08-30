import Foundation

/// A config value as it is reported to ConfigDirector: the value itself when it is small enough to
/// send, or the id ConfigDirector knows it by.
struct TelemetryValue: Hashable, Sendable {
    /// Values longer than this are reported by id rather than inline, to keep payloads small.
    static let maxLength = 500

    var value: String?
    var valueID: String?

    /// The type the config was declared with, carried only until the value is ``compacted()``.
    var type: ConfigType?

    /// Returns the form of this value that is sent to the server: a value too large to report
    /// inline, and every JSON document, is replaced by its id.
    ///
    /// This is the only step that hashes, which is why it runs off the caller's thread.
    func compacted() -> TelemetryValue {
        let mustUseID = type == .json || (value?.utf16.count ?? 0) > Self.maxLength

        if let valueID, mustUseID {
            return TelemetryValue(valueID: valueID)
        }

        guard let value, !value.isEmpty else {
            return valueID.map { TelemetryValue(valueID: $0) } ?? TelemetryValue()
        }

        return mustUseID ? TelemetryValue(valueID: ValueID.make(for: value)) : TelemetryValue(value: value)
    }
}

extension TelemetryValue: Encodable {
    private enum CodingKeys: String, CodingKey {
        case value, type
        case valueID = "valueId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(valueID, forKey: .valueID)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
    }
}

/// A single config evaluation, as reported to ConfigDirector.
///
/// Identical evaluations are reported once with a count, so equality is what decides which events
/// collapse together.
struct EvaluatedConfigEvent: Hashable, Sendable {
    /// The id of the context the config was evaluated against.
    var contextID: String?

    var key: String

    /// The type the config was declared with, or `nil` when no config state was found for ``key``.
    var type: ConfigType?

    var defaultValue: TelemetryValue

    /// The name of the type the caller asked the value to be returned as.
    var requestedType: String

    var evaluatedValue: TelemetryValue

    /// The id the server sent for the evaluated value, kept alongside ``evaluatedValue`` because a
    /// value small enough to report inline is reported by value.
    var evaluatedValueID: String?

    var usedDefault: Bool
    var evaluationReason: EvaluationReason

    func compacted() -> EvaluatedConfigEvent {
        var compacted = self
        compacted.defaultValue = defaultValue.compacted()
        compacted.evaluatedValue = evaluatedValue.compacted()
        return compacted
    }
}

extension EvaluatedConfigEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case key, type, defaultValue, requestedType, evaluatedValue, usedDefault, evaluationReason
        case contextID = "contextId"
        case evaluatedValueID = "evaluatedValueId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(contextID, forKey: .contextID)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encode(requestedType, forKey: .requestedType)
        try container.encode(evaluatedValue, forKey: .evaluatedValue)
        try container.encodeIfPresent(evaluatedValueID, forKey: .evaluatedValueID)
        try container.encode(usedDefault, forKey: .usedDefault)
        try container.encode(evaluationReason.rawValue, forKey: .evaluationReason)
    }
}

/// A group of identical events, reported once with the number of times it occurred.
struct AggregatedEvent<Event: Sendable>: Sendable {
    var startTime: Date
    var endTime: Date
    var count: Int
    var event: Event
}

extension AggregatedEvent: Encodable where Event: Encodable {
    private enum CodingKeys: String, CodingKey {
        case startTime, endTime, count, event
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startTime.telemetryTimestamp, forKey: .startTime)
        try container.encode(endTime.telemetryTimestamp, forKey: .endTime)
        try container.encode(count, forKey: .count)
        try container.encode(event, forKey: .event)
    }
}

/// Shared rather than built per timestamp, and locked rather than assumed thread-safe: this type
/// predates `Sendable` and does not document concurrent formatting.
private let telemetryTimestampFormatter = Locked<ISO8601DateFormatter>({
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}())

extension Date {
    /// The timestamp format the ConfigDirector API expects.
    var telemetryTimestamp: String {
        telemetryTimestampFormatter.withLock { $0.string(from: self) }
    }
}
