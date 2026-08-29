import Foundation

struct SDKMetaContext: Sendable, Encodable {
    var sdkName: String
    var sdkVersion: String
    var appName: String?
    var appVersion: String?
    var userAgent: String?
}

enum AppInfo {
    /// Fills in whichever of the app name and version the application did not provide with what the
    /// running application's bundle reports.
    static func metaContext(
        metadata: ConfigDirectorMetaContext?,
        bundle: Bundle = .main
    ) -> SDKMetaContext {
        SDKMetaContext(
            sdkName: Constants.sdkName,
            sdkVersion: Constants.sdkVersion,
            appName: metadata?.appName
                ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            appVersion: metadata?.appVersion
                ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            userAgent: userAgent
        )
    }

    /// The platform name, matching what the other ConfigDirector client SDKs report.
    static var userAgent: String {
        #if targetEnvironment(macCatalyst)
            "macCatalyst"
        #elseif os(iOS)
            "iOS"
        #elseif os(macOS)
            "macOS"
        #elseif os(tvOS)
            "tvOS"
        #elseif os(watchOS)
            "watchOS"
        #elseif os(visionOS)
            "visionOS"
        #else
            "unknown"
        #endif
    }
}
