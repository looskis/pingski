import Foundation

enum HTTPParseError: Error, Equatable {
    case malformed(String)
    case headersTooLarge
    case bodyTooLarge
}

enum HTTPParseResult {
    case incomplete(expectsContinue: Bool)
    case complete(HTTPRequest)
}

/// Incremental HTTP/1.1 request parser. Call `parse` whenever bytes arrive; it consumes exactly one
/// request from the front of the buffer when a full one is available.
enum HTTPParser {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024

    private static let crlf = Data("\r\n".utf8)
    private static let crlfcrlf = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: inout Data) throws -> HTTPParseResult {
        // Tolerate stray CRLFs between pipelined requests.
        while buffer.count >= 2, buffer[buffer.startIndex] == 0x0D, buffer[buffer.startIndex + 1] == 0x0A {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 2)
        }
        guard let headEnd = buffer.range(of: crlfcrlf) else {
            if buffer.count > maxHeaderBytes { throw HTTPParseError.headersTooLarge }
            return .incomplete(expectsContinue: false)
        }
        if headEnd.lowerBound - buffer.startIndex > maxHeaderBytes { throw HTTPParseError.headersTooLarge }

        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed("request head is not valid UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw HTTPParseError.malformed("missing request line")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw HTTPParseError.malformed("bad request line")
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let version = String(parts[2])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPParseError.malformed("bad header line")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPParseError.malformed("empty header name") }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let bodyStart = headEnd.upperBound
        let expectsContinue = headers["expect"]?.lowercased() == "100-continue"
        var body = Data()
        let consumedEnd: Data.Index

        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            guard let (decoded, end) = try decodeChunked(buffer, from: bodyStart) else {
                return .incomplete(expectsContinue: expectsContinue)
            }
            body = decoded
            consumedEnd = end
        } else if let lengthString = headers["content-length"] {
            guard let length = Int(lengthString.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                throw HTTPParseError.malformed("bad Content-Length")
            }
            guard length <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
            guard buffer.endIndex - bodyStart >= length else {
                return .incomplete(expectsContinue: expectsContinue)
            }
            body = Data(buffer[bodyStart..<bodyStart + length])
            consumedEnd = bodyStart + length
        } else {
            consumedEnd = bodyStart
        }

        buffer.removeSubrange(buffer.startIndex..<consumedEnd)
        return .complete(HTTPRequest(method: method, target: target, version: version, headers: headers, body: body))
    }

    private static func decodeChunked(_ buffer: Data, from start: Data.Index) throws -> (Data, Data.Index)? {
        var pos = start
        var out = Data()
        while true {
            guard let lineEnd = buffer.range(of: crlf, in: pos..<buffer.endIndex) else { return nil }
            let sizeLine = String(decoding: buffer[pos..<lineEnd.lowerBound], as: UTF8.self)
            let sizeHex = sizeLine.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeHex, radix: 16) else {
                throw HTTPParseError.malformed("bad chunk size")
            }
            pos = lineEnd.upperBound
            if size == 0 {
                // "0\r\n" is followed by optional trailers and a terminating empty line.
                let searchStart = max(buffer.startIndex, pos - 2)
                guard let end = buffer.range(of: crlfcrlf, in: searchStart..<buffer.endIndex) else { return nil }
                return (out, end.upperBound)
            }
            guard out.count + size <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
            guard buffer.endIndex - pos >= size + 2 else { return nil }
            out.append(buffer[pos..<pos + size])
            pos += size
            guard buffer[pos..<pos + 2] == crlf else {
                throw HTTPParseError.malformed("chunk missing CRLF")
            }
            pos += 2
        }
    }
}
