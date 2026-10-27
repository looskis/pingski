import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// Turns an `icon` value (http(s) URL, file path, file:// URL or data: URI) into a notification attachment.
enum AttachmentLoader {
    static let maxBytes = 10 * 1024 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func load(_ source: String) async throws -> UNNotificationAttachment {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError("'icon' must not be empty") }

        let data: Data
        var type: UTType?

        if trimmed.lowercased().hasPrefix("data:") {
            (data, type) = try decodeDataURI(trimmed)
        } else if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            (data, type) = try await download(url)
        } else {
            let path: String
            if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
                path = url.path
            } else {
                path = (trimmed as NSString).expandingTildeInPath
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("icon file not found: \(path)")
            }
            data = try Data(contentsOf: URL(fileURLWithPath: path))
            type = UTType(filenameExtension: (path as NSString).pathExtension)
        }

        guard data.count <= maxBytes else { throw ValidationError("icon exceeds \(maxBytes) bytes") }
        guard !data.isEmpty else { throw ValidationError("icon is empty") }

        let resolved = type ?? sniff(data) ?? .png
        guard resolved.conforms(to: .image) || resolved.conforms(to: .audiovisualContent) else {
            throw ValidationError("icon must be an image (png, jpeg, gif, heic...) got \(resolved.identifier)")
        }
        let ext = resolved.preferredFilenameExtension ?? "png"

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pingski-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: file)
        do {
            return try UNNotificationAttachment(identifier: "icon", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: resolved.identifier])
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw ValidationError("could not attach icon: \(error.localizedDescription)")
        }
    }

    private static func decodeDataURI(_ uri: String) throws -> (Data, UTType?) {
        let withoutScheme = uri.dropFirst("data:".count)
        guard let comma = withoutScheme.firstIndex(of: ",") else {
            throw ValidationError("malformed data URI")
        }
        let meta = withoutScheme[..<comma]
        let payload = withoutScheme[withoutScheme.index(after: comma)...]
        let metaParts = meta.split(separator: ";").map(String.init)
        let mime = metaParts.first.flatMap { $0.contains("/") ? $0 : nil }
        let isBase64 = metaParts.contains { $0.lowercased() == "base64" }
        let data: Data
        if isBase64 {
            guard let decoded = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters) else {
                throw ValidationError("data URI is not valid base64")
            }
            data = decoded
        } else {
            data = Data((String(payload).removingPercentEncoding ?? String(payload)).utf8)
        }
        return (data, mime.flatMap { UTType(mimeType: $0) })
    }

    private static func download(_ url: URL) async throws -> (Data, UTType?) {
        var request = URLRequest(url: url)
        request.setValue("pingski/\(pingskiVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ValidationError("could not download icon \(url): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ValidationError("icon download \(url) returned HTTP \(http.statusCode)")
        }
        var type: UTType?
        if let mime = response.mimeType, mime != "application/octet-stream" {
            type = UTType(mimeType: mime)
        }
        if type == nil || type == .data {
            type = UTType(filenameExtension: url.pathExtension)
        }
        return (data, type)
    }

    private static func sniff(_ data: Data) -> UTType? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if head.count >= 12, Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return .heic }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]), head.count >= 12, Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return .webP }
        return nil
    }
}
