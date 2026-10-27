import AppKit
import CoreServices
import Foundation

final class Daemon: NSObject, NSApplicationDelegate {
    private let config: ServeConfig
    private var server: HTTPServer?
    private var notifier: Notifier?
    private var signalSources: [DispatchSourceSignal] = []

    init(config: ServeConfig) {
        self.config = config
    }

    /// Starts everything and never returns.
    func run() -> Never {
        Log.verbose = config.verbose
        guard let bundleID = Bundle.main.bundleIdentifier, Bundle.main.bundleURL.pathExtension == "app" else {
            Log.error("pingski must run from inside its app bundle (Pingski.app/Contents/MacOS/pingski) so macOS can route notifications to it.")
            Log.error("Use the 'pingski' launcher installed by Homebrew or 'make run' from a checkout.")
            exit(78)
        }
        // Make sure LaunchServices knows about this bundle so notification clicks route back to us.
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self

        let events = EventBus(globalWebhook: config.webhook)
        let notifier = Notifier(events: events, provisional: config.provisional)
        self.notifier = notifier
        let router = Router(backend: notifier, events: events, token: config.token, port: Int(config.port))

        do {
            let server = try HTTPServer(host: config.host, port: config.port) { request in
                await router.handle(request)
            }
            self.server = server
            server.start(onReady: { [config] port in
                Log.info("pingski \(pingskiVersion) listening on http://\(config.host):\(port) (bundle \(bundleID))")
                Log.info("docs: http://\(config.host == "0.0.0.0" ? "127.0.0.1" : config.host):\(port)/docs")
                if config.token != nil { Log.info("bearer token authentication enabled") }
                if let hook = config.webhook { Log.info("forwarding events to \(hook)") }
            }, onFailure: { [config] error in
                Log.error("could not listen on \(config.host):\(config.port): \(error)")
                exit(1)
            })
        } catch {
            Log.error("failed to create listener: \(error)")
            exit(1)
        }

        installSignalHandlers()

        Task {
            let status = await notifier.authorizationStatus()
            Log.info("notification permission: \(status)")
            if status == "notDetermined" {
                if !config.provisional { Log.info("requesting notification permission; macOS shows a prompt the first time, please click Allow") }
                let granted = await notifier.requestAuthorization(provisional: config.provisional)
                Log.info(granted ? "notification permission granted\(config.provisional ? " (provisional)" : "")" : "notification permission not granted (approve the prompt or enable Pingski in System Settings > Notifications)")
            } else if status == "denied" {
                Log.warn("notifications are disabled for Pingski. Enable them in System Settings > Notifications > Pingski.")
            }
        }

        app.run()
        exit(0)
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Log.info("received signal \(sig), shutting down")
                self?.server?.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        server?.stop()
        return .terminateNow
    }
}
