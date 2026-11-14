import Foundation
@testable import HomeAssistant

/// An in-memory tunnel stream. By default it echoes what it receives; `respond` replaces that with a
/// server of the test's own, which sees each chunk and decides what to send back.
final class FakeTailcatConnection: TailcatConnection {
    private let condition = NSCondition()
    private var inbound = Data()
    private var receivedEOF = false
    private var isClosed = false
    private(set) var written = Data()
    private(set) var closeWriteCount = 0
    private(set) var closeCount = 0

    /// Called with everything written so far; returns bytes to send and whether to end the stream.
    var respond: ((Data) -> (reply: Data, finish: Bool))?

    init(respond: ((Data) -> (reply: Data, finish: Bool))? = nil) {
        self.respond = respond
    }

    var didCloseWrite: Bool { condition.withLock { closeWriteCount > 0 } }
    var didClose: Bool { condition.withLock { closeCount > 0 } }
    var receivedBytes: Data { condition.withLock { written } }

    /// Makes the "server" send `data` and optionally end its side of the stream.
    func send(_ data: Data, finish: Bool = false) {
        condition.withLock {
            inbound.append(data)
            receivedEOF = receivedEOF || finish
            condition.broadcast()
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        condition.lock()
        defer { condition.unlock() }
        while inbound.isEmpty, !receivedEOF, !isClosed {
            condition.wait()
        }
        if isClosed, inbound.isEmpty {
            throw TailcatError(kind: .closed)
        }
        let count = min(buffer.count, inbound.count)
        guard count > 0 else { return 0 }
        inbound.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: count)
        inbound.removeFirst(count)
        return count
    }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        let reply: (reply: Data, finish: Bool)? = try condition.withLock {
            guard !isClosed else { throw TailcatError(kind: .closed) }
            written.append(contentsOf: buffer)
            if let respond {
                return respond(written)
            } else {
                return (Data(buffer), false)
            }
        }
        if let reply, !reply.reply.isEmpty || reply.finish {
            send(reply.reply, finish: reply.finish)
        }
    }

    func closeWrite() throws {
        condition.withLock {
            closeWriteCount += 1
            if respond == nil {
                // An echo server finishes once its client does.
                receivedEOF = true
                condition.broadcast()
            }
        }
    }

    func close() {
        condition.withLock {
            closeCount += 1
            isClosed = true
            condition.broadcast()
        }
    }
}
