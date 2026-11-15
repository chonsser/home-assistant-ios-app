import Foundation
import Shared

/// Opens TCP streams to the paired server's port inside the Tailcat tunnel. Abstracted so the
/// loopback proxy can be tested without a network or the Go runtime.
protocol TailcatDialing: AnyObject {
    /// Blocks until the stream is open or `timeout` (seconds) has passed.
    func dial(port: UInt16, timeout: TimeInterval) throws -> TailcatConnection
    /// Closes the client and every stream it opened. Safe to call more than once.
    func close()
}
