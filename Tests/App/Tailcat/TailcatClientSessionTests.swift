import Foundation
@testable import HomeAssistant
@testable import Shared
import XCTest

final class TailcatClientSessionTests: XCTestCase {
    private let configuration = TailcatConfiguration(
        address: "tc1example",
        clientPrivateKey: "privkey:0123",
        tunnelPort: 8123
    )

    private final class Factory {
        private let lock = NSLock()
        private var pending: [FakeTailcatDialer]
        private(set) var made = [FakeTailcatDialer]()
        private(set) var configurations = [TailcatConfiguration]()

        init(_ clients: [FakeTailcatDialer]) {
            self.pending = clients
        }

        func make(_ configuration: TailcatConfiguration) -> TailcatDialing {
            lock.withLock {
                let client = pending.isEmpty ? FakeTailcatDialer() : pending.removeFirst()
                made.append(client)
                configurations.append(configuration)
                return client
            }
        }

        var count: Int { lock.withLock { made.count } }
    }

    private func session(_ factory: Factory) -> TailcatClientSession {
        TailcatClientSession(
            configuration: configuration,
            freshAttemptTimeout: 2,
            establishedAttemptTimeout: 1,
            retryDelay: 0.01,
            makeClient: factory.make
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        wait(for: [expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)], timeout: 30)
    }

    func testCreatesTheClientLazilyAndReusesIt() throws {
        let factory = Factory([])
        let session = session(factory)
        XCTAssertEqual(factory.count, 0)

        _ = try session.dial(port: 8123, timeout: 5)
        _ = try session.dial(port: 8123, timeout: 5)

        XCTAssertEqual(factory.count, 1)
        XCTAssertEqual(factory.made.first?.dials, [8123, 8123])
        XCTAssertEqual(factory.configurations, [configuration])
    }

    func testRetriesWithAFreshClientUntilTheServerLetsItIn() throws {
        let rejected = FakeTailcatDialer(results: [.failure(TailcatError(kind: .timeout))])
        let factory = Factory([rejected])
        let session = session(factory)

        _ = try session.dial(port: 8123, timeout: 5)

        XCTAssertEqual(factory.count, 2, "a client that never got through is replaced")
        waitUntil { rejected.closes == 1 }
    }

    func testGivesUpAfterTheTimeout() {
        let failing = (0 ..< 1000).map { _ in FakeTailcatDialer(results: [.failure(TailcatError(kind: .timeout))]) }
        let session = session(Factory(failing))

        XCTAssertThrowsError(try session.dial(port: 8123, timeout: 0.2)) { error in
            XCTAssertEqual((error as? TailcatError)?.kind, .timeout)
        }
    }

    /// What a Tailcat server restart looks like from the app: the client that was working keeps a
    /// session to the old process and its next dial times out, while a fresh client gets through.
    func testAClientThatStopsGettingThroughIsReplacedAtOnce() throws {
        let stale = FakeTailcatDialer(results: [
            .success(FakeTailcatConnection()),
            .failure(TailcatError(kind: .timeout)),
        ])
        let factory = Factory([stale])
        let session = session(factory)
        _ = try session.dial(port: 8123, timeout: 5)

        _ = try session.dial(port: 8123, timeout: 5)

        XCTAssertEqual(factory.count, 2, "one failed dial is enough to start a new client")
        XCTAssertEqual(stale.dials.count, 2, "the stale client is not tried again")
        // Closing the stale client is what closes the dead streams it still carries.
        waitUntil { stale.closes == 1 }
    }

    func testEstablishedClientsGetShorterAttempts() throws {
        let client = FakeTailcatDialer()
        let session = session(Factory([client]))

        _ = try session.dial(port: 8123, timeout: 5)
        _ = try session.dial(port: 8123, timeout: 5)

        XCTAssertEqual(client.timeouts, [2, 1])
    }

    func testAttemptsNeverOutlastTheOverallTimeout() throws {
        let client = FakeTailcatDialer()
        let session = session(Factory([client]))

        _ = try session.dial(port: 8123, timeout: 0.5)

        XCTAssertLessThanOrEqual(try XCTUnwrap(client.timeouts.first), 0.5)
    }

    func testResetStartsAFreshClient() throws {
        let factory = Factory([])
        let session = session(factory)
        _ = try session.dial(port: 8123, timeout: 5)

        session.reset()
        _ = try session.dial(port: 8123, timeout: 5)

        XCTAssertEqual(factory.count, 2)
        waitUntil { factory.made[0].closes == 1 }
    }

    func testANewKeyStartsAFreshClientWithIt() throws {
        let factory = Factory([])
        let session = session(factory)
        _ = try session.dial(port: 8123, timeout: 5)

        var rekeyed = configuration
        rekeyed.clientPrivateKey = "privkey:4567"
        session.update(configuration: rekeyed)
        session.update(configuration: rekeyed)
        _ = try session.dial(port: 8123, timeout: 5)

        XCTAssertEqual(factory.configurations, [configuration, rekeyed])
    }

    func testAnInvalidConfigurationIsNotRetried() {
        var attempts = 0
        let session = TailcatClientSession(configuration: configuration, makeClient: { _ in
            attempts += 1
            throw TailcatError(kind: .invalidArgument)
        })

        XCTAssertThrowsError(try session.dial(port: 8123, timeout: 5))
        XCTAssertEqual(attempts, 1)
    }
}
