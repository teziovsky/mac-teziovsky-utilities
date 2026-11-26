import Foundation
import UserNotifications

/// Posts a local notification. A no-op outside an app bundle (no bundle identifier, or `swift test`),
/// where `UNUserNotificationCenter` would crash.
enum ExternalDriveNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didRequestAuthorization = false

    static func post(title: String, body: String) {
        // `swift test` runs inside xctest, which has a bundle identifier but no app bundle; the
        // notification center throws there too, so require a real `.app`.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        let shouldRequest = lock.withLock {
            defer { didRequestAuthorization = true }
            return !didRequestAuthorization
        }
        if shouldRequest {
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { center.add(request) }
            }
        } else {
            center.add(request)
        }
    }
}
