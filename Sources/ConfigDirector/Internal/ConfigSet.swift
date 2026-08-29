import Foundation

/// The type a config was declared with in the ConfigDirector dashboard.
enum ConfigType: String, Sendable, Codable, CaseIterable {
    case custom
    case boolean
    case string
    case integer
    case float
    case enumeration = "enum"
    case url
    case json

    init(from decoder: any Decoder) throws {
        let wireName = try decoder.singleValueContainer().decode(String.self)
        self = ConfigType(rawValue: wireName) ?? .custom
    }
}

/// The evaluated state of a single config, as returned by the server.
struct ConfigState: Sendable, Equatable, Decodable {
    var id: String
    var key: String
    var type: ConfigType

    /// The evaluated value, serialized as a string. It is `nil` when the config has no value for the
    /// current context.
    var value: String?

    /// An opaque identifier of the evaluated value, used for telemetry.
    var valueID: String?

    private enum CodingKeys: String, CodingKey {
        case id, key, type, value
        case valueID = "valueId"
    }

    init(id: String = "", key: String, type: ConfigType, value: String?, valueID: String? = nil) {
        self.id = id
        self.key = key
        self.type = type
        self.value = value
        self.valueID = valueID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        type = try container.decodeIfPresent(ConfigType.self, forKey: .type) ?? .custom
        value = try container.decodeIfPresent(String.self, forKey: .value)
        valueID = try container.decodeIfPresent(String.self, forKey: .valueID)
    }
}

/// Whether a ``ConfigSet`` carries the complete config state or only the configs that changed since
/// the last one.
enum ConfigSetKind: String, Sendable, Decodable {
    case full
    case delta

    init(from decoder: any Decoder) throws {
        let wireName = try decoder.singleValueContainer().decode(String.self)
        self = ConfigSetKind(rawValue: wireName) ?? .full
    }
}

/// A batch of config state received from the ConfigDirector server.
struct ConfigSet: Sendable, Equatable, Decodable {
    var environmentID: String
    var projectID: String
    var configs: [String: ConfigState]
    var kind: ConfigSetKind

    /// The server timestamp of this set, echoed back on the next polling request so the server can
    /// respond with a delta.
    var timestamp: String?

    private enum CodingKeys: String, CodingKey {
        case environmentID = "environmentId"
        case projectID = "projectId"
        case configs, kind, timestamp
    }

    init(
        environmentID: String = "",
        projectID: String = "",
        configs: [String: ConfigState],
        kind: ConfigSetKind = .full,
        timestamp: String? = nil
    ) {
        self.environmentID = environmentID
        self.projectID = projectID
        self.configs = configs
        self.kind = kind
        self.timestamp = timestamp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID) ?? ""
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        configs = try container.decodeIfPresent([String: ConfigState].self, forKey: .configs) ?? [:]
        kind = try container.decodeIfPresent(ConfigSetKind.self, forKey: .kind) ?? .full
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }
}
