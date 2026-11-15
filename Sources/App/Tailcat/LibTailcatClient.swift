import Foundation
import Shared

internal import Tailcat

/// A libtailcat client for one paired server. Network startup is deferred to the first dial.
final class LibTailcatClient: TailcatDialing {
    private let lock = NSLock()
    private var handle: tc_handle

    init(configuration: TailcatConfiguration) throws {
        let config = try JSONSerialization.data(withJSONObject: [
            "address": configuration.address,
            "key": configuration.clientPrivateKey,
        ])
        guard let json = String(data: config, encoding: .utf8) else {
            throw TailcatError(kind: .invalidArgument)
        }

        var handle: tc_handle = 0
        var error: UnsafeMutablePointer<CChar>?
        // `tc_client_new` takes a mutable pointer but only borrows it for the duration of the call.
        let status = json.withCString { tc_client_new(UnsafeMutablePointer(mutating: $0), &handle, &error) }
        try LibTailcat.check(status, error)
        self.handle = handle
    }

    deinit {
        close()
    }

    func dial(port: UInt16, timeout: TimeInterval) throws -> TailcatConnection {
        let client = currentHandle()
        guard client != 0 else { throw TailcatError(kind: .closed) }

        return try LibTailcat.withToken(timeout: timeout) { token in
            var connection: tc_handle = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_client_dial(client, token, port, Int32(TC_TCP), &connection, &error)
            try LibTailcat.check(status, error)
            return LibTailcatConnection(handle: connection)
        }
    }

    func close() {
        let client: tc_handle = lock.withLock {
            defer { handle = 0 }
            return handle
        }
        guard client != 0 else { return }
        // Interrupts and waits for every call on the client and its connections.
        tc_close(client, nil)
    }

    private func currentHandle() -> tc_handle {
        lock.withLock { handle }
    }
}
