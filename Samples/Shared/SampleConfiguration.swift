import ConfigDirector
import Foundation

/// The values the app is built with, which come from `Config.local.xcconfig` by way of the
/// `Info.plist`. See the README.
enum SampleConfiguration {
    static func makeClient() -> ConfigDirectorClient? {
        guard let clientSDKKey = infoValue(for: "ConfigDirectorSDKKey") else { return nil }

        return try? ConfigDirectorClient(
            clientSDKKey: clientSDKKey,
            // The SDK logs at `warn` by default; turned up here so the connection can be followed
            // in the console.
            options: ConfigDirectorClientOptions(logger: ConsoleLogger(level: .debug))
        )
    }

    /// The context targeting rules are evaluated against.
    static var context: ConfigDirectorContext {
        ConfigDirectorContext(
            id: infoValue(for: "ConfigDirectorUserID"),
            name: infoValue(for: "ConfigDirectorUserName"),
            traits: infoValue(for: "ConfigDirectorUserRole").map { ["role": .string($0)] }
        )
    }

    private static func infoValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

/// The identities the sample can evaluate configs against. Switching between them calls
/// `updateContext`, which reconnects and re-evaluates every config.
enum SampleUser: String, CaseIterable, Identifiable {
    case configured
    case betaTester
    case anonymous

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .configured: "Configured"
        case .betaTester: "Beta tester"
        case .anonymous: "Anonymous"
        }
    }

    var context: ConfigDirectorContext {
        switch self {
        case .configured:
            SampleConfiguration.context
        case .betaTester:
            ConfigDirectorContext(id: "beta-tester", name: "Beta Tester", traits: ["role": "beta"])
        case .anonymous:
            ConfigDirectorContext(isAnonymous: true)
        }
    }
}
