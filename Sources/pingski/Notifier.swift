import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Abstraction over the notification system so the router can be tested without a bundle.
protocol NotificationBackend: AnyObject {
    func authorizationStatus() async -> String
    func requestAuthorization(provisional: Bool) async -> Bool
    func send(_ request: NotificationRequest) async throws -> NotificationReceipt
    func list() async -> [NotificationInfo]
    func get(id: String) async -> NotificationInfo?
    func remove(id: String) async -> Bool
    func removeAll() async
}

struct NotifierError: Error, CustomStringConvertible {
    let status: Int
    let code: String
    let message: String
    var description: String { message }
}

private enum UserInfoKey {
    static let marker = "pingski"
    static let url = "url"
    static let callback = "callback_url"
    static let data = "data_json"
    static let actionURLs = "action_urls"
}

final class Notifier: NSObject, NotificationBackend, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let events: EventBus
    private let lock = NSLock()
    private var categories: [String: UNNotificationCategory] = [:]
    private static let defaultCategory = "pingski.default"
    /// When true, first-time authorization is requested provisionally (no prompt, quiet delivery).
    var provisional = false

    init(events: EventBus, provisional: Bool = false) {
        self.center = UNUserNotificationCenter.current()
        self.events = events
        self.provisional = provisional
        super.init()
        center.delegate = self
        let base = UNNotificationCategory(identifier: Notifier.defaultCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction])
        categories[Notifier.defaultCategory] = base
        center.setNotificationCategories([base])
    }

    // MARK: NotificationBackend

    func authorizationStatus() async -> String {
        let settings = await center.notificationSettings()
        return Notifier.describe(settings.authorizationStatus)
    }

    func requestAuthorization(provisional: Bool) async -> Bool {
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if provisional { options.insert(.provisional) }
        do {
            return try await center.requestAuthorization(options: options)
        } catch {
            Log.warn("authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    func send(_ request: NotificationRequest) async throws -> NotificationReceipt {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            throw NotifierError(status: 403, code: "notifications_denied", message: "Notifications for Pingski are disabled. Enable them in System Settings > Notifications > Pingski.")
        case .notDetermined:
            let granted = await requestAuthorization(provisional: provisional)
            if !granted {
                throw NotifierError(status: 403, code: "notifications_not_authorized", message: "Notification permission was not granted. Approve the system prompt or enable Pingski in System Settings > Notifications.")
            }
        default:
            break
        }

        let id = request.id ?? UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let subtitle = request.subtitle { content.subtitle = subtitle }
        content.body = request.message ?? ""
        content.sound = Notifier.sound(for: request.sound, critical: request.priority == .critical)
        if let group = request.group { content.threadIdentifier = group }
        if let badge = request.badge { content.badge = NSNumber(value: badge) }
        if let priority = request.priority {
            switch priority {
            case .passive: content.interruptionLevel = .passive
            case .active: content.interruptionLevel = .active
            case .timeSensitive: content.interruptionLevel = .timeSensitive
            case .critical: content.interruptionLevel = .critical
            }
        }
        if let relevance = request.relevance { content.relevanceScore = relevance }

        var userInfo: [String: Any] = [UserInfoKey.marker: true]
        if let url = request.url { userInfo[UserInfoKey.url] = url }
        if let callback = request.callbackURL { userInfo[UserInfoKey.callback] = callback }
        if let data = request.data { userInfo[UserInfoKey.data] = data.jsonString }

        if let actions = request.actions, !actions.isEmpty {
            content.categoryIdentifier = registerCategory(for: actions)
            var actionURLs: [String: String] = [:]
            for action in actions {
                if let url = action.url { actionURLs[action.id] = url }
            }
            if !actionURLs.isEmpty { userInfo[UserInfoKey.actionURLs] = actionURLs }
        } else {
            content.categoryIdentifier = Notifier.defaultCategory
        }
        content.userInfo = userInfo

        if let icon = request.icon {
            content.attachments = [try await AttachmentLoader.load(icon)]
        }

        var trigger: UNNotificationTrigger?
        var deliverAt: Date?
        if let delay = request.delay, delay > 0 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            deliverAt = Date().addingTimeInterval(delay)
        }

        let unRequest = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(unRequest)
        } catch {
            throw NotifierError(status: 500, code: "delivery_failed", message: "UNUserNotificationCenter rejected the notification: \(error.localizedDescription)")
        }

        if trigger == nil {
            events.publish(type: .delivered, notificationId: id, title: request.title, url: request.url, data: request.data, webhook: request.callbackURL.flatMap(URL.init(string:)))
        }
        return NotificationReceipt(id: id, status: trigger == nil ? .delivered : .scheduled, createdAt: Date(), deliverAt: deliverAt)
    }

    func list() async -> [NotificationInfo] {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        var out: [NotificationInfo] = []
        for request in pending {
            var info = Notifier.info(from: request, state: .pending)
            if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
                info.date = trigger.nextTriggerDate()
            } else if let trigger = request.trigger as? UNCalendarNotificationTrigger {
                info.date = trigger.nextTriggerDate()
            }
            out.append(info)
        }
        for notification in delivered {
            var info = Notifier.info(from: notification.request, state: .delivered)
            info.date = notification.date
            out.append(info)
        }
        return out
    }

    func get(id: String) async -> NotificationInfo? {
        await list().first { $0.id == id }
    }

    func remove(id: String) async -> Bool {
        let existed = await get(id: id) != nil
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
        if existed {
            events.publish(type: .removed, notificationId: id)
        }
        return existed
    }

    func removeAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: Categories

    private func registerCategory(for actions: [NotificationAction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = (try? encoder.encode(actions)) ?? Data()
        let digest = SHA256.hash(data: fingerprint).prefix(8).map { String(format: "%02x", $0) }.joined()
        let identifier = "pingski.\(digest)"

        lock.lock()
        defer { lock.unlock() }
        if categories[identifier] != nil { return identifier }

        let unActions: [UNNotificationAction] = actions.map { action in
            var options: UNNotificationActionOptions = []
            if action.destructive == true { options.insert(.destructive) }
            if action.foreground == true { options.insert(.foreground) }
            if action.authenticationRequired == true { options.insert(.authenticationRequired) }
            if let input = action.textInput {
                return UNTextInputNotificationAction(identifier: action.id, title: action.title, options: options, textInputButtonTitle: input.buttonTitle ?? "Send", textInputPlaceholder: input.placeholder ?? "")
            }
            return UNNotificationAction(identifier: action.id, title: action.title, options: options)
        }
        let category = UNNotificationCategory(identifier: identifier, actions: unActions, intentIdentifiers: [], options: [.customDismissAction])
        categories[identifier] = category
        center.setNotificationCategories(Set(categories.values))
        Log.debug("registered category \(identifier) with \(actions.count) action(s)")
        return identifier
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let userInfo = request.content.userInfo
        let id = request.identifier
        let callback = (userInfo[UserInfoKey.callback] as? String).flatMap(URL.init(string:))
        let data = (userInfo[UserInfoKey.data] as? String).flatMap(JSONValue.parse)
        let text = (response as? UNTextInputNotificationResponse)?.userText

        var type: EventType
        var actionId: String?
        var urlToOpen: String?

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            type = .clicked
            urlToOpen = userInfo[UserInfoKey.url] as? String
        case UNNotificationDismissActionIdentifier:
            type = .dismissed
        default:
            type = .action
            actionId = response.actionIdentifier
            urlToOpen = (userInfo[UserInfoKey.actionURLs] as? [String: String])?[response.actionIdentifier]
        }

        if let urlToOpen, let url = URL(string: urlToOpen) {
            DispatchQueue.main.async {
                if NSWorkspace.shared.open(url) {
                    Log.info("opened \(url) for notification \(id)")
                } else {
                    Log.warn("failed to open \(url) for notification \(id)")
                }
            }
        }

        events.publish(type: type, notificationId: id, title: request.content.title, actionId: actionId, text: text, url: urlToOpen, data: data, webhook: callback)
        completionHandler()
    }

    // MARK: Helpers

    private static func info(from request: UNNotificationRequest, state: NotificationInfo.State) -> NotificationInfo {
        let content = request.content
        let userInfo = content.userInfo
        return NotificationInfo(
            id: request.identifier,
            state: state,
            title: content.title,
            subtitle: content.subtitle.isEmpty ? nil : content.subtitle,
            message: content.body.isEmpty ? nil : content.body,
            url: userInfo[UserInfoKey.url] as? String,
            group: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
            date: nil,
            data: (userInfo[UserInfoKey.data] as? String).flatMap(JSONValue.parse)
        )
    }

    private static func sound(for name: String?, critical: Bool) -> UNNotificationSound? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return critical ? .defaultCritical : .default
        }
        switch raw.lowercased() {
        case "default": return critical ? .defaultCritical : .default
        case "none", "silent", "off", "false": return nil
        case "critical": return .defaultCritical
        default:
            let fileName = raw.contains(".") ? raw : raw + ".aiff"
            return UNNotificationSound(named: UNNotificationSoundName(fileName))
        }
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}
