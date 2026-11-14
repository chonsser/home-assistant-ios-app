import Foundation
import Shared

/// The loopback port a Tailcat tunnel is served on. WKWebView keys an origin's storage (the
/// frontend's login state, localStorage) by `host:port`, so the port has to come out the same on
/// every launch: it is derived from the tunnel endpoint with a stable hash rather than `Hasher`,
/// which is seeded per process.
enum TailcatLocalPort {
    static let range: ClosedRange<UInt16> = 20000 ... 59999

    /// The port to try first for `configuration`.
    static func preferred(for configuration: TailcatConfiguration) -> UInt16 {
        preferred(forIdentity: configuration.endpointIdentity)
    }

    static func preferred(forIdentity identity: String) -> UInt16 {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + UInt16(fnv1a64(identity) % span)
    }

    /// The ports to try, in order, when the preferred one is taken: walking forward and wrapping
    /// within `range`, so the fallback is as stable as it can be.
    static func candidates(startingAt preferred: UInt16, count: Int) -> [UInt16] {
        let span = Int(range.upperBound - range.lowerBound) + 1
        let start = Int(min(max(preferred, range.lowerBound), range.upperBound) - range.lowerBound)
        return (0 ..< max(1, min(count, span))).map { offset in
            range.lowerBound + UInt16((start + offset) % span)
        }
    }

    /// FNV-1a, 64 bit.
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
