import AppKit
import UserNotifications

/// Notifications for finished answers and downloads.
enum Notifier {
    private static let delegate = NotificationDelegate()

    static func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(service: Service) {
        let content = UNMutableNotificationContent()
        content.title = LF("%@ er ferdig", service.title)
        content.body = L("Svaret ditt er klart. Klikk for å åpne.")
        // Sound is handled by the "Play a sound" setting instead.
        content.userInfo = ["service": service.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension Notifier {
    static func postDownload(_ url: URL) {
        let content = UNMutableNotificationContent()
        content.title = L("Lastet ned")
        content.body = url.lastPathComponent
        content.userInfo = ["reveal": url.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let path = info["reveal"] as? String {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
            completionHandler()
            return
        }
        let raw = info["service"] as? String
        Task { @MainActor in
            if let raw, let service = Service(rawValue: raw) {
                AppState.shared.switchTo(service)
            }
            PanelController.shared.show(full: true)
        }
        completionHandler()
    }
}
