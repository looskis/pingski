import Foundation
import Network

final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "pingski.http.listener")
    private let requestedPort: UInt16
    private let connectionsLock = NSLock()
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(host: String, port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "pingski", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        self.listener = try NWListener(using: parameters)
        self.handler = handler
        self.requestedPort = port
    }

    func start(onReady: @escaping (UInt16) -> Void, onFailure: @escaping (Error) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady(self.listener.port?.rawValue ?? self.requestedPort)
            case .failed(let error):
                onFailure(error)
            case .waiting(let error):
                Log.warn("listener waiting: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let http = HTTPConnection(connection: connection, handler: self.handler)
            let key = ObjectIdentifier(http)
            self.connectionsLock.lock()
            self.connections[key] = http
            self.connectionsLock.unlock()
            http.onTeardown = { [weak self] in
                guard let self else { return }
                self.connectionsLock.lock()
                self.connections[key] = nil
                self.connectionsLock.unlock()
            }
            http.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        connectionsLock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        connectionsLock.unlock()
        for connection in open { connection.close() }
    }

    var openConnectionCount: Int {
        connectionsLock.lock(); defer { connectionsLock.unlock() }
        return connections.count
    }
}

final class HTTPConnection: HTTPStreamWriter {
    private let connection: NWConnection
    private let handler: HTTPServer.Handler
    private let queue = DispatchQueue(label: "pingski.http.connection")
    private var buffer = Data()
    private var busy = false
    private var closed = false
    private var inputEnded = false
    private var sentContinue = false
    private var streaming = false
    private let remote: String

    var onClose: (() -> Void)?
    var onTeardown: (() -> Void)?
    var isOpen: Bool { queue.sync { !closed } }

    init(connection: NWConnection, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.handler = handler
        if case let .hostPort(host, port) = connection.endpoint {
            remote = "\(host):\(port)"
        } else {
            remote = "\(connection.endpoint)"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.teardown()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if let error {
                Log.debug("\(self.remote) receive error: \(error)")
                self.teardown()
                return
            }
            self.processBuffer()
            if isComplete {
                self.inputEnded = true
                if !self.busy && !self.streaming { self.teardown() }
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        guard !busy, !closed, !streaming else { return }
        do {
            switch try HTTPParser.parse(&buffer) {
            case .incomplete(let expectsContinue):
                if expectsContinue && !sentContinue {
                    sentContinue = true
                    rawSend(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), final: false)
                }
            case .complete(let request):
                sentContinue = false
                busy = true
                let started = Date()
                Task { [weak self] in
                    guard let self else { return }
                    let response = await self.handler(request)
                    self.queue.async {
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        Log.info("\(self.remote) \(request.method) \(request.target) -> \(response.status) (\(ms)ms)")
                        self.send(response, for: request)
                    }
                }
            }
        } catch let error as HTTPParseError {
            let response: HTTPResponse
            switch error {
            case .bodyTooLarge:
                response = .error(413, code: "payload_too_large", message: "request body exceeds \(HTTPParser.maxBodyBytes) bytes")
            case .headersTooLarge:
                response = .error(431, code: "headers_too_large", message: "request headers exceed \(HTTPParser.maxHeaderBytes) bytes")
            case .malformed(let why):
                response = .error(400, code: "bad_request", message: "malformed HTTP request: \(why)")
            }
            busy = true
            send(response, for: nil)
        } catch {
            busy = true
            send(.error(500, code: "internal_error", message: "\(error)"), for: nil)
        }
    }

    private func send(_ response: HTTPResponse, for request: HTTPRequest?) {
        guard !closed else { return }
        let isStream = response.stream != nil
        let keepAlive = !isStream && !inputEnded && (request?.wantsKeepAlive ?? false)
        let isHead = request?.method == "HEAD"

        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reason(for: response.status))\r\n"
        head += "Server: pingski/\(pingskiVersion)\r\n"
        head += "Date: \(HTTPConnection.dateFormatter.string(from: Date()))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        if !isStream {
            head += "Content-Length: \(response.body.count)\r\n"
        }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var payload = Data(head.utf8)
        if !isHead && !isStream { payload.append(response.body) }

        if let stream = response.stream {
            streaming = true
            rawSend(payload, final: false)
            if isHead {
                teardown()
            } else {
                stream(self)
            }
            return
        }

        if keepAlive {
            rawSend(payload, final: false)
            busy = false
            processBuffer()
        } else {
            rawSend(payload, final: true)
        }
    }

    private func rawSend(_ data: Data, final: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { Log.debug("send error: \(error)") }
            if final { self?.teardown() }
        })
    }

    private func teardown() {
        if closed { return }
        closed = true
        busy = false
        connection.cancel()
        let callback = onClose
        onClose = nil
        callback?()
        let teardown = onTeardown
        onTeardown = nil
        teardown?()
    }

    // MARK: HTTPStreamWriter

    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.rawSend(data, final: false)
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.teardown()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
}
