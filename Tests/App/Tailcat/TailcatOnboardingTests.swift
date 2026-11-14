import Foundation
@testable import HomeAssistant
@testable import Shared
import XCTest

/// Onboarding through a Tailcat pairing link signs in through the tunnel's loopback URL but must
/// recognize the server by its tunnel afterwards.
final class TailcatOnboardingTests: XCTestCase {
    private static let tailcat = TailcatConfiguration(
        address: "tc1example",
        clientPrivateKey: "privkey:0123",
        tunnelPort: 8123
    )
    private static let tunnelURL = URL(string: "http://127.0.0.1:43123")!
    private var previousTailcatLocalURL: ((TailcatConfiguration) -> URL?)!

    override func setUp() {
        super.setUp()
        previousTailcatLocalURL = HANetworkingEnvironment.current.tailcatLocalURL
        HANetworkingEnvironment.current.tailcatLocalURL = { $0 == Self.tailcat ? Self.tunnelURL : nil }
    }

    override func tearDown() {
        HANetworkingEnvironment.current.tailcatLocalURL = previousTailcatLocalURL
        super.tearDown()
    }

    private func info(tailcat: TailcatConfiguration?, instanceID: String?) -> ServerInfo {
        var info = ServerInfo.fake()
        info.connection.set(address: nil, for: .external)
        info.connection.set(address: nil, for: .internal)
        info.connection.tailcat = tailcat
        info.instanceID = instanceID
        return info
    }

    func testTheSignedInURLOfATailcatServerIsItsTunnel() {
        let connection = info(tailcat: Self.tailcat, instanceID: nil).connection

        XCTAssertEqual(OnboardingAuthStepConfig.signedInURL(of: connection), Self.tunnelURL)
    }

    func testTheInternalURLStillWinsWhenThereIsOne() {
        var connection = info(tailcat: Self.tailcat, instanceID: nil).connection
        connection.set(address: URL(string: "http://homeassistant.local:8123"), for: .internal)

        XCTAssertEqual(
            OnboardingAuthStepConfig.signedInURL(of: connection),
            URL(string: "http://homeassistant.local:8123")
        )
    }

    func testPairingAgainRecognizesTheSameServer() {
        let existing = Server.fake(initial: info(tailcat: Self.tailcat, instanceID: "instance-1"))

        let identity = OnboardingAuth.serverIdentity(
            for: info(tailcat: Self.tailcat, instanceID: "instance-1"),
            fallback: .init(rawValue: "fallback"),
            existingServers: [existing]
        )

        XCTAssertEqual(identity, .existing(existing.identifier))
    }
}
