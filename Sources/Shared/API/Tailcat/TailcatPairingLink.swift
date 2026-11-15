import Foundation

/// A Tailcat pairing link produced by Home Assistant core (also shown as a QR code):
///
///     homeassistant://tailcat/pair?address=<tc…>&key=<privkey:…>&port=<1-65535>&name=<instance name>
///
/// Development builds register `homeassistant-dev` instead, so either of the app's deep link schemes
/// is accepted. `address` and `key` are secrets: never log the link or its values.
public struct TailcatPairingLink: Equatable {
    public static let host = "tailcat"
    public static let path = "/pair"

    public var configuration: TailcatConfiguration
    /// The instance name the server suggested, if any.
    public var name: String?

    public init(configuration: TailcatConfiguration, name: String?) {
        self.configuration = configuration
        self.name = name
    }

    /// Whether `url` addresses the Tailcat pairing route at all, valid or not. Lets callers keep the
    /// link out of logs before validating it.
    public static func isPairingRoute(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return AppConstants.deeplinkSchemes.contains(scheme) && url.host?.lowercased() == host
    }

    /// Parses and strictly validates a pairing link.
    public init(url: URL) throws {
        guard Self.isPairingRoute(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == Self.path else {
            throw TailcatPairingLinkError.invalidLink
        }

        func value(_ name: String) -> String? {
            let values = (components.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
            // A repeated parameter is ambiguous, so it counts as missing.
            guard values.count == 1 else { return nil }
            let trimmed = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let address = value("address"), address.hasPrefix("tc"), address.count > 2,
              !address.contains(where: \.isWhitespace) else {
            throw TailcatPairingLinkError.invalidAddress
        }

        let keyPrefix = "privkey:"
        guard let key = value("key"), key.hasPrefix(keyPrefix), key.count > keyPrefix.count,
              !key.contains(where: \.isWhitespace) else {
            throw TailcatPairingLinkError.invalidKey
        }

        guard let portString = value("port"), portString.allSatisfy(\.isASCII), let port = UInt16(portString),
              port >= 1 else {
            throw TailcatPairingLinkError.invalidPort
        }

        self.init(
            configuration: TailcatConfiguration(address: address, clientPrivateKey: key, tunnelPort: port),
            name: value("name")
        )
    }

    /// Parses text the user pasted or a QR code carried.
    public init(string: String) throws {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TailcatPairingLinkError.invalidLink
        }
        try self.init(url: url)
    }
}
