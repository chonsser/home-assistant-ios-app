import Foundation
import Shared

/// Attaches a Tailcat pairing to a server the app already has, or removes it.
enum TailcatServerPairing {
    static func attach(
        _ configuration: TailcatConfiguration,
        to server: Server,
        servers: ServerManager = Current.servers,
        tunnels: TailcatTunnelManager = .shared
    ) {
        let previous = server.info.connection.tailcat
        server.update { info in
            info.connection.tailcat = configuration
        }
        Current.Log.info("Tailcat pairing attached to server \(server.identifier)")

        if let previous, previous.endpointIdentity != configuration.endpointIdentity {
            stopTunnelIfUnused(previous, servers: servers, tunnels: tunnels)
        }
    }

    static func remove(
        from server: Server,
        servers: ServerManager = Current.servers,
        tunnels: TailcatTunnelManager = .shared
    ) {
        guard let previous = server.info.connection.tailcat else { return }
        server.update { info in
            info.connection.tailcat = nil
        }
        Current.Log.info("Tailcat pairing removed from server \(server.identifier)")
        stopTunnelIfUnused(previous, servers: servers, tunnels: tunnels)
    }

    private static func stopTunnelIfUnused(
        _ configuration: TailcatConfiguration,
        servers: ServerManager,
        tunnels: TailcatTunnelManager
    ) {
        let stillUsed = servers.all.contains {
            $0.info.connection.tailcat?.endpointIdentity == configuration.endpointIdentity
        }
        if !stillUsed {
            tunnels.stopTunnel(for: configuration)
        }
    }
}
