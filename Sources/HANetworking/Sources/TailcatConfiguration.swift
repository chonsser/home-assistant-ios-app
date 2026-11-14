import Foundation

/// How to reach a Home Assistant server through a Tailcat tunnel
/// (https://github.com/tailscale/tailcat): the server's secret Tailcat address, this device's own
/// private client key (the server allowlists its public half) and the TCP port inside the tunnel
/// that speaks HTTP to Home Assistant.
///
/// The tunnel itself runs in the app process only (`HANetworkingEnvironment.tailcatLocalURL`); this
/// type is plain data so every target can decode and keep it. `address` and `clientPrivateKey` are
/// secrets: never log them. `description` is redacted for that reason.
public struct TailcatConfiguration: Codable, Equatable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible {
    /// The server's Tailcat address (`tc…`).
    public var address: String
    /// This device's Tailcat private key (`privkey:…`).
    public var clientPrivateKey: String
    /// TCP port inside the tunnel that Home Assistant answers on.
    public var tunnelPort: UInt16

    public init(address: String, clientPrivateKey: String, tunnelPort: UInt16) {
        self.address = address
        self.clientPrivateKey = clientPrivateKey
        self.tunnelPort = tunnelPort
    }

    /// Identifies the tunnel endpoint (server address and port) regardless of the client key, so a
    /// device re-paired with a new key keeps talking to the same endpoint.
    public var endpointIdentity: String {
        "\(address):\(tunnelPort)"
    }

    public var description: String {
        "TailcatConfiguration(port: \(tunnelPort), <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}
