import Foundation

/// In-memory event log with fan-out to SSE subscribers and HTTP webhooks.
final class EventBus {
    private let lock = NSLock()
    private var seq = 0
    private var history: [NotificationEvent] = []
    private var subscribers: [UUID: (NotificationEvent) -> Void] = [:]
    private let maxHistory = 1000
    let globalWebhook: URL?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init(globalWebhook: URL? = nil) {
        self.globalWebhook = globalWebhook
    }

    var latestSeq: Int {
        lock.lock(); defer { lock.unlock() }
        return seq
    }

    @discardableResult
    func publish(type: EventType, notificationId: String, title: String? = nil, actionId: String? = nil, text: String? = nil, url: String? = nil, data: JSONValue? = nil, webhook: URL? = nil) -> NotificationEvent {
        lock.lock()
        seq += 1
        let event = NotificationEvent(seq: seq, type: type, notificationId: notificationId, timestamp: Date(), actionId: actionId, text: text, url: url, title: title, data: data)
        history.append(event)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        let targets = Array(subscribers.values)
        lock.unlock()

        Log.debug("event #\(event.seq) \(type.rawValue) \(notificationId)\(actionId.map { " action=\($0)" } ?? "")")
        for target in targets { target(event) }
        var hooks: [URL] = []
        if let globalWebhook { hooks.append(globalWebhook) }
        if let webhook, webhook != globalWebhook { hooks.append(webhook) }
        for hook in hooks { deliver(event, to: hook) }
        return event
    }

    func recent(since: Int? = nil, limit: Int = 100) -> [NotificationEvent] {
        lock.lock(); defer { lock.unlock() }
        var slice = history
        if let since { slice = slice.filter { $0.seq > since } }
        if slice.count > limit { slice = Array(slice.suffix(limit)) }
        return slice
    }

    func subscribe(_ callback: @escaping (NotificationEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = callback; lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.lock(); subscribers[id] = nil; lock.unlock()
    }

    private func deliver(_ event: NotificationEvent, to url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("pingski/\(pingskiVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(event.type.rawValue, forHTTPHeaderField: "X-Pingski-Event")
        request.httpBody = try? HTTPResponse.encoder.encode(event)
        session.dataTask(with: request) { _, response, error in
            if let error {
                Log.warn("webhook \(url) failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                Log.warn("webhook \(url) returned HTTP \(http.statusCode)")
            } else {
                Log.debug("webhook \(url) delivered event #\(event.seq)")
            }
        }.resume()
    }
}
