import Foundation
import Network
import Shared
import UIKit

/// Runs the app's Tailcat tunnels: one loopback proxy per tunnel endpoint (server address and port),
/// created the first time a server's URL is resolved and kept for the life of the process.
///
/// `localURL(for:)` is synchronous because `ConnectionInfo.evaluateActiveURL()` is: the proxy binds
/// its port right away and only the tunnel client, which needs the network, is created lazily on the
/// first connection.
final class TailcatTunnelManager {
    static let shared = TailcatTunnelManager()

    /// How long one loopback connection waits for its tunnel stream, retries included. Covers the
    /// couple of seconds Home Assistant needs to restart its Tailcat server (to allowlist a freshly
    /// paired device, say) plus a fresh client finding its way to it on a slow network, and stays
    /// below the 60 second request timeout of URLSession and WebKit.
    static let dialTimeout: TimeInterval = 45
    /// A suspension shorter than this keeps the tunnel client; longer ones start a fresh client,
    /// because the Go runtime's sockets may not have survived.
    static let backgroundResetThreshold: TimeInterval = 20

    private struct Tunnel {
        let proxy: TailcatLoopbackProxy
        let session: TailcatClientSession
    }

    private let lock = NSLock()
    private var tunnels = [String: Tunnel]()
    private var enteredBackgroundAt: Date?
    private var observers = [NSObjectProtocol]()
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private let makeSession: (TailcatConfiguration) -> TailcatClientSession

    init(makeSession: @escaping (TailcatConfiguration) -> TailcatClientSession = {
        TailcatClientSession(configuration: $0)
    }) {
        self.makeSession = makeSession
    }

    /// Lets `ConnectionInfo` resolve tunnel URLs in this process and follows the app's lifecycle.
    func install() {
        HANetworkingEnvironment.current.tailcatLocalURL = { [weak self] configuration in
            self?.localURL(for: configuration)
        }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.applicationDidEnterBackground()
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.applicationWillEnterForeground()
            },
        ]

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.networkPathDidChange(to: Self.signature(of: path))
        }
        monitor.start(queue: DispatchQueue(label: "io.home-assistant.tailcat.path"))
        pathMonitor = monitor
    }

    /// What identifies a network path for the tunnel: whether it is usable and over which interfaces.
    private static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.type):\($0.name)" }
        return "\(path.status):\(interfaces.joined(separator: ","))"
    }

    /// The tunnel client's sockets belong to the network it started on; after a switch (Wi-Fi to
    /// cellular, a new Wi-Fi network) they no longer reach anything, and neither do its streams.
    /// Starting fresh clients makes the next connection find a path over the current network.
    func networkPathDidChange(to signature: String) {
        let changed: Bool = lock.withLock {
            defer { lastPathSignature = signature }
            return lastPathSignature != nil && lastPathSignature != signature
        }
        guard changed else { return }
        Current.Log.info("Tailcat: network path changed, starting new tunnel clients")
        resetAllSessions()
    }

    private func resetAllSessions() {
        let current: [Tunnel] = lock.withLock { Array(tunnels.values) }
        current.forEach { $0.session.reset() }
    }

    /// The loopback URL serving `configuration`'s tunnel, starting the proxy if needed. `nil` when
    /// no loopback port could be bound.
    func localURL(for configuration: TailcatConfiguration) -> URL? {
        lock.withLock {
            let key = configuration.endpointIdentity
            if let tunnel = tunnels[key] {
                tunnel.session.update(configuration: configuration)
                return tunnel.proxy.localURL
            }

            let session = makeSession(configuration)
            do {
                let proxy = try TailcatLoopbackProxy(
                    preferredPort: TailcatLocalPort.preferred(for: configuration),
                    tunnelPort: configuration.tunnelPort,
                    dialer: session,
                    dialTimeout: Self.dialTimeout
                )
                tunnels[key] = Tunnel(proxy: proxy, session: session)
                Current.Log.info("Tailcat: serving a tunnel on loopback port \(proxy.port)")
                return proxy.localURL
            } catch {
                Current.Log.error("Tailcat: could not start the loopback proxy: \(error)")
                return nil
            }
        }
    }

    /// Stops the tunnel for `configuration`'s endpoint, e.g. after the pairing was removed.
    func stopTunnel(for configuration: TailcatConfiguration) {
        let tunnel: Tunnel? = lock.withLock {
            tunnels.removeValue(forKey: configuration.endpointIdentity)
        }
        guard let tunnel else { return }
        tunnel.proxy.stop()
        DispatchQueue.global(qos: .utility).async {
            tunnel.session.close()
        }
    }

    func applicationDidEnterBackground() {
        lock.withLock { enteredBackgroundAt = Date() }
    }

    func applicationWillEnterForeground() {
        let (current, backgroundDuration): ([Tunnel], TimeInterval?) = lock.withLock {
            defer { enteredBackgroundAt = nil }
            return (Array(tunnels.values), enteredBackgroundAt.map { Date().timeIntervalSince($0) })
        }

        for tunnel in current {
            tunnel.proxy.ensureListening()
            if let backgroundDuration, backgroundDuration >= Self.backgroundResetThreshold {
                tunnel.session.reset()
            }
        }
    }
}
