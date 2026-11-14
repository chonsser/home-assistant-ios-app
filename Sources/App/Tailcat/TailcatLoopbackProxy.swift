import Darwin
import Foundation
import Shared

/// Serves a Tailcat tunnel on `http://127.0.0.1:<port>`: every TCP connection accepted there is
/// piped, in both directions, to a stream dialed to the server's port inside the tunnel. WKWebView,
/// URLSession and the websocket then talk to the loopback URL as if it were the server.
///
/// The listening socket is bound synchronously in `init`, so the URL is known the moment the proxy
/// exists. Dialing happens per accepted connection on its own thread, because every libtailcat call
/// blocks; nothing here runs on the main thread or the Swift concurrency pool.
///
/// The proxy lives until `stop()` is called: its accept loop keeps it alive.
final class TailcatLoopbackProxy {
    /// How far past the preferred port to look for a free one.
    static let portProbeCount = 64
    private static let bufferSize = 64 * 1024

    let port: UInt16
    var localURL: URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private let tunnelPort: UInt16
    private let dialTimeout: TimeInterval
    private let dialer: TailcatDialing
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var wakePipe: (read: Int32, write: Int32) = (-1, -1)
    /// Signalled once the current accept loop has closed its listening socket.
    private var acceptLoopExited: DispatchSemaphore?
    private var isStopped = false
    private var pipes = [ObjectIdentifier: Pipe]()

    /// Binds the first free port among `TailcatLocalPort.candidates(startingAt: preferredPort)`.
    init(
        preferredPort: UInt16,
        tunnelPort: UInt16,
        dialer: TailcatDialing,
        dialTimeout: TimeInterval
    ) throws {
        var bound: (fd: Int32, port: UInt16)?
        for candidate in TailcatLocalPort.candidates(startingAt: preferredPort, count: Self.portProbeCount) {
            if let fd = Self.bindLoopback(port: candidate) {
                bound = (fd, candidate)
                break
            }
        }
        guard let bound else {
            throw TailcatError(kind: .listenerUnavailable)
        }
        self.port = bound.port
        self.tunnelPort = tunnelPort
        self.dialer = dialer
        self.dialTimeout = dialTimeout
        self.listener = bound.fd
        startAcceptLoop(on: bound.fd)
    }

    /// Number of client connections currently being piped. For tests and diagnostics.
    var activeConnectionCount: Int {
        lock.withLock { pipes.count }
    }

    /// Whether the listening socket is open. iOS can reclaim it while the app is suspended.
    var isListening: Bool {
        lock.withLock { listener >= 0 }
    }

    /// Re-binds the same port when the listening socket died (e.g. reclaimed while suspended).
    func ensureListening() {
        let needsRebind = lock.withLock { !isStopped && listener < 0 }
        guard needsRebind else { return }
        guard let fd = Self.bindLoopback(port: port) else {
            Current.Log.error("Tailcat: could not listen on loopback port \(port) again")
            return
        }
        lock.withLock { listener = fd }
        startAcceptLoop(on: fd)
    }

    /// Closes the listener and every piped connection. Returns once the port is free again, so a
    /// proxy started right after for the same endpoint gets the same port.
    func stop() {
        let (open, wake, exited): ([Pipe], Int32, DispatchSemaphore?) = lock.withLock {
            guard !isStopped else { return ([], -1, nil) }
            isStopped = true
            return (Array(pipes.values), listener >= 0 ? wakePipe.write : -1, acceptLoopExited)
        }
        if wake >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wake, &byte, 1)
            // The loop wakes from `poll` at once; the timeout only guards against the unexpected.
            _ = exited?.wait(timeout: .now() + 2)
        }
        open.forEach { $0.abort() }
    }

    // MARK: - Listening

    private static func bindLoopback(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func startAcceptLoop(on fd: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            Darwin.close(fd)
            lock.withLock { listener = -1 }
            return
        }
        let exited = DispatchSemaphore(value: 0)
        lock.withLock {
            wakePipe = (fds[0], fds[1])
            acceptLoopExited = exited
        }

        // The loop keeps the proxy alive until `stop()`, which is what ends it.
        let thread = Thread { [self] in
            acceptLoop(listener: fd, wake: fds[0])
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            Darwin.close(fd)
            lock.withLock {
                if listener == fd {
                    listener = -1
                }
            }
            exited.signal()
        }
        thread.name = "io.home-assistant.tailcat.accept"
        thread.start()
    }

    private func acceptLoop(listener fd: Int32, wake: Int32) {
        while true {
            var descriptors = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if descriptors[1].revents != 0 || lock.withLock({ isStopped }) {
                return
            }
            if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                break
            }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if [EINTR, EAGAIN, ECONNABORTED, EMFILE, ENFILE].contains(errno) { continue }
                break
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            handle(client: client)
        }

        Current.Log.warning("Tailcat: loopback listener on port \(port) stopped unexpectedly")
    }

    // MARK: - Piping

    private func handle(client fd: Int32) {
        let thread = Thread { [weak self] in
            guard let self else {
                Darwin.close(fd)
                return
            }
            let connection: TailcatConnection
            do {
                connection = try dialer.dial(port: tunnelPort, timeout: dialTimeout)
            } catch {
                Current.Log.error("Tailcat: could not open a tunnel stream: \(error)")
                Darwin.close(fd)
                return
            }

            let pipe = Pipe(socket: fd, connection: connection)
            let accepted: Bool = lock.withLock {
                guard !self.isStopped else { return false }
                self.pipes[ObjectIdentifier(pipe)] = pipe
                return true
            }
            guard accepted else {
                pipe.abort()
                pipe.finish()
                return
            }

            pipe.run(bufferSize: Self.bufferSize) { [weak self] in
                _ = self?.lock.withLock { self?.pipes.removeValue(forKey: ObjectIdentifier(pipe)) }
            }
        }
        thread.name = "io.home-assistant.tailcat.connection"
        thread.start()
    }

    /// One accepted loopback socket and its tunnel stream, copied in both directions on two threads.
    /// A side reaching end of stream half-closes the other; an error tears both down. The socket and
    /// stream are released once both directions are done.
    private final class Pipe {
        private let socket: Int32
        private let connection: TailcatConnection
        private let lock = NSLock()
        private var finishedDirections = 0
        private var isFinished = false

        init(socket: Int32, connection: TailcatConnection) {
            self.socket = socket
            self.connection = connection
        }

        func run(bufferSize: Int, onFinish: @escaping () -> Void) {
            let directionDone = { [self] in
                let bothDone: Bool = lock.withLock {
                    finishedDirections += 1
                    return finishedDirections == 2
                }
                if bothDone {
                    finish()
                    onFinish()
                }
            }

            let upstream = Thread { [self] in
                copySocketToTunnel(bufferSize: bufferSize)
                directionDone()
            }
            upstream.name = "io.home-assistant.tailcat.upstream"
            upstream.start()

            copyTunnelToSocket(bufferSize: bufferSize)
            directionDone()
        }

        /// Interrupts both directions.
        func abort() {
            lock.withLock {
                // Once closed, the descriptor number may already belong to someone else.
                guard !isFinished else { return }
                Darwin.shutdown(socket, SHUT_RDWR)
            }
            connection.close()
        }

        /// Releases the socket and the stream. Only called once both directions stopped.
        func finish() {
            lock.withLock {
                guard !isFinished else { return }
                isFinished = true
                Darwin.close(socket)
            }
            connection.close()
        }

        private func copySocketToTunnel(bufferSize: Int) {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 1)
            defer { buffer.deallocate() }

            while true {
                let count = recv(socket, buffer.baseAddress, bufferSize, 0)
                if count > 0 {
                    do {
                        try connection.write(UnsafeRawBufferPointer(rebasing: buffer[0 ..< count]))
                    } catch {
                        abort()
                        return
                    }
                } else if count == 0 {
                    // The loopback client finished sending: pass the half-close on.
                    do {
                        try connection.closeWrite()
                    } catch {
                        abort()
                    }
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    abort()
                    return
                }
            }
        }

        private func copyTunnelToSocket(bufferSize: Int) {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 1)
            defer { buffer.deallocate() }

            while true {
                let count: Int
                do {
                    count = try connection.read(into: buffer)
                } catch {
                    abort()
                    return
                }

                if count == 0 {
                    // The server finished sending: pass the half-close on.
                    Darwin.shutdown(socket, SHUT_WR)
                    return
                }

                guard sendAll(UnsafeRawBufferPointer(rebasing: buffer[0 ..< count])) else {
                    abort()
                    return
                }
            }
        }

        private func sendAll(_ bytes: UnsafeRawBufferPointer) -> Bool {
            var offset = 0
            while offset < bytes.count {
                let sent = send(socket, bytes.baseAddress! + offset, bytes.count - offset, 0)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
