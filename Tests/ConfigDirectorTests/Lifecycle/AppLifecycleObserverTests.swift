@testable import ConfigDirector
import Foundation
import Testing

struct AppLifecycleObserverTests {
    private func makeObserver(
        _ center: NotificationCenter,
        background: Notification.Name? = .testDidEnterBackground,
        foreground: Notification.Name? = .testWillEnterForeground
    ) -> NotificationCenterLifecycleObserver {
        NotificationCenterLifecycleObserver(
            center: center,
            backgroundNotification: background,
            foregroundNotification: foreground
        )
    }

    private func record(_ observer: NotificationCenterLifecycleObserver) -> Locked<[AppLifecyclePhase]> {
        let phases = Locked<[AppLifecyclePhase]>([])
        observer.start { phase in phases.withLock { $0.append(phase) } }
        return phases
    }

    @Test func reportsBackgroundAndForegroundTransitions() {
        let center = NotificationCenter()
        let phases = record(makeObserver(center))

        center.post(name: .testDidEnterBackground, object: nil)
        center.post(name: .testWillEnterForeground, object: nil)

        #expect(phases.withLock { $0 } == [.background, .foreground])
    }

    @Test func stopsReportingOnceStopped() {
        let center = NotificationCenter()
        let observer = makeObserver(center)
        let phases = record(observer)

        observer.stop()
        center.post(name: .testDidEnterBackground, object: nil)

        #expect(phases.withLock { $0 }.isEmpty)
    }

    @Test func startingAgainReplacesTheEarlierRegistration() {
        let center = NotificationCenter()
        let observer = makeObserver(center)
        let phases = Locked<[AppLifecyclePhase]>([])
        let onChange: @Sendable (AppLifecyclePhase) -> Void = { phase in
            phases.withLock { $0.append(phase) }
        }

        observer.start(onChange: onChange)
        observer.start(onChange: onChange)
        center.post(name: .testDidEnterBackground, object: nil)

        #expect(phases.withLock { $0 } == [.background])
    }

    @Test func reportsNothingWhereThePlatformHasNoLifecycleNotifications() {
        let center = NotificationCenter()
        let phases = record(makeObserver(center, background: nil, foreground: nil))

        center.post(name: .testDidEnterBackground, object: nil)
        center.post(name: .testWillEnterForeground, object: nil)

        #expect(phases.withLock { $0 }.isEmpty)
    }
}
