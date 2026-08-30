import Foundation

#if canImport(WatchKit)
    import WatchKit
#elseif canImport(UIKit)
    import UIKit
#endif

enum AppLifecyclePhase: Sendable, Equatable {
    case background
    case foreground
}

/// Reports the application leaving and returning to the foreground.
protocol AppLifecycleObserver: Sendable {
    func start(onChange: @escaping @Sendable (AppLifecyclePhase) -> Void)
    func stop()
}

/// The lifecycle notifications the platform posts, or none where the platform has no notion of an
/// application being backgrounded.
enum AppLifecycleNotifications {
    #if canImport(WatchKit)
        static let background = WKExtension.applicationDidEnterBackgroundNotification
        static let foreground = WKExtension.applicationWillEnterForegroundNotification
    #elseif canImport(UIKit)
        static let background = UIApplication.didEnterBackgroundNotification
        static let foreground = UIApplication.willEnterForegroundNotification
    #else
        static let background: Notification.Name? = nil
        static let foreground: Notification.Name? = nil
    #endif
}

/// The default ``AppLifecycleObserver``.
///
/// A macOS app keeps running when it leaves the foreground, and keeps its connections with it, so
/// there is nothing to observe and nothing to pause.
final class NotificationCenterLifecycleObserver: AppLifecycleObserver {
    private let center: NotificationCenter
    private let backgroundNotification: Notification.Name?
    private let foregroundNotification: Notification.Name?
    private let tokens = Locked<[any NSObjectProtocol]>([])

    init(
        center: NotificationCenter = .default,
        backgroundNotification: Notification.Name? = AppLifecycleNotifications.background,
        foregroundNotification: Notification.Name? = AppLifecycleNotifications.foreground
    ) {
        self.center = center
        self.backgroundNotification = backgroundNotification
        self.foregroundNotification = foregroundNotification
    }

    func start(onChange: @escaping @Sendable (AppLifecyclePhase) -> Void) {
        stop()

        let started = [
            backgroundNotification.map { observe($0, as: .background, onChange) },
            foregroundNotification.map { observe($0, as: .foreground, onChange) },
        ]
        tokens.withLock { $0 = started.compactMap(\.self) }
    }

    func stop() {
        let observed = tokens.exchange(\.self, with: [])

        for token in observed {
            center.removeObserver(token)
        }
    }

    private func observe(
        _ name: Notification.Name,
        as phase: AppLifecyclePhase,
        _ onChange: @escaping @Sendable (AppLifecyclePhase) -> Void
    ) -> any NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: nil) { _ in onChange(phase) }
    }
}
