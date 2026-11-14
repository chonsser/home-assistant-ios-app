import Foundation
import Shared

/// Owns the Tailcat client for one tunnel endpoint: creates it lazily on the first dial, retries a
/// dial until the overall timeout, and replaces the client when it turns out to be unusable.
///
/// Retrying matters right after pairing: Home Assistant restarts its Tailcat server to allowlist a
/// new device, which takes a couple of seconds, and a client that registered before that never gets
/// through. A client that never dialed successfully is therefore replaced after a failed attempt.
/// One that did keeps serving its other streams unless it fails repeatedly. After the app returns
/// from the background the Go runtime's sockets may be dead, so `reset()` drops the client and the
/// next dial starts a fresh one.
final class TailcatClientSession: TailcatDialing {
    typealias ClientFactory = (TailcatConfiguration) throws -> TailcatDialing

    private let makeClient: ClientFactory
    private let attemptTimeout: TimeInterval
    private let retryDelay: TimeInterval
    private let consecutiveFailuresBeforeReset: Int
    private let lock = NSLock()
    private var configuration: TailcatConfiguration
    private var client: TailcatDialing?
    private var clientHasDialed = false
    private var consecutiveFailures = 0

    init(
        configuration: TailcatConfiguration,
        attemptTimeout: TimeInterval = 10,
        retryDelay: TimeInterval = 1,
        consecutiveFailuresBeforeReset: Int = 2,
        makeClient: @escaping ClientFactory = { try LibTailcatClient(configuration: $0) }
    ) {
        self.configuration = configuration
        self.attemptTimeout = attemptTimeout
        self.retryDelay = retryDelay
        self.consecutiveFailuresBeforeReset = consecutiveFailuresBeforeReset
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
                consecutiveFailures = 0
            }
            return client
        }
        // Closing waits for every call on the client, so it never runs on the caller's thread.
        if let old {
            DispatchQueue.global(qos: .utility).async { old.close() }
        }
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
            let current = try currentClient()

            do {
                let connection = try current.dial(port: port, timeout: min(attemptTimeout, remaining))
                lock.withLock {
                    if client === current {
                        clientHasDialed = true
                        consecutiveFailures = 0
                    }
                }
                return connection
            } catch {
                lastError = error
                Current.Log.info("Tailcat: dial attempt failed, retrying: \(error)")
                discardIfUnusable(current)
            }

            let pause = min(retryDelay, deadline.timeIntervalSinceNow)
            if pause > 0 {
                Thread.sleep(forTimeInterval: pause)
            }
        } while Date() < deadline

        throw lastError
    }

    private func currentClient() throws -> TailcatDialing {
        try lock.withLock {
            if let client {
                return client
            }
            let created = try makeClient(configuration)
            client = created
            clientHasDialed = false
            consecutiveFailures = 0
            return created
        }
    }

    private func discardIfUnusable(_ failed: TailcatDialing) {
        let discarded: TailcatDialing? = lock.withLock {
            guard client === failed else { return nil }
            consecutiveFailures += 1
            guard !clientHasDialed || consecutiveFailures >= consecutiveFailuresBeforeReset else { return nil }
            client = nil
            clientHasDialed = false
            consecutiveFailures = 0
            return failed
        }
        if let discarded {
            DispatchQueue.global(qos: .utility).async { discarded.close() }
        }
    }
}
