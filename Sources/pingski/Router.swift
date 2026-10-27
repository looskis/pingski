import Foundation

/// Maps HTTP requests to notification operations. Pure async code; no Network.framework here.
final class Router {
    let backend: NotificationBackend
    let events: EventBus
    let token: String?
    let port: Int
    private let startedAt = Date()
    private let decoder = JSONDecoder()

    /// Every route the server answers, used by tests to cross-check the OpenAPI document.
    static let routes: [(method: String, path: String)] = [
        ("GET", "/"), ("GET", "/health"), ("GET", "/openapi.json"), ("GET", "/docs"),
        ("POST", "/notify"), ("POST", "/notifications"), ("GET", "/notifications"), ("DELETE", "/notifications"),
        ("GET", "/notifications/{id}"), ("DELETE", "/notifications/{id}"),
        ("GET", "/events"), ("GET", "/events/stream"), ("POST", "/authorize"),
    ]

    private static let publicPaths: Set<String> = ["/", "/health", "/openapi.json", "/docs"]
    private static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type, X-API-Key, Last-Event-ID"),
    ]

    init(backend: NotificationBackend, events: EventBus, token: String?, port: Int) {
        self.backend = backend
        self.events = events
        self.token = token?.isEmpty == true ? nil : token
        self.port = port
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        var response = await route(request)
        response.headers.append(contentsOf: Router.corsHeaders)
        return response
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let method = request.method == "HEAD" ? "GET" : request.method
        let components = request.pathComponents
        let path = "/" + components.joined(separator: "/")

        if request.method == "OPTIONS" {
            return .empty(204)
        }
        if let denied = authorize(request, path: path) {
            return denied
        }

        do {
            switch (method, components) {
            case ("GET", []):
                return .json(200, IndexResponse(name: "pingski", version: pingskiVersion, docs: "/docs", openapi: "/openapi.json", health: "/health"))
            case ("GET", ["health"]):
                let status = await backend.authorizationStatus()
                return .json(200, HealthResponse(
                    status: "ok",
                    version: pingskiVersion,
                    uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
                    authorization: status,
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    port: port))
            case ("GET", ["openapi.json"]):
                return .rawJSON(200, OpenAPISpec.json)
            case ("GET", ["docs"]):
                return .html(200, DocsPage.html)
            case ("POST", ["notify"]), ("POST", ["notifications"]):
                return try await sendNotification(request)
            case ("GET", ["notifications"]):
                let items = await backend.list()
                return .json(200, NotificationList(notifications: items, count: items.count))
            case ("DELETE", ["notifications"]):
                await backend.removeAll()
                return .json(200, DeleteResponse(removed: true, id: nil))
            case ("GET", _) where components.count == 2 && components[0] == "notifications":
                let id = components[1]
                guard let info = await backend.get(id: id) else {
                    return .error(404, code: "not_found", message: "no pending or delivered notification with id '\(id)'")
                }
                return .json(200, info)
            case ("DELETE", _) where components.count == 2 && components[0] == "notifications":
                let id = components[1]
                let removed = await backend.remove(id: id)
                return .json(removed ? 200 : 404, DeleteResponse(removed: removed, id: id))
            case ("GET", ["events"]):
                return listEvents(request)
            case ("GET", ["events", "stream"]):
                return streamEvents(request)
            case ("POST", ["authorize"]):
                let provisional = ["1", "true", "yes"].contains(request.query["provisional"]?.lowercased() ?? "")
                let granted = await backend.requestAuthorization(provisional: provisional)
                let status = await backend.authorizationStatus()
                return .json(200, AuthorizationResponse(authorization: status, granted: granted))
            default:
                if Router.routes.contains(where: { $0.path == path || ($0.path.hasPrefix("/notifications/") && components.count == 2 && components[0] == "notifications") }) {
                    return .error(405, code: "method_not_allowed", message: "\(request.method) is not supported on \(path)")
                }
                return .error(404, code: "not_found", message: "no route for \(request.method) \(path)")
            }
        } catch let error as ValidationError {
            return .error(400, code: "validation_error", message: error.message)
        } catch let error as NotifierError {
            return .error(error.status, code: error.code, message: error.message)
        } catch let error as DecodingError {
            return .error(400, code: "bad_json", message: Router.describe(error))
        } catch {
            return .error(500, code: "internal_error", message: "\(error)")
        }
    }

    private func authorize(_ request: HTTPRequest, path: String) -> HTTPResponse? {
        guard let token else { return nil }
        if Router.publicPaths.contains(path) { return nil }
        var presented: String?
        if let auth = request.header("authorization") {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                presented = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        if presented == nil { presented = request.header("x-api-key") }
        if presented == nil { presented = request.query["token"] }
        guard let presented, Router.constantTimeEquals(presented, token) else {
            return HTTPResponse(status: 401,
                                headers: [("Content-Type", "application/json; charset=utf-8"), ("WWW-Authenticate", "Bearer realm=\"pingski\"")],
                                body: (try? HTTPResponse.encoder.encode(ErrorResponse(error: .init(code: "unauthorized", message: "missing or invalid token")))) ?? Data())
        }
        return nil
    }

    private func sendNotification(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard !request.body.isEmpty else {
            throw ValidationError("request body must be a JSON object with at least a 'title'")
        }
        if let contentType = request.header("content-type"), !contentType.lowercased().contains("json"), !contentType.lowercased().contains("text/plain") {
            return .error(415, code: "unsupported_media_type", message: "send application/json")
        }
        let notification = try decoder.decode(NotificationRequest.self, from: request.body)
        let receipt = try await backend.send(notification)
        return .json(receipt.status == .scheduled ? 202 : 201, receipt, headers: [("Location", "/notifications/\(receipt.id)")])
    }

    private func listEvents(_ request: HTTPRequest) -> HTTPResponse {
        let since = request.query["since"].flatMap(Int.init)
        let limit = min(max(request.query["limit"].flatMap(Int.init) ?? 100, 1), 1000)
        return .json(200, EventList(events: events.recent(since: since, limit: limit), latestSeq: events.latestSeq))
    }

    private func streamEvents(_ request: HTTPRequest) -> HTTPResponse {
        let lastSeen = request.header("last-event-id").flatMap(Int.init) ?? request.query["since"].flatMap(Int.init)
        let bus = events
        var response = HTTPResponse(status: 200, headers: [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("X-Accel-Buffering", "no"),
        ])
        response.stream = { writer in
            writer.write(": pingski event stream\nretry: 3000\n\n")
            for missed in bus.recent(since: lastSeen, limit: 1000) where lastSeen != nil {
                writer.write(Router.sseFrame(missed))
            }
            let subscription = bus.subscribe { event in
                writer.write(Router.sseFrame(event))
            }
            let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            heartbeat.schedule(deadline: .now() + 15, repeating: 15)
            heartbeat.setEventHandler { [weak writer] in
                writer?.write(": ping\n\n")
            }
            heartbeat.resume()
            writer.onClose = {
                heartbeat.cancel()
                bus.unsubscribe(subscription)
            }
        }
        return response
    }

    static func sseFrame(_ event: NotificationEvent) -> String {
        let payload = (try? HTTPResponse.encoder.encode(event)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "id: \(event.seq)\nevent: \(event.type.rawValue)\ndata: \(payload)\n\n"
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let ctx):
            if let underlying = ctx.underlyingError as? ValidationError { return underlying.message }
            return "invalid JSON: \(ctx.debugDescription)"
        case .keyNotFound(let key, _): return "missing field '\(key.stringValue)'"
        case .typeMismatch(let type, let ctx): return "wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): expected \(type)"
        case .valueNotFound(let type, let ctx): return "missing value at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): expected \(type)"
        @unknown default: return "invalid JSON"
        }
    }
}
