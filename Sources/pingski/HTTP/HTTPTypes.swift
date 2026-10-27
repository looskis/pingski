import Foundation

struct HTTPRequest {
    var method: String
    var target: String
    var version: String
    /// Header names are lowercased. Repeated headers are joined with ", ".
    var headers: [String: String]
    var body: Data

    var path: String {
        if let q = target.firstIndex(of: "?") { return String(target[..<q]) }
        return target
    }

    var pathComponents: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
    }

    var query: [String: String] {
        guard let q = target.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeQueryComponent(String(kv[0]))
            let value = kv.count > 1 ? decodeQueryComponent(String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var wantsKeepAlive: Bool {
        let connection = header("connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
    }

    private func decodeQueryComponent(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

/// Sink handed to streaming responses (server-sent events). All methods are thread-safe.
protocol HTTPStreamWriter: AnyObject {
    var isOpen: Bool { get }
    var onClose: (() -> Void)? { get set }
    func write(_ data: Data)
    func close()
}

extension HTTPStreamWriter {
    func write(_ string: String) { write(Data(string.utf8)) }
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()
    /// When set, the connection is handed to this closure after the headers are written and
    /// stays open until the writer is closed. `body` is ignored.
    var stream: ((HTTPStreamWriter) -> Void)? = nil

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func json<T: Encodable>(_ status: Int = 200, _ value: T, headers: [(String, String)] = []) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")] + headers, body: data)
    }

    static func rawJSON(_ status: Int = 200, _ json: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: Data(json.utf8))
    }

    static func html(_ status: Int = 200, _ html: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8")], body: Data(html.utf8))
    }

    static func text(_ status: Int = 200, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    static func empty(_ status: Int = 204, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    static func error(_ status: Int, code: String, message: String) -> HTTPResponse {
        json(status, ErrorResponse(error: .init(code: code, message: message)))
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

struct ErrorResponse: Codable {
    struct Detail: Codable {
        var code: String
        var message: String
    }
    var error: Detail
}
