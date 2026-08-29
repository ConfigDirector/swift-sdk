import Foundation

/// An error raised by the ConfigDirector SDK.
public enum ConfigDirectorError: Error, Sendable, Equatable {
    /// The client was created without a usable client SDK key.
    case missingClientSDKKey

    /// The base URL given in ``ConnectionOptions/baseURL`` is not an absolute URL.
    case invalidBaseURL(URL)

    /// The connection to the ConfigDirector server failed, carrying the HTTP status code when one
    /// was received.
    case connectionFailed(message: String, statusCode: Int?)
}

extension ConfigDirectorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingClientSDKKey:
            "No client SDK key was provided. The client cannot be created without a valid client SDK key."
        case let .invalidBaseURL(url):
            "Invalid base URL '\(url)'. The base URL must be absolute."
        case let .connectionFailed(message, statusCode):
            statusCode.map { "\(message) (HTTP \($0))" } ?? message
        }
    }
}
