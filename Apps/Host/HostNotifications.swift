import Foundation
import UserNotifications

/// Quiet notices for things the host's user should know about but needn't
/// answer (a viewer signed in, sign-in paused). Provisional authorization:
/// no permission prompt; they land in Notification Center without a banner
/// until the user chooses to see them more prominently.
enum HostNotifications {
    static func post(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
