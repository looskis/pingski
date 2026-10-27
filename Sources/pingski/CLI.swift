import Foundation

struct ServeConfig {
    var host = "127.0.0.1"
    var port: UInt16 = 7464
    var token: String?
    var webhook: URL?
    var verbose = false
    var provisional = false
}

struct SendOptions {
    var server = "http://127.0.0.1:7464"
    var token: String?
    var body: [String: JSONValue] = [:]
    var rawJSON: String?
}

enum Command {
    case serve(ServeConfig)
    case send(SendOptions)
    case openapi
    case help
    case version
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum CLI {
    static let usage = """
    pingski \(pingskiVersion) - macOS notification daemon with an HTTP + OpenAPI interface

    USAGE
      pingski [serve] [options]        Start the daemon (default command)
      pingski send [options]           Post a notification to a running daemon
      pingski openapi                  Print the OpenAPI 3 document
      pingski --version | --help

    SERVE OPTIONS
      -p, --port <n>        TCP port to listen on (default 7464, env PINGSKI_PORT)
          --host <addr>     Bind address (default 127.0.0.1; use 0.0.0.0 for LAN, env PINGSKI_HOST)
          --token <secret>  Require 'Authorization: Bearer <secret>' or 'X-API-Key' (env PINGSKI_TOKEN)
          --webhook <url>   POST every event (clicked/action/dismissed/...) to this URL (env PINGSKI_WEBHOOK)
          --provisional     Ask for provisional (quiet) permission: no prompt, notifications go
                            straight to Notification Center without banners until the user
                            promotes them (env PINGSKI_PROVISIONAL=1)
      -v, --verbose         Debug logging
      All options can also come from KEY=VALUE lines in the file named by PINGSKI_ENV_FILE.

    SEND OPTIONS
          --server <url>    Daemon base URL (default http://127.0.0.1:7464, env PINGSKI_SERVER)
          --token <secret>  Auth token (env PINGSKI_TOKEN)
      -t, --title <text>    Notification title (required unless --json)
      -m, --message <text>  Body text
      -s, --subtitle <text>
          --icon <src>      Image URL, file path or data: URI shown with the notification
          --url <url>       Deep link opened when the notification is clicked
          --sound <name>    default | none | <name of a system sound, e.g. Glass>
          --group <id>      Thread identifier used to group notifications
          --badge <n>       Dock badge number
          --priority <lvl>  passive | active | timeSensitive | critical
          --delay <sec>     Deliver after N seconds
          --id <id>         Explicit identifier (re-sending replaces the notification)
          --action <spec>   Button; 'id=Title' or 'id=Title=https://url' (repeatable)
          --callback <url>  Webhook for this notification's events
          --data <json>     Arbitrary JSON echoed in events
          --json <json>     Send this raw JSON body instead of building one

    EXAMPLES
      pingski --port 8080
      pingski send -t "Build finished" -m "main is green" --url "https://ci.example.com/run/42"
      curl -X POST localhost:7464/notify -H 'Content-Type: application/json' \\
           -d '{"title":"Hello","message":"from curl","icon":"https://example.com/logo.png"}'
    """

    static func parse(_ arguments: [String]) throws -> Command {
        var args = Array(arguments.dropFirst())
        if args.isEmpty { return .serve(try parseServe([])) }

        switch args[0] {
        case "-h", "--help", "help":
            return .help
        case "-V", "--version", "version":
            return .version
        case "openapi", "spec":
            return .openapi
        case "send", "notify":
            args.removeFirst()
            return .send(try parseSend(args))
        case "serve", "start", "run":
            args.removeFirst()
            return .serve(try parseServe(args))
        default:
            if args[0].hasPrefix("-") { return .serve(try parseServe(args)) }
            throw CLIError("unknown command '\(args[0])'. Run 'pingski --help'.")
        }
    }

    /// Process environment merged with KEY=VALUE lines from the file named by PINGSKI_ENV_FILE
    /// (used by `brew services`). Real environment variables win over file values.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let path = env["PINGSKI_ENV_FILE"], !path.isEmpty,
              let contents = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return env }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if env[key] == nil { env[key] = value }
        }
        return env
    }

    private static func parseServe(_ args: [String]) throws -> ServeConfig {
        var config = ServeConfig()
        let env = environment()
        if let p = env["PINGSKI_PORT"] { config.port = try parsePort(p) }
        if let h = env["PINGSKI_HOST"], !h.isEmpty { config.host = h }
        if let t = env["PINGSKI_TOKEN"], !t.isEmpty { config.token = t }
        if let w = env["PINGSKI_WEBHOOK"], !w.isEmpty { config.webhook = try parseWebhook(w) }
        if env["PINGSKI_VERBOSE"] == "1" { config.verbose = true }
        if env["PINGSKI_PROVISIONAL"] == "1" { config.provisional = true }

        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIError("\(flag) requires a value") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-p", "--port": config.port = try parsePort(try value(arg))
            case "--host": config.host = try value(arg)
            case "--token": config.token = try value(arg)
            case "--webhook": config.webhook = try parseWebhook(try value(arg))
            case "-v", "--verbose": config.verbose = true
            case "--provisional", "--quiet": config.provisional = true
            case "-h", "--help": throw CLIError(usage)
            default:
                if arg.hasPrefix("--port=") { config.port = try parsePort(String(arg.dropFirst(7))) }
                else if arg.hasPrefix("--host=") { config.host = String(arg.dropFirst(7)) }
                else if arg.hasPrefix("--token=") { config.token = String(arg.dropFirst(8)) }
                else if arg.hasPrefix("--webhook=") { config.webhook = try parseWebhook(String(arg.dropFirst(10))) }
                else if let n = UInt16(arg), i == 0 { config.port = n }
                else { throw CLIError("unknown option '\(arg)'. Run 'pingski --help'.") }
            }
            i += 1
        }
        if config.host.lowercased() == "localhost" { config.host = "127.0.0.1" }
        if config.host == "*" || config.host.lowercased() == "any" { config.host = "0.0.0.0" }
        return config
    }

    private static func parseSend(_ args: [String]) throws -> SendOptions {
        var options = SendOptions()
        let env = environment()
        if let s = env["PINGSKI_SERVER"], !s.isEmpty { options.server = s }
        if let p = env["PINGSKI_PORT"], env["PINGSKI_SERVER"] == nil { options.server = "http://127.0.0.1:\(p)" }
        if let t = env["PINGSKI_TOKEN"], !t.isEmpty { options.token = t }
        var actions: [JSONValue] = []

        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIError("\(flag) requires a value") }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--server": options.server = try value(arg)
            case "-p", "--port": options.server = "http://127.0.0.1:\(try parsePort(try value(arg)))"
            case "--token": options.token = try value(arg)
            case "-t", "--title": options.body["title"] = .string(try value(arg))
            case "-m", "--message", "--body": options.body["message"] = .string(try value(arg))
            case "-s", "--subtitle": options.body["subtitle"] = .string(try value(arg))
            case "--icon", "--logo", "--image": options.body["icon"] = .string(try value(arg))
            case "--url", "--link", "--open": options.body["url"] = .string(try value(arg))
            case "--sound": options.body["sound"] = .string(try value(arg))
            case "--group", "--thread": options.body["group"] = .string(try value(arg))
            case "--badge":
                let raw = try value(arg)
                guard let n = Int(raw) else { throw CLIError("--badge expects an integer") }
                options.body["badge"] = .number(Double(n))
            case "--priority", "--level": options.body["priority"] = .string(try value(arg))
            case "--relevance":
                let raw = try value(arg)
                guard let n = Double(raw) else { throw CLIError("--relevance expects a number") }
                options.body["relevance"] = .number(n)
            case "--delay", "--in":
                let raw = try value(arg)
                guard let n = Double(raw) else { throw CLIError("--delay expects a number of seconds") }
                options.body["delay"] = .number(n)
            case "--id": options.body["id"] = .string(try value(arg))
            case "--callback", "--webhook": options.body["callbackUrl"] = .string(try value(arg))
            case "--action", "--button":
                let spec = try value(arg)
                let parts = spec.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                var action: [String: JSONValue] = [:]
                switch parts.count {
                case 1:
                    action["id"] = .string(NotificationAction.slug(parts[0]))
                    action["title"] = .string(parts[0])
                case 2:
                    action["id"] = .string(parts[0])
                    action["title"] = .string(parts[1])
                default:
                    action["id"] = .string(parts[0])
                    action["title"] = .string(parts[1])
                    action["url"] = .string(parts[2])
                }
                actions.append(.object(action))
            case "--data":
                let raw = try value(arg)
                guard let parsed = JSONValue.parse(raw) else { throw CLIError("--data must be valid JSON") }
                options.body["data"] = parsed
            case "--json":
                let raw = try value(arg)
                guard JSONValue.parse(raw) != nil else { throw CLIError("--json must be valid JSON") }
                options.rawJSON = raw
            case "-h", "--help": throw CLIError(usage)
            default: throw CLIError("unknown option '\(arg)'. Run 'pingski --help'.")
            }
            i += 1
        }
        if !actions.isEmpty { options.body["actions"] = .array(actions) }
        if options.rawJSON == nil && options.body["title"] == nil {
            throw CLIError("send requires --title (or --json)")
        }
        return options
    }

    private static func parsePort(_ raw: String) throws -> UInt16 {
        guard let n = UInt16(raw.trimmingCharacters(in: .whitespaces)) else {
            throw CLIError("invalid port '\(raw)' (expected 0-65535)")
        }
        return n
    }

    private static func parseWebhook(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CLIError("webhook must be an http(s) URL (got '\(raw)')")
        }
        return url
    }
}
