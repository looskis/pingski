import Foundation

enum Log {
    static var verbose = false

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit("DEBUG", message(), stderr: false)
    }

    static func info(_ message: String) { emit("INFO", message, stderr: false) }
    static func warn(_ message: String) { emit("WARN", message, stderr: true) }
    static func error(_ message: String) { emit("ERROR", message, stderr: true) }

    private static func emit(_ level: String, _ message: String, stderr: Bool) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        if stderr {
            FileHandle.standardError.write(Data(line.utf8))
        } else {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
