import BranchCore
import Foundation
import UserNotifications

/// Posts user notifications for backup events. Silently does nothing outside an .app bundle,
/// where the notification center isn't available.
@MainActor
final class Notifier {
    var enabled = true
    private var authorized = false

    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorization() {
        guard available, enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(_ event: BackupEvent) {
        guard available, enabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        if case .needsAttention = event { content.sound = .default }
        if case .quota(let level) = event, level >= .insufficient { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
