import Foundation
@testable import HomeAssistant
@testable import Shared
import XCTest

/// The manager with fake tunnel clients: real loopback listeners, no Go runtime.
final class TailcatTunnelManagerTests: XCTestCase {
    private var manager: TailcatTunnelManager!
    private var configurations = [TailcatConfiguration]()

    override func setUp() {
        super.setUp()
        manager = TailcatTunnelManager(makeSession: {
            TailcatClientSession(configuration: $0, makeClient: { _ in FakeTailcatDialer() })
        })
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

    func testReturningFromTheBackgroundKeepsTheURL() throws {
        let first = try XCTUnwrap(manager.localURL(for: configuration()))

        manager.applicationDidEnterBackground()
        manager.applicationWillEnterForeground()

        XCTAssertEqual(manager.localURL(for: configuration()), first)
    }
}
