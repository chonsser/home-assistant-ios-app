import Foundation

/// Why a Tailcat pairing link was rejected.
public enum TailcatPairingLinkError: Error, Equatable, LocalizedError {
    /// Not a `homeassistant://tailcat/pair` link.
    case invalidLink
    /// `address` is missing or is not a Tailcat address (`tc…`).
    case invalidAddress
    /// `key` is missing or is not a Tailcat private key (`privkey:…`).
    case invalidKey
    /// `port` is missing or outside 1–65535.
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .invalidLink:
            return L10n.Tailcat.Pairing.Error.invalidLink
        case .invalidAddress:
            return L10n.Tailcat.Pairing.Error.invalidAddress
        case .invalidKey:
            return L10n.Tailcat.Pairing.Error.invalidKey
        case .invalidPort:
            return L10n.Tailcat.Pairing.Error.invalidPort
        }
    }
}
