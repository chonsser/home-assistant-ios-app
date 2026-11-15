import Foundation
import ObjectMapper
@testable import Shared
import XCTest

/// `ConnectionInfo` with a Tailcat tunnel. XCTest rather than Swift Testing because the tunnel hook
/// lives on the process-wide `HANetworkingEnvironment`, which XCTest classes swap one at a time.
final class ConnectionInfoTailcatTests: XCTestCase {
    private static let tailcat = TailcatConfiguration(
        address: "tc1example",
        clientPrivateKey: "privkey:0123",
        tunnelPort: 8123
    )
    private static let tunnelURL = URL(string: "http://127.0.0.1:43123")!

    private var previousTailcatLocalURL: ((TailcatConfiguration) -> URL?)!
    private var previousLastKnownNetworkState: (() -> NetworkState)!

    override func setUp() {
        super.setUp()
        previousTailcatLocalURL = HANetworkingEnvironment.current.tailcatLocalURL
        previousLastKnownNetworkState = Current.connectivity.lastKnownNetworkState
        setTunnelAvailable(true)
        setNetworkState(NetworkState())
    }

    override func tearDown() {
        HANetworkingEnvironment.current.tailcatLocalURL = previousTailcatLocalURL
        Current.connectivity.lastKnownNetworkState = previousLastKnownNetworkState
        super.tearDown()
    }

    private func setTunnelAvailable(_ available: Bool) {
        HANetworkingEnvironment.current.tailcatLocalURL = { configuration in
            available && configuration == Self.tailcat ? Self.tunnelURL : nil
        }
    }

    private func setNetworkState(_ state: NetworkState) {
        Current.connectivity.lastKnownNetworkState = { state }
    }

    private func connection(
        internalURL: URL? = nil,
        externalURL: URL? = nil,
        remoteUIURL: URL? = nil,
        useCloud: Bool = false,
        securityLevel: ConnectionSecurityLevel = .mostSecure,
        tailcat: TailcatConfiguration? = ConnectionInfoTailcatTests.tailcat
    ) -> ConnectionInfo {
        var info = ConnectionInfo(
            externalURL: externalURL,
            internalURL: internalURL,
            cloudhookURL: nil,
            remoteUIURL: remoteUIURL,
            webhookID: "webhook",
            webhookSecret: "secret",
            internalSSIDs: ["Home"],
            internalHardwareAddresses: nil,
            isLocalPushEnabled: false,
            securityExceptions: .init(),
            connectionAccessSecurityLevel: securityLevel,
            tailcat: tailcat
        )
        info.useCloud = useCloud
        return info
    }

    // MARK: - Codable

    func testURLTypeRawValuesStayStable() {
        XCTAssertEqual(ConnectionInfo.URLType.internal.rawValue, 0)
        XCTAssertEqual(ConnectionInfo.URLType.remoteUI.rawValue, 1)
        XCTAssertEqual(ConnectionInfo.URLType.external.rawValue, 2)
        XCTAssertEqual(ConnectionInfo.URLType.none.rawValue, 3)
        XCTAssertEqual(ConnectionInfo.URLType.tailcat.rawValue, 4)
    }

    func testDecodesConnectionsStoredBeforeTailcat() throws {
        let json = """
        {"webhookID": "webhook", "internalURL": "http://homeassistant.local:8123", "useCloud": false}
        """
        let info = try JSONDecoder().decode(ConnectionInfo.self, from: Data(json.utf8))

        XCTAssertNil(info.tailcat)
        XCTAssertEqual(info.address(for: .internal), URL(string: "http://homeassistant.local:8123"))
    }

    func testRoundTripsTheTailcatConfiguration() throws {
        let original = connection(externalURL: URL(string: "https://example.com"))
        let decoded = try JSONDecoder().decode(ConnectionInfo.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.tailcat, Self.tailcat)
        XCTAssertEqual(decoded.address(for: .external), URL(string: "https://example.com"))
    }

    func testMalformedTailcatConfigurationOnlyCostsTheTunnel() throws {
        let json = """
        {"webhookID": "webhook", "externalURL": "https://example.com", "tailcat": {"address": 1}}
        """
        let info = try JSONDecoder().decode(ConnectionInfo.self, from: Data(json.utf8))

        XCTAssertNil(info.tailcat)
        XCTAssertEqual(info.address(for: .external), URL(string: "https://example.com"))
    }

    // MARK: - Active URL

    func testTailcatIsUsedWhenItIsTheOnlyRoute() {
        var info = connection()

        XCTAssertEqual(info.evaluateActiveURL(), Self.tunnelURL)
        XCTAssertEqual(info.activeURLType, .tailcat)
        XCTAssertEqual(info.evaluateWebhookURL(), Self.tunnelURL.appendingPathComponent("api/webhook/webhook"))
    }

    func testProcessesWithoutTheTunnelSkipTailcat() {
        setTunnelAvailable(false)
        var info = connection(internalURL: URL(string: "http://homeassistant.local:8123"))

        XCTAssertNil(info.evaluateActiveURL())
        XCTAssertEqual(info.activeURLType, .none)
        XCTAssertNil(info.address(for: .tailcat))
    }

    func testInternalURLWinsOnTheHomeNetwork() {
        setNetworkState(NetworkState(ssid: "Home"))
        var info = connection(internalURL: URL(string: "http://homeassistant.local:8123"))

        XCTAssertEqual(info.evaluateActiveURL(), URL(string: "http://homeassistant.local:8123"))
        XCTAssertEqual(info.activeURLType, .internal)
    }

    func testCloudWinsWhenEnabled() {
        var info = connection(remoteUIURL: URL(string: "https://example.ui.nabu.casa"), useCloud: true)

        XCTAssertEqual(info.evaluateActiveURL(), URL(string: "https://example.ui.nabu.casa"))
        XCTAssertEqual(info.activeURLType, .remoteUI)
    }

    func testTailcatIsUsedWhenCloudIsDisabled() {
        var info = connection(remoteUIURL: URL(string: "https://example.ui.nabu.casa"), useCloud: false)

        XCTAssertEqual(info.evaluateActiveURL(), Self.tunnelURL)
        XCTAssertEqual(info.activeURLType, .tailcat)
    }

    func testExternalURLWinsOverTailcat() {
        var info = connection(externalURL: URL(string: "https://example.duckdns.org"))

        XCTAssertEqual(info.evaluateActiveURL(), URL(string: "https://example.duckdns.org"))
        XCTAssertEqual(info.activeURLType, .external)
    }

    func testTailcatWinsOverTheInternalFallbacksAwayFromHome() {
        var lessSecure = connection(
            internalURL: URL(string: "http://homeassistant.local:8123"),
            securityLevel: .lessSecure
        )
        XCTAssertEqual(lessSecure.evaluateActiveURL(), Self.tunnelURL)
        XCTAssertEqual(lessSecure.activeURLType, .tailcat)

        var https = connection(internalURL: URL(string: "https://homeassistant.local:8123"))
        XCTAssertEqual(https.evaluateActiveURL(), Self.tunnelURL)
        XCTAssertEqual(https.activeURLType, .tailcat)
    }

    func testOverrideSelectsTailcat() {
        setNetworkState(NetworkState(ssid: "Home"))
        var info = connection(internalURL: URL(string: "http://homeassistant.local:8123"))
        info.overrideActiveURLType = .tailcat

        XCTAssertEqual(info.evaluateActiveURL(), Self.tunnelURL)
        XCTAssertEqual(info.activeURLType, .tailcat)
    }

    func testOverrideFallsBackWithoutTheTunnel() {
        setTunnelAvailable(false)
        setNetworkState(NetworkState(ssid: "Home"))
        var info = connection(internalURL: URL(string: "http://homeassistant.local:8123"))
        info.overrideActiveURLType = .tailcat

        XCTAssertEqual(info.evaluateActiveURL(), URL(string: "http://homeassistant.local:8123"))
        XCTAssertEqual(info.activeURLType, .internal)
    }

    func testRemovingThePairingClearsATailcatOverride() {
        var info = connection()
        info.overrideActiveURLType = .tailcat

        info.tailcat = nil

        XCTAssertNil(info.overrideActiveURLType)
    }

    // MARK: - Security

    func testTailcatCountsAsASecureRemoteConnection() {
        let info = connection()

        XCTAssertTrue(info.hasRemoteConnectionSetup)
        XCTAssertTrue(info.hasHTTPSURLOption)
        XCTAssertFalse(info.hasNonHTTPSURLOptions)
        XCTAssertTrue(info.configuredURLs.isEmpty)
    }

    func testTailcatIsSecureEvenWithoutTheTunnelInThisProcess() {
        setTunnelAvailable(false)
        let info = connection(internalURL: URL(string: "http://homeassistant.local:8123"))

        XCTAssertTrue(info.hasHTTPSURLOption)
        XCTAssertTrue(info.hasRemoteConnectionSetup)
    }

    func testThePlainHTTPInternalURLStillCountsAsNonHTTPS() {
        let info = connection(internalURL: URL(string: "http://homeassistant.local:8123"))

        XCTAssertTrue(info.hasNonHTTPSURLOptions)
        XCTAssertEqual(info.configuredURLs, [URL(string: "http://homeassistant.local:8123")!])
    }

    func testTheLoopbackURLIsNeverAnInvitation() {
        XCTAssertNil(connection().invitationURL())
        XCTAssertEqual(
            connection(internalURL: URL(string: "http://homeassistant.local:8123")).invitationURL(),
            URL(string: "http://homeassistant.local:8123")
        )
    }

    func testTailcatCanBeUsedToAuthenticate() {
        XCTAssertEqual(
            connection(internalURL: URL(string: "http://homeassistant.local:8123")).availableAuthenticationURLTypes,
            [.tailcat, .internal]
        )

        setTunnelAvailable(false)
        XCTAssertEqual(
            connection(internalURL: URL(string: "http://homeassistant.local:8123")).availableAuthenticationURLTypes,
            [.internal]
        )
    }

    func testTheTunnelIdentifiesTheServer() {
        XCTAssertEqual(connection().hostAndPortIdentities, ["127.0.0.1:43123"])
    }

    func testTheLoopbackURLIsNeverStoredAsAnAddress() {
        var info = connection()

        info.set(address: Self.tunnelURL, for: .tailcat)

        XCTAssertTrue(info.configuredURLs.isEmpty)
        XCTAssertEqual(info.tailcat, Self.tailcat)
    }

    // MARK: - Server refreshes

    func testConfigRefreshKeepsThePairing() throws {
        let config = try XCTUnwrap(ConfigResponse(JSON: [
            "version": "2026.9.3",
            "remote_ui_url": "https://example.ui.nabu.casa",
        ]))
        var info = ServerInfo.fake()
        info.connection.tailcat = Self.tailcat

        info.apply(config)

        XCTAssertEqual(info.connection.tailcat, Self.tailcat)
        XCTAssertEqual(info.connection.address(for: .remoteUI), URL(string: "https://example.ui.nabu.casa"))
    }

    func testDiscoveredTailcatInstanceSignsInThroughTheTunnel() {
        let instance = DiscoveredHomeAssistant(tailcat: Self.tailcat, localURL: Self.tunnelURL, name: "Home")

        XCTAssertEqual(instance.tailcat, Self.tailcat)
        XCTAssertEqual(instance.internalURL, Self.tunnelURL)
        XCTAssertNil(instance.externalURL)
        XCTAssertEqual(instance.locationName, "Home")
        XCTAssertFalse(instance.hasHomeAssistantInstanceID)
    }
}
