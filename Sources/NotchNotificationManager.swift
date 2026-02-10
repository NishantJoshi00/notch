import Cocoa
import UserNotifications

extension Notification.Name {
    static let notchNotificationTapped = Notification.Name("notchNotificationTapped")
}

class NotchNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotchNotificationManager()

    private var isAvailable = false

    private override init() {
        super.init()

        // UNUserNotificationCenter crashes without a bundle identifier (SPM executables)
        guard Bundle.main.bundleIdentifier != nil else {
            print("NotchNotificationManager: No bundle identifier — notifications unavailable.")
            return
        }

        UNUserNotificationCenter.current().delegate = self
        isAvailable = true
    }

    func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func sendNotification(body: String) {
        guard isAvailable else {
            print("Notch (notification): \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Notch"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // Show notification banner even when app is in foreground (but input window not visible)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // When user taps notification, open the input bar
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NotificationCenter.default.post(name: .notchNotificationTapped, object: nil)
        completionHandler()
    }
}
