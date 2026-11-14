import Foundation
import Shared

internal import Tailcat

/// A TCP stream opened through `LibTailcatClient`.
final class LibTailcatConnection: TailcatConnection {
    private static let closeWriteTimeout: TimeInterval = 10

    private let lock = NSLock()
    private var handle: tc_handle

    init(handle: tc_handle) {
        self.handle = handle
    }

    deinit {
        close()
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        var count = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = try tc_conn_read(liveHandle(), LibTailcat.noCancel, base, buffer.count, &count, &error)
        if status == Int32(TC_EOF) {
            tc_free(error)
            // Bytes delivered together with EOF are still data; EOF shows up on the next read.
            return count
        }
        if status != Int32(TC_OK), count > 0 {
            // Hand over what arrived; the error resurfaces on the next read.
            tc_free(error)
            return count
        }
        try LibTailcat.check(status, error)
        return count
    }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            var count = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = try tc_conn_write(
                liveHandle(),
                LibTailcat.noCancel,
                UnsafeMutableRawPointer(mutating: base + offset),
                buffer.count - offset,
                &count,
                &error
            )
            offset += count
            try LibTailcat.check(status, error)
        }
    }

    func closeWrite() throws {
        let connection = try liveHandle()
        try LibTailcat.withToken(timeout: Self.closeWriteTimeout) { token in
            var error: UnsafeMutablePointer<CChar>?
            try LibTailcat.check(tc_conn_close_write(connection, token, &error), error)
        }
    }

    func close() {
        let connection: tc_handle = lock.withLock {
            defer { handle = 0 }
            return handle
        }
        guard connection != 0 else { return }
        tc_close(connection, nil)
    }

    private func liveHandle() throws -> tc_handle {
        let connection = lock.withLock { handle }
        guard connection != 0 else { throw TailcatError(kind: .closed) }
        return connection
    }
}
