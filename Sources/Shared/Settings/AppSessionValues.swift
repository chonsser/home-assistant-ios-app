import Foundation

public protocol AppSessionValuesProtocol {
    var inviteURL: URL? { get set }
    var inviteTailcatPairing: TailcatPairingLink? { get set }
}

/// Values stored for the given app session until terminated by the OS.
final class AppSessionValues: AppSessionValuesProtocol {
    static var shared = AppSessionValues()
    /// The URL from the Home Assistant invitation link
    public var inviteURL: URL?
    /// The Tailcat pairing link opened before a server existed, onboarded once the user continues.
    public var inviteTailcatPairing: TailcatPairingLink?
}
