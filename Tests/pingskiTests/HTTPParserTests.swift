import XCTest
@testable import pingski

final class HTTPParserTests: XCTestCase {
    private func parse(_ raw: String) throws -> (HTTPParseResult, Data) {
        var buffer = Data(raw.utf8)
        let result = try HTTPParser.parse(&buffer)
        return (result, buffer)
    }

    func testParsesSimpleGet() throws {
        let (result, rest) = try parse("GET /health?x=1&y=a%20b HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n")
        guard case .complete(let request) = result else { return XCTFail("expected complete") }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/health")
        XCTAssertEqual(request.query["x"], "1")
        XCTAssertEqual(request.query["y"], "a b")
        XCTAssertEqual(request.header("Host"), "localhost")
        XCTAssertTrue(request.wantsKeepAlive)
        XCTAssertTrue(rest.isEmpty)
    }

    func testIncompleteHeadersWaits() throws {
        let (result, rest) = try parse("POST /notify HTTP/1.1\r\nContent-Length: 5\r\n")
        guard case .incomplete = result else { return XCTFail("expected incomplete") }
        XCTAssertFalse(rest.isEmpty)
    }

    func testContentLengthBodyAndPipelining() throws {
        var buffer = Data("POST /notify HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\n\r\n".utf8)
        guard case .complete(let first) = try HTTPParser.parse(&buffer) else { return XCTFail() }
        XCTAssertEqual(String(decoding: first.body, as: UTF8.self), "hello")
        guard case .complete(let second) = try HTTPParser.parse(&buffer) else { return XCTFail() }
        XCTAssertEqual(second.path, "/")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPartialBodyWaitsAndReportsExpectContinue() throws {
        let (result, _) = try parse("POST /notify HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\nabc")
        guard case .incomplete(let expects) = result else { return XCTFail() }
        XCTAssertTrue(expects)
    }

    func testChunkedBody() throws {
        let (result, rest) = try parse("POST /notify HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n")
        guard case .complete(let request) = result else { return XCTFail() }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello world")
        XCTAssertTrue(rest.isEmpty)
    }

    func testChunkedWithTrailers() throws {
        let (result, _) = try parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\nX-Trailer: 1\r\n\r\n")
        guard case .complete(let request) = result else { return XCTFail() }
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hi")
    }

    func testIncompleteChunkedWaits() throws {
        let (result, _) = try parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel")
        guard case .incomplete = result else { return XCTFail() }
    }

    func testMalformedRequestLine() {
        XCTAssertThrowsError(try parse("BLAH\r\n\r\n"))
        XCTAssertThrowsError(try parse("GET / HTTP/1.1\r\nNoColon\r\n\r\n"))
        XCTAssertThrowsError(try parse("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n"))
    }

    func testBodyTooLarge() {
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n")) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge)
        }
    }

    func testHeadersTooLarge() {
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes + 10)
        XCTAssertThrowsError(try parse(huge)) { error in
            XCTAssertEqual(error as? HTTPParseError, .headersTooLarge)
        }
    }

    func testHTTP10ClosesByDefault() throws {
        let (result, _) = try parse("GET / HTTP/1.0\r\n\r\n")
        guard case .complete(let request) = result else { return XCTFail() }
        XCTAssertFalse(request.wantsKeepAlive)
    }

    func testRepeatedHeadersAreJoined() throws {
        let (result, _) = try parse("GET / HTTP/1.1\r\nX-A: 1\r\nx-a: 2\r\n\r\n")
        guard case .complete(let request) = result else { return XCTFail() }
        XCTAssertEqual(request.header("X-A"), "1, 2")
    }
}
