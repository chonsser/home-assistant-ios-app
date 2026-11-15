import Foundation
@testable import HomeAssistant
@testable import Shared
import XCTest

/// The manager with fake tunnel clients: real loopback listeners, no Go runtime.
final class TailcatTunnelManagerTests: XCTestCase {
    private var manager: TailcatTunnelManager!
    private var configurations = [TailcatConfiguration]()
    private var clients = [FakeTailcatDialer]()
    private let clientsLock = NSLock()

    override func setUp() {
        super.setUp()
        manager = TailcatTunnelManager(makeSession: { [unowned self] configuration in
            TailcatClientSession(configuration: configuration, makeClient: { [unowned self] _ in
                let client = FakeTailcatDialer()
                clientsLock.withLock { clients.append(client) }
                return client
            })
        })
    }

    private var madeClients: [FakeTailcatDialer] {
        clientsLock.withLock { clients }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        wait(for: [expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)], timeout: 30)
    }

    /// Opens a loopback connection so the tunnel dials and its client exists.
    private func connect(to url: URL) throws {
        let done = expectation(description: "request")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        waitUntil { !self.madeClients.isEmpty }
        session.invalidateAndCancel()
        wait(for: [done], timeout: 30)
    }

    override func tearDown() {
        configurations.forEach { manager.stopTunnel(for: $0) }
        configurations = []
        manager = nil
        super.tearDown()
    }

    private func configuration(port: UInt16 = 8123, key: String = "privkey:0123") -> TailcatConfiguration {
        let configuration = TailcatConfiguration(
            address: "tc1\(name.filter(\.isLetter))",
            clientPrivateKey: key,
            tunnelPort: port
        )
        configurations.append(configuration)
        return configuration
    }

    func testTheURLIsStableForAnEndpoint() throws {
        let first = try XCTUnwrap(manager.localURL(for: configuration()))

        XCTAssertEqual(manager.localURL(for: configuration()), first)
        XCTAssertEqual(manager.localURL(for: configuration(key: "privkey:4567")), first)
        XCTAssertEqual(first.host, "127.0.0.1")
        XCTAssertEqual(first.scheme, "http")
        let port = try XCTUnwrap(first.port.map(UInt16.init))
        XCTAssertTrue(
            TailcatLocalPort.candidates(startingAt: TailcatLocalPort.preferred(for: configuration()), count: 64)
                .contains(port)
        )
    }

    func testEveryEndpointGetsItsOwnURL() throws {
        let first = try XCTUnwrap(manager.localURL(for: configuration(port: 8123)))
        let second = try XCTUnwrap(manager.localURL(for: configuration(port: 8124)))

        XCTAssertNotEqual(first, second)
    }

    func testAStoppedTunnelStartsAgainOnTheSamePort() throws {
        let first = try XCTUnwrap(manager.localURL(for: configuration()))

        manager.stopTunnel(for: configuration())
        let restarted = try XCTUnwrap(manager.localURL(for: configuration()))

        XCTAssertEqual(restarted, first)
    }

    func testANetworkChangeStartsNewTunnelClients() throws {
        let url = try XCTUnwrap(manager.localURL(for: configuration()))
        manager.networkPathDidChange(to: "satisfied:wifi:en0")
        try connect(to: url)
        let first = try XCTUnwrap(madeClients.first)

        manager.networkPathDidChange(to: "satisfied:wifi:en0")
        XCTAssertEqual(first.closes, 0, "an unchanged path keeps the client")

        manager.networkPathDidChange(to: "satisfied:cellular:pdp_ip0")
        waitUntil { first.closes == 1 }
    }

    func testReturningFromTheBackgroundKeepsTheURL() throws {
        let first = try XCTUnwrap(manager.localURL(for: configuration()))

        manager.applicationDidEnterBackground()
        manager.applicationWillEnterForeground()

        XCTAssertEqual(manager.localURL(for: configuration()), first)
    }
}
