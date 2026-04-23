import Combine
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    private static let enabledKey = "notificationEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    var onNotificationClicked: ((String) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()

        EventBus.shared.stateChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                guard let self, self.isEnabled else { return }
                switch event.newState {
                case .permissionRequest:
                    self.showPermissionNotification(
                        sessionId: event.sessionId,
                        label: event.label,
                        toolDescription: event.toolDescription
                    )
                case .taskComplete:
                    self.showTaskCompleteNotification(
                        sessionId: event.sessionId,
                        label: event.label
                    )
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("[NotificationManager] authorization error: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sessionId = userInfo["sessionId"] as? String {
            onNotificationClicked?(sessionId)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // LSUIElement apps are always "foreground" — must explicitly show banner
        completionHandler(.banner)
    }

    // MARK: - Private

    private func showPermissionNotification(sessionId: String, label: String?, toolDescription: String?) {
        let content = UNMutableNotificationContent()
        content.title = label ?? "Claude Code"
        content.body = toolDescription ?? "Permission requested"
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "perm-\(sessionId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func showTaskCompleteNotification(sessionId: String, label: String?) {
        let content = UNMutableNotificationContent()
        content.title = label ?? "Claude Code"
        content.body = "Task complete ✓"
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "task-\(sessionId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
