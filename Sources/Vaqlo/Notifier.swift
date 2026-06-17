import Foundation
import UserNotifications

/// Системные уведомления: предложение записать встречу и информирование об автозаписи.
enum Notifier {
    static let recordCategory = "VAQLO_MEETING"
    static let recordAction = "VAQLO_RECORD_NOW"
    static let firstSeenCategory = "VAQLO_FIRST_SEEN"
    static let actionAlways = "VAQLO_POLICY_ALWAYS"
    static let actionAsk = "VAQLO_POLICY_ASK"
    static let actionNever = "VAQLO_POLICY_NEVER"

    @MainActor
    static func configure(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate

        let record = UNNotificationAction(identifier: recordAction, title: L("notif.record"), options: [.foreground])
        let meeting = UNNotificationCategory(
            identifier: recordCategory, actions: [record], intentIdentifiers: [], options: []
        )

        // Первая встреча с приложением — три варианта политики.
        let always = UNNotificationAction(identifier: actionAlways, title: L("notif.policy.always"), options: [.foreground])
        let ask = UNNotificationAction(identifier: actionAsk, title: L("notif.policy.ask"), options: [.foreground])
        let never = UNNotificationAction(identifier: actionNever, title: L("notif.policy.never"), options: [.destructive])
        let firstSeen = UNNotificationCategory(
            identifier: firstSeenCategory, actions: [always, ask, never], intentIdentifiers: [], options: []
        )

        center.setNotificationCategories([meeting, firstSeen])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func askFirstSeen(appName: String, bundleID: String) {
        let content = UNMutableNotificationContent()
        content.title = L("notif.firstSeen.title")
        content.body = L("notif.firstSeen.body", appName)
        content.categoryIdentifier = firstSeenCategory
        content.userInfo = ["bundleID": bundleID, "name": appName]
        content.sound = .default
        deliver(content, id: "first-seen-\(bundleID)")
    }

    @MainActor
    static func askToRecord(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = L("notif.meeting.title")
        content.body = L("notif.meeting.body", appName)
        content.categoryIdentifier = recordCategory
        content.sound = .default
        deliver(content, id: "meeting-prompt")
    }

    static func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        deliver(content, id: UUID().uuidString)
    }

    private static func deliver(_ content: UNNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
