import Foundation

/// The user's context, sent to ConfigDirector and used to evaluate targeting rules.
public struct ConfigDirectorContext: Sendable, Equatable {
    /// The user's identifier. This should uniquely identify an application user.
    ///
    /// For anonymous users you may generate a UUID, or leave this unset and let the SDK generate a
    /// random one. This value segments users in percentage rollouts, so changing it can move a user
    /// into a different percentile.
    public var id: String?

    /// The user's display name. It is shown in the ConfigDirector dashboard and may be used by
    /// targeting rules.
    public var name: String?

    /// Arbitrary traits for the current user. They are shown in the ConfigDirector dashboard and may
    /// be used by targeting rules.
    ///
    /// ```swift
    /// ConfigDirectorContext(id: "user-123", traits: ["plan": "pro", "seats": 12, "beta": true])
    /// ```
    public var traits: [String: TraitValue]?

    /// Whether to treat this context as anonymous during evaluation. When `true`, the values are
    /// still used to evaluate targeting rules, but the context is not persisted and does not appear
    /// in the dashboard.
    public var isAnonymous: Bool?

    public init(
        id: String? = nil,
        name: String? = nil,
        traits: [String: TraitValue]? = nil,
        isAnonymous: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.traits = traits
        self.isAnonymous = isAnonymous
    }
}

public extension ConfigDirectorContext {
    /// A value a targeting rule can be written against.
    ///
    /// Values are usually written as literals rather than spelled out:
    ///
    /// ```swift
    /// let traits: [String: ConfigDirectorContext.TraitValue] = [
    ///     "plan": "pro",
    ///     "seats": 12,
    ///     "beta": true,
    ///     "regions": ["us-east", "eu-west"],
    /// ]
    /// ```
    enum TraitValue: Sendable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case array([TraitValue])
        case dictionary([String: TraitValue])
        case null
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: ConfigDirectorContext.TraitValue...) {
        self = .array(elements)
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ConfigDirectorContext.TraitValue)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension ConfigDirectorContext.TraitValue: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null
    }
}

extension ConfigDirectorContext.TraitValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .dictionary(values): try container.encode(values)
        case .null: try container.encodeNil()
        }
    }
}

extension ConfigDirectorContext: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, traits, anonymous
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(traits, forKey: .traits)
        try container.encodeIfPresent(isAnonymous, forKey: .anonymous)
    }
}

/// Metadata about your application. Including these values lets you write targeting rules against
/// them.
///
/// Each field left unset is filled in with what the running application's bundle reports, so most
/// applications do not need to set either one.
public struct ConfigDirectorMetaContext: Sendable, Equatable {
    /// Your application's name. Defaults to the bundle's `CFBundleDisplayName`, or `CFBundleName`.
    public var appName: String?

    /// Your application's version. Defaults to the bundle's `CFBundleShortVersionString`.
    public var appVersion: String?

    public init(appName: String? = nil, appVersion: String? = nil) {
        self.appName = appName
        self.appVersion = appVersion
    }
}
