import Foundation
import Shared

/// A failure reported by the Tailcat tunnel engine. The libtailcat message is kept for diagnostics
/// only: it never contains the address or keys, but branch on `kind`, never on the text.
struct TailcatError: LocalizedError, Equatable, CustomStringConvertible {
    enum Kind: Equatable {
        case invalidArgument
        case closed
        case timeout
        case cancelled
        case failure
        /// The local loopback listener could not be created.
        case listenerUnavailable
        /// A status code this build does not know.
        case unrecognized(Int32)
    }

    var kind: Kind
    var message: String?

    init(kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    /// What the user sees: the tunnel could not be used, whatever the reason.
    var errorDescription: String? {
        L10n.Tailcat.Pairing.Error.tunnelUnavailable
    }

    var description: String {
        if let message {
            return "TailcatError(\(kind)): \(message)"
        } else {
            return "TailcatError(\(kind))"
        }
    }
}
