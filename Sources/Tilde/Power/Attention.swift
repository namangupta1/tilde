import AppKit
import UserNotifications

struct CommandRecord: Identifiable, Hashable {
    let id = UUID()
    var command: String
    var started: Date
    var duration: TimeInterval?
    var exitCode: Int32?
    var directory: String?

    var finished: Bool { duration != nil }
}

/// Desktop notifications + per-tab "needs attention" flags.
@MainActor
enum Notifier {
    static var notifyEnabled: Bool { UserDefaults.standard.object(forKey: "notifyLongCommands") as? Bool ?? true }
    static var threshold: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "notifyThreshold")
        return v > 0 ? v : 10
    }

    /// UNUserNotificationCenter crashes when the process has no bundle (e.g. `swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    private static var requested = false

    static func requestAuthorizationIfNeeded() {
        guard available, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, tabID: UUID?) {
        guard available, notifyEnabled else { return }
        requestAuthorizationIfNeeded()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let tabID { c.userInfo = ["tabID": tabID.uuidString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func format(_ d: TimeInterval) -> String {
        if d < 60 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60, s = Int(d) % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }
}

/// Routes clicks on notifications back to the tab that posted them.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func install() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["tabID"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id { TildeApp.store.select(id) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
