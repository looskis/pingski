import Foundation

enum SendCommand {
    static func run(_ options: SendOptions) -> Int32 {
        guard var base = URL(string: options.server) else {
            FileHandle.standardError.write(Data("invalid server URL: \(options.server)\n".utf8))
            return 2
        }
        if base.path.hasSuffix("/") { base = URL(string: String(options.server.dropLast())) ?? base }
        let url = base.appendingPathComponent("notify")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = options.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let raw = options.rawJSON {
            request.httpBody = Data(raw.utf8)
        } else {
            request.httpBody = Data(JSONValue.object(options.body).jsonString.utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                FileHandle.standardError.write(Data("request failed: \(error.localizedDescription)\nIs the daemon running? Try 'pingski' or 'brew services start pingski'.\n".utf8))
                exitCode = 1
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, !data.isEmpty {
                print(String(decoding: data, as: UTF8.self))
            }
            if status >= 400 {
                FileHandle.standardError.write(Data("server returned HTTP \(status)\n".utf8))
                exitCode = 1
            }
        }.resume()
        semaphore.wait()
        return exitCode
    }
}
