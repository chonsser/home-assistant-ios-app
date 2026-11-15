import Foundation
import Shared

/// A TCP stream inside the Tailcat tunnel. One read and one write may run concurrently; every call
/// blocks, so they run on the proxy's own threads, never on the main thread or the cooperative pool.
protocol TailcatConnection: AnyObject {
    /// Reads up to `buffer.count` bytes. Returns 0 at end of stream.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    /// Writes every byte of `buffer`.
    func write(_ buffer: UnsafeRawBufferPointer) throws
    /// Half-closes the stream: no more writes, reads continue until the peer finishes.
    func closeWrite() throws
    /// Releases the stream and interrupts any call blocked on it. Safe to call more than once.
    func close()
}
