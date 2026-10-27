import XCTest
@testable import pingski

final class FakeBackend: NotificationBackend {
    var status = "authorized"
    var sent: [NotificationRequest] = []
    var stored: [NotificationInfo] = []

    func authorizationStatus() async -> String { status }
    func requestAuthorization(provisional: Bool) async -> Bool { status = provisional ? "provisional" : "authorized"; return true }
    func send(_ request: NotificationRequest) async throws -> NotificationReceipt {
        if status == "denied" { throw NotifierError(status: 403, code: "notifications_denied", message: "denied") }
        sent.append(request)
        let id = request.id ?? "generated"
        stored.append(NotificationInfo(id: id, state: (request.delay ?? 0) > 0 ? .pending : .delivered, title: request.title))
        return NotificationReceipt(id: id, status: (request.delay ?? 0) > 0 ? .scheduled : .delivered, createdAt: Date(), deliverAt: nil)
    }
    func list() async -> [NotificationInfo] { stored }
    func get(id: String) async -> NotificationInfo? { stored.first { $0.id == id } }
    func remove(id: String) async -> Bool {
        let before = stored.count
        stored.removeAll { $0.id == id }
        return stored.count != before
    }
    func removeAll() async { stored.removeAll() }
}

final class RouterTests: XCTestCase {
    private var backend: FakeBackend!
    private var events: EventBus!
    private var router: Router!

    override func setUp() {
        backend = FakeBackend()
        events = EventBus()
        router = Router(backend: backend, events: events, token: nil, port: 7464)
    }

    private func request(_ method: String, _ target: String, body: String? = nil, headers: [String: String] = [:]) -> HTTPRequest {
        var h = headers
        if body != nil { h["content-type"] = h["content-type"] ?? "application/json" }
        return HTTPRequest(method: method, target: target, version: "HTTP/1.1", headers: h, body: Data((body ?? "").utf8))
    }

    private func assertStatus(_ req: HTTPRequest, _ expected: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let response = await router.handle(req)
        XCTAssertEqual(response.status, expected, message, file: file, line: line)
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testIndexAndHealth() async throws {
        let index = await router.handle(request("GET", "/"))
        XCTAssertEqual(index.status, 200)
        XCTAssertEqual(try json(index)["docs"] as? String, "/docs")
        let health = await router.handle(request("GET", "/health"))
        XCTAssertEqual(try json(health)["authorization"] as? String, "authorized")
        XCTAssertTrue(health.headers.contains { $0.0 == "Access-Control-Allow-Origin" })
    }

    func testSendDeliveredAndScheduled() async throws {
        let delivered = await router.handle(request("POST", "/notify", body: #"{"title":"Hi","id":"n1"}"#))
        XCTAssertEqual(delivered.status, 201)
        XCTAssertEqual(try json(delivered)["status"] as? String, "delivered")
        XCTAssertTrue(delivered.headers.contains { $0.0 == "Location" && $0.1 == "/notifications/n1" })

        let scheduled = await router.handle(request("POST", "/notifications", body: #"{"title":"Later","delay":30}"#))
        XCTAssertEqual(scheduled.status, 202)
        XCTAssertEqual(backend.sent.count, 2)
    }

    func testSendErrors() async throws {
        await assertStatus(request("POST", "/notify", body: ""), 400)
        await assertStatus(request("POST", "/notify", body: "{nope"), 400)
        await assertStatus(request("POST", "/notify", body: #"{"message":"x"}"#), 400)
        await assertStatus(request("POST", "/notify", body: "<x/>", headers: ["content-type": "text/xml"]), 415)
        backend.status = "denied"
        let denied = await router.handle(request("POST", "/notify", body: #"{"title":"x"}"#))
        XCTAssertEqual(denied.status, 403)
        XCTAssertEqual(((try json(denied)["error"] as? [String: Any])?["code"]) as? String, "notifications_denied")
    }

    func testListGetDelete() async throws {
        _ = await router.handle(request("POST", "/notify", body: #"{"title":"A","id":"a"}"#))
        _ = await router.handle(request("POST", "/notify", body: #"{"title":"B","id":"b"}"#))
        let list = await router.handle(request("GET", "/notifications"))
        XCTAssertEqual(try json(list)["count"] as? Int, 2)
        await assertStatus(request("GET", "/notifications/a"), 200)
        await assertStatus(request("GET", "/notifications/zzz"), 404)
        await assertStatus(request("DELETE", "/notifications/a"), 200)
        await assertStatus(request("DELETE", "/notifications/a"), 404)
        await assertStatus(request("DELETE", "/notifications"), 200)
        let after = await router.handle(request("GET", "/notifications"))
        XCTAssertEqual(try json(after)["count"] as? Int, 0)
    }

    func testUnknownRoutes() async {
        await assertStatus(request("GET", "/nope"), 404)
        await assertStatus(request("PUT", "/notifications"), 405)
        await assertStatus(request("OPTIONS", "/notify"), 204)
        await assertStatus(request("HEAD", "/health"), 200)
    }

    func testTokenAuth() async {
        router = Router(backend: backend, events: events, token: "s3cret", port: 1)
        await assertStatus(request("GET", "/health"), 200, "health is public")
        await assertStatus(request("GET", "/openapi.json"), 200, "spec is public")
        let denied = await router.handle(request("GET", "/notifications"))
        XCTAssertEqual(denied.status, 401)
        XCTAssertTrue(denied.headers.contains { $0.0 == "WWW-Authenticate" })
        await assertStatus(request("GET", "/notifications", headers: ["authorization": "Bearer wrong"]), 401)
        await assertStatus(request("GET", "/notifications", headers: ["authorization": "Bearer s3cret"]), 200)
        await assertStatus(request("GET", "/notifications", headers: ["x-api-key": "s3cret"]), 200)
        await assertStatus(request("GET", "/notifications?token=s3cret"), 200)
    }

    func testEventsListAndSince() async throws {
        events.publish(type: .delivered, notificationId: "a")
        events.publish(type: .clicked, notificationId: "a", url: "https://x")
        let all = try json(await router.handle(request("GET", "/events")))
        XCTAssertEqual((all["events"] as? [Any])?.count, 2)
        XCTAssertEqual(all["latestSeq"] as? Int, 2)
        let since = try json(await router.handle(request("GET", "/events?since=1")))
        XCTAssertEqual((since["events"] as? [[String: Any]])?.first?["type"] as? String, "clicked")
    }

    func testAuthorizeEndpoint() async throws {
        backend.status = "notDetermined"
        let response = await router.handle(request("POST", "/authorize?provisional=true"))
        XCTAssertEqual(try json(response)["authorization"] as? String, "provisional")
        XCTAssertEqual(try json(response)["granted"] as? Bool, true)
    }

    func testSSEFrameFormat() {
        let event = NotificationEvent(seq: 7, type: .action, notificationId: "n", timestamp: Date(), actionId: "ok")
        let frame = Router.sseFrame(event)
        XCTAssertTrue(frame.hasPrefix("id: 7\nevent: action\ndata: {"))
        XCTAssertTrue(frame.hasSuffix("}\n\n"))
        XCTAssertTrue(frame.contains("\"actionId\":\"ok\""))
    }
}
