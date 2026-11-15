import Foundation
@testable import HomeAssistant
@testable import Shared
import XCTest

/// Talks to a real Tailcat server through the real libtailcat client. Skipped unless a pairing link
/// is provided, so it never runs in CI:
///
///     TEST_RUNNER_TAILCAT_LIVE_PAIRING_LINK='homeassistant://tailcat/pair?…' \
///         xcodebuild test … -only-testing:Tests-App/TailcatLiveTunnelTests
///
/// The server behind the link must answer `GET /` (or `TAILCAT_LIVE_PATH`) with HTTP 200.
final class TailcatLiveTunnelTests: XCTestCase {
    func testFetchesThroughALiveTunnel() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let linkString = environment["TAILCAT_LIVE_PAIRING_LINK"], !linkString.isEmpty else {
            throw XCTSkip("TAILCAT_LIVE_PAIRING_LINK is not set")
        }
        let link = try TailcatPairingLink(string: linkString)
        let manager = TailcatTunnelManager()
        defer { manager.stopTunnel(for: link.configuration) }

        let localURL = try XCTUnwrap(manager.localURL(for: link.configuration))
        let url = localURL.appendingPathComponent(environment["TAILCAT_LIVE_PATH"] ?? "")

        let done = expectation(description: "response")
        var status: Int?
        var failure: Error?
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        session.dataTask(with: url) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode
            failure = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 90)
        session.invalidateAndCancel()

        XCTAssertNil(failure)
        XCTAssertEqual(status, 200)
    }
}
