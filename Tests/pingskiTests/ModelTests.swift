import XCTest
@testable import pingski

final class ModelTests: XCTestCase {
    private func decode(_ json: String) throws -> NotificationRequest {
        try JSONDecoder().decode(NotificationRequest.self, from: Data(json.utf8))
    }

    func testCanonicalFields() throws {
        let request = try decode("""
        {"id":"a","title":"T","subtitle":"S","message":"M","icon":"https://x/y.png","url":"slack://open","sound":"Glass",
         "group":"g","badge":3,"priority":"timeSensitive","relevance":0.5,"delay":10,
         "actions":[{"id":"ok","title":"OK","url":"https://x","destructive":true,"textInput":{"placeholder":"p"}}],
         "callbackUrl":"https://hook","data":{"n":1,"s":"x","b":true,"l":[1,2],"z":null}}
        """)
        XCTAssertEqual(request.id, "a")
        XCTAssertEqual(request.title, "T")
        XCTAssertEqual(request.subtitle, "S")
        XCTAssertEqual(request.message, "M")
        XCTAssertEqual(request.icon, "https://x/y.png")
        XCTAssertEqual(request.url, "slack://open")
        XCTAssertEqual(request.sound, "Glass")
        XCTAssertEqual(request.group, "g")
        XCTAssertEqual(request.badge, 3)
        XCTAssertEqual(request.priority, .timeSensitive)
        XCTAssertEqual(request.relevance, 0.5)
        XCTAssertEqual(request.delay, 10)
        XCTAssertEqual(request.actions?.count, 1)
        XCTAssertEqual(request.actions?.first?.textInput?.placeholder, "p")
        XCTAssertEqual(request.actions?.first?.destructive, true)
        XCTAssertEqual(request.callbackURL, "https://hook")
        XCTAssertEqual(request.data, .object(["n": .number(1), "s": .string("x"), "b": .bool(true), "l": .array([.number(1), .number(2)]), "z": .null]))
    }

    func testAliases() throws {
        let request = try decode("""
        {"header":"T","body":"B","logo":"/tmp/x.png","deep_link":"https://x","thread":"t","interruption_level":"time-sensitive",
         "delay_seconds":5,"buttons":[{"label":"Go"}],"callback_url":"https://hook","payload":{"a":1}}
        """)
        XCTAssertEqual(request.title, "T")
        XCTAssertEqual(request.message, "B")
        XCTAssertEqual(request.icon, "/tmp/x.png")
        XCTAssertEqual(request.url, "https://x")
        XCTAssertEqual(request.group, "t")
        XCTAssertEqual(request.priority, .timeSensitive)
        XCTAssertEqual(request.delay, 5)
        XCTAssertEqual(request.actions?.first?.id, "go")
        XCTAssertEqual(request.actions?.first?.title, "Go")
        XCTAssertEqual(request.callbackURL, "https://hook")
        XCTAssertEqual(request.data, .object(["a": .number(1)]))
    }

    func testNullAliasFallsThrough() throws {
        let request = try decode(#"{"title":"T","message":null,"body":"from body"}"#)
        XCTAssertEqual(request.message, "from body")
    }

    func testValidationErrors() {
        let cases: [(String, String)] = [
            (#"{"message":"x"}"#, "title"),
            (#"{"title":"  "}"#, "empty"),
            (#"{"title":"x","url":"nope"}"#, "url"),
            (#"{"title":"x","callbackUrl":"ftp://x"}"#, "callbackUrl"),
            (#"{"title":"x","relevance":2}"#, "relevance"),
            (#"{"title":"x","delay":-1}"#, "delay"),
            (#"{"title":"x","badge":-1}"#, "badge"),
            (#"{"title":"x","priority":"loud"}"#, "priority"),
            (#"{"title":"x","actions":[{"title":"A","id":"a"},{"title":"B","id":"a"}]}"#, "duplicate"),
            (#"{"title":"x","actions":[{"id":"a"}]}"#, "title"),
            (#"{"title":1}"#, "wrong type"),
        ]
        for (json, needle) in cases {
            XCTAssertThrowsError(try decode(json), json) { error in
                let message = (error as? ValidationError)?.message ?? ((error as? DecodingError).map { "\($0)" } ?? "\(error)")
                XCTAssertTrue(message.localizedCaseInsensitiveContains(needle), "expected '\(needle)' in '\(message)' for \(json)")
            }
        }
    }

    func testActionSlug() {
        XCTAssertEqual(NotificationAction.slug("View Logs!"), "view-logs")
        XCTAssertEqual(NotificationAction.slug("???"), "action")
    }

    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object(["a": .number(1.5), "b": .number(2), "c": .array([.string("x"), .null])])
        let string = value.jsonString
        XCTAssertEqual(string, #"{"a":1.5,"b":2,"c":["x",null]}"#)
        XCTAssertEqual(JSONValue.parse(string), value)
    }
}
