import Foundation
import Shared

/// Owns the Tailcat client for one tunnel endpoint: creates it lazily on the first dial, retries a
/// dial until the overall timeout, and replaces the client as soon as a dial on it fails.
///
/// A failed dial means the client cannot be trusted any more, whether or not it worked before:
///
/// - Right after pairing, Home Assistant restarts its Tailcat server to allowlist the new device, and
///   a client that registered before that never gets through.
/// - When the server restarts (an allowlist change, a Home Assistant restart), a client that was
///   working keeps a session to the old process: its dials time out and the streams it carries are
///   dead without either end noticing. A fresh client connects at once. Closing the old one also
///   closes those dead streams, which is what makes the web view and the websocket reconnect.
///
/// A client that already got through has its dials bounded by `establishedAttemptTimeout`, because
/// a dial on a working session takes well under a second; a fresh client gets the longer
/// `freshAttemptTimeout`, since registering and finding a path to the server can take a while on a
/// slow network, and cutting it off early would only start the same wait over with another client.
final class TailcatClientSession: TailcatDialing {
    typealias ClientFactory = (TailcatConfiguration) throws -> TailcatDialing

    private let makeClient: ClientFactory
    private let freshAttemptTimeout: TimeInterval
    private let establishedAttemptTimeout: TimeInterval
    private let retryDelay: TimeInterval
    private let closeQueue: DispatchQueue
    private let lock = NSLock()
    private var configuration: TailcatConfiguration
    private var client: TailcatDialing?
    private var clientHasDialed = false

    init(
        configuration: TailcatConfiguration,
        freshAttemptTimeout: TimeInterval = 20,
        establishedAttemptTimeout: TimeInterval = 6,
        retryDelay: TimeInterval = 1,
        closeQueue: DispatchQueue = .global(qos: .utility),
        makeClient: @escaping ClientFactory = { try LibTailcatClient(configuration: $0) }
    ) {
        self.configuration = configuration
        self.freshAttemptTimeout = freshAttemptTimeout
        self.establishedAttemptTimeout = establishedAttemptTimeout
        self.retryDelay = retryDelay
        self.closeQueue = closeQueue
        self.makeClient = makeClient
    }

    /// Switches to a new client key for the same endpoint; the next dial uses it.
    func update(configuration newConfiguration: TailcatConfiguration) {
        let changed = lock.withLock {
            guard configuration != newConfiguration else { return false }
            configuration = newConfiguration
            return true
        }
        if changed {
            reset()
        }
    }

    /// Closes the current client (and its streams); the next dial creates a fresh one.
    func reset() {
        let old: TailcatDialing? = lock.withLock {
            defer {
                client = nil
                clientHasDialed = false
            }
            return client
        }
        closeInBackground(old)
    }

    func close() {
        let old: TailcatDialing? = lock.withLock {
            defer { client = nil }
            return client
        }
        old?.close()
    }

    /// Dials `port`, retrying until `timeout` seconds have passed.
    func dial(port: UInt16, timeout: TimeInterval) throws -> TailcatConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = TailcatError(kind: .timeout)

        repeat {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            // An invalid configuration does not get better by retrying, so that error is thrown.
            let (current, isEstablished) = try currentClient()
            let attemptTimeout = isEstablished ? establishedAttemptTimeout : freshAttemptTimeout

            do {
                let connection = try current.dial(port: port, timeout: min(attemptTimeout, remaining))
                lock.withLock {
                    if client === current {
                        clientHasDialed = true
                    }
                }
                return connection
            } catch {
                lastError = error
                if discard(current) {
                    Current.Log.info("Tailcat: dial failed, starting a new client: \(error)")
                    continue
                }
                // Another dial already replaced this client (and closing it is what failed this one):
                // retry on the new client right away.
                if (error as? TailcatError)?.kind == .closed {
                    continue
                }
            }

            let pause = min(retryDelay, deadline.timeIntervalSinceNow)
            if pause > 0 {
                Thread.sleep(forTimeInterval: pause)
            }
        } while Date() < deadline

        throw lastError
    }

    private func currentClient() throws -> (TailcatDialing, isEstablished: Bool) {
        try lock.withLock {
            if let client {
                return (client, clientHasDialed)
            }
            let created = try makeClient(configuration)
            client = created
            clientHasDialed = false
            return (created, false)
        }
    }

    /// Drops `failed` if it is still the current client. Returns whether it was.
    private func discard(_ failed: TailcatDialing) -> Bool {
        let discarded: Bool = lock.withLock {
            guard client === failed else { return false }
            client = nil
            clientHasDialed = false
            return true
        }
        if discarded {
            closeInBackground(failed)
        }
        return discarded
    }

    /// Closing waits for every call on the client, so it never runs on the caller's thread.
    private func closeInBackground(_ client: TailcatDialing?) {
        guard let client else { return }
        closeQueue.async { client.close() }
    }
}
