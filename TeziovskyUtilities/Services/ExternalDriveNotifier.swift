import Foundation
import UserNotifications

/// Posts a local notification. A no-op outside an app bundle (no bundle identifier, or `swift test`),
/// where `UNUserNotificationCenter` would crash.
enum ExternalDriveNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didRequestAuthorization = false

    /// True only inside a real `.app`: `swift test` runs inside xctest, which has a bundle identifier but no
    /// app bundle, and the notification center throws there too.
    private static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks once per launch, when the first run starts, so the prompt appears while the owner is there.
    static func requestAuthorization() {
        guard canNotify else { return }
        requestAuthorizationOnce { _ in }
    }

    static func post(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        let asked = requestAuthorizationOnce { granted in
            if granted { center.add(request) }
        }
        if !asked { center.add(request) }
    }

    /// Requests authorization the first time only; returns whether this call asked.
    @discardableResult
    private static func requestAuthorizationOnce(then completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        let shouldRequest = lock.withLock {
            defer { didRequestAuthorization = true }
            return !didRequestAuthorization
        }
        guard shouldRequest else { return false }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
        return true
    }
}
