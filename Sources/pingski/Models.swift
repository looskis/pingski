import Foundation

struct ValidationError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where K == DynamicKey {
    /// Returns the first present, non-null value among the given alias keys.
    func first<T: Decodable>(_ type: T.Type, _ keys: [String]) throws -> T? {
        for name in keys {
            let key = DynamicKey(name)
            guard contains(key) else { continue }
            if try decodeNil(forKey: key) { continue }
            do {
                return try decode(T.self, forKey: key)
            } catch let error as ValidationError {
                throw error
            } catch let error as DecodingError {
                if case .dataCorrupted(let context) = error, let nested = context.underlyingError as? ValidationError {
                    throw nested
                }
                throw ValidationError("field '\(name)' has the wrong type (expected \(T.self))")
            }
        }
        return nil
    }
}

enum NotificationPriority: String, Codable, CaseIterable {
    case passive
    case active
    case timeSensitive
    case critical

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "passive", "low": self = .passive
        case "active", "default", "normal": self = .active
        case "timesensitive", "high": self = .timeSensitive
        case "critical", "urgent": self = .critical
        default:
            throw ValidationError("priority must be one of passive, active, timeSensitive, critical (got '\(raw)')")
        }
    }
}

struct NotificationAction: Codable, Equatable {
    struct TextInput: Codable, Equatable {
        var buttonTitle: String?
        var placeholder: String?
    }

    var id: String
    var title: String
    var url: String?
    var destructive: Bool?
    var foreground: Bool?
    var authenticationRequired: Bool?
    var textInput: TextInput?

    init(id: String, title: String, url: String? = nil, destructive: Bool? = nil, foreground: Bool? = nil, authenticationRequired: Bool? = nil, textInput: TextInput? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.destructive = destructive
        self.foreground = foreground
        self.authenticationRequired = authenticationRequired
        self.textInput = textInput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        guard let title = try c.first(String.self, ["title", "label", "text"]), !title.isEmpty else {
            throw ValidationError("each action needs a non-empty 'title'")
        }
        self.title = title
        self.id = try c.first(String.self, ["id", "identifier"]) ?? NotificationAction.slug(title)
        self.url = try c.first(String.self, ["url", "link", "deep_link", "deepLink"])
        self.destructive = try c.first(Bool.self, ["destructive"])
        self.foreground = try c.first(Bool.self, ["foreground"])
        self.authenticationRequired = try c.first(Bool.self, ["authenticationRequired", "authentication_required"])
        if let input = try c.first(TextInput.self, ["textInput", "text_input", "input"]) {
            self.textInput = input
        } else if try c.first(Bool.self, ["textInput", "text_input", "input"]) == true {
            self.textInput = TextInput()
        }
        if id.isEmpty { throw ValidationError("action id must not be empty") }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url, destructive, foreground, authenticationRequired, textInput
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = title.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(mapped).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "action" : slug
    }
}

/// Incoming notification. Decoding accepts several aliases for each field (see OpenAPI spec).
struct NotificationRequest: Codable, Equatable {
    var id: String?
    var title: String
    var subtitle: String?
    var message: String?
    var icon: String?
    var url: String?
    var sound: String?
    var group: String?
    var badge: Int?
    var priority: NotificationPriority?
    var relevance: Double?
    var delay: Double?
    var actions: [NotificationAction]?
    var callbackURL: String?
    var data: JSONValue?

    init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        guard let title = try c.first(String.self, ["title", "header", "heading", "summary"]) else {
            throw ValidationError("missing required field 'title'")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("'title' must not be empty") }
        self.title = trimmed
        self.id = try c.first(String.self, ["id", "identifier"])
        self.subtitle = try c.first(String.self, ["subtitle", "subheader"])
        self.message = try c.first(String.self, ["message", "body", "text", "description"])
        self.icon = try c.first(String.self, ["icon", "logo", "image", "attachment"])
        self.url = try c.first(String.self, ["url", "link", "deep_link", "deepLink", "open"])
        self.sound = try c.first(String.self, ["sound"])
        self.group = try c.first(String.self, ["group", "thread", "threadIdentifier", "thread_id"])
        self.badge = try c.first(Int.self, ["badge"])
        self.priority = try c.first(NotificationPriority.self, ["priority", "interruptionLevel", "interruption_level", "level"])
        self.relevance = try c.first(Double.self, ["relevance", "relevanceScore", "relevance_score"])
        self.delay = try c.first(Double.self, ["delay", "delaySeconds", "delay_seconds", "in"])
        self.actions = try c.first([NotificationAction].self, ["actions", "buttons"])
        self.callbackURL = try c.first(String.self, ["callbackUrl", "callback_url", "callback", "webhook"])
        self.data = try c.first(JSONValue.self, ["data", "payload", "metadata", "userInfo"])
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, message, icon, url, sound, group, badge, priority, relevance, delay, actions
        case callbackURL = "callbackUrl"
        case data
    }

    func validate() throws {
        if let id, id.isEmpty { throw ValidationError("'id' must not be empty") }
        if let url {
            guard let parsed = URL(string: url), parsed.scheme != nil else {
                throw ValidationError("'url' must be an absolute URL with a scheme (got '\(url)')")
            }
        }
        if let callbackURL {
            guard let parsed = URL(string: callbackURL), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw ValidationError("'callbackUrl' must be an http(s) URL")
            }
        }
        if let relevance, !(0...1).contains(relevance) {
            throw ValidationError("'relevance' must be between 0 and 1")
        }
        if let delay, delay < 0 || delay > 60 * 60 * 24 * 365 {
            throw ValidationError("'delay' must be between 0 and 31536000 seconds")
        }
        if let badge, badge < 0 {
            throw ValidationError("'badge' must be zero or positive")
        }
        if let actions {
            if actions.count > 10 { throw ValidationError("at most 10 actions are supported") }
            var seen = Set<String>()
            for action in actions {
                guard seen.insert(action.id).inserted else {
                    throw ValidationError("duplicate action id '\(action.id)'")
                }
                if let actionURL = action.url, URL(string: actionURL)?.scheme == nil {
                    throw ValidationError("action '\(action.id)' url must be an absolute URL")
                }
            }
        }
    }
}

struct NotificationReceipt: Codable {
    enum Status: String, Codable {
        case delivered
        case scheduled
    }
    var id: String
    var status: Status
    var createdAt: Date
    var deliverAt: Date?
}

struct NotificationInfo: Codable {
    enum State: String, Codable {
        case pending
        case delivered
    }
    var id: String
    var state: State
    var title: String
    var subtitle: String?
    var message: String?
    var url: String?
    var group: String?
    var date: Date?
    var data: JSONValue?
}

struct NotificationList: Codable {
    var notifications: [NotificationInfo]
    var count: Int
}

enum EventType: String, Codable {
    case delivered
    case clicked
    case action
    case dismissed
    case removed
}

struct NotificationEvent: Codable {
    var seq: Int
    var type: EventType
    var notificationId: String
    var timestamp: Date
    var actionId: String?
    var text: String?
    var url: String?
    var title: String?
    var data: JSONValue?
}

struct EventList: Codable {
    var events: [NotificationEvent]
    var latestSeq: Int
}

struct HealthResponse: Codable {
    var status: String
    var version: String
    var uptimeSeconds: Int
    var authorization: String
    var bundleIdentifier: String?
    var macOSVersion: String
    var port: Int
}

struct AuthorizationResponse: Codable {
    var authorization: String
    var granted: Bool
}

struct IndexResponse: Codable {
    var name: String
    var version: String
    var docs: String
    var openapi: String
    var health: String
}

struct DeleteResponse: Codable {
    var removed: Bool
    var id: String?
}
