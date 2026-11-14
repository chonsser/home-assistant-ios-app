import Foundation
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite("Tailcat loopback port")
struct TailcatLocalPortTests {
    private let configuration = TailcatConfiguration(
        address: "tc1example",
        clientPrivateKey: "privkey:0123",
        tunnelPort: 8123
    )

    @Test("The preferred port is a pure function of the tunnel endpoint")
    func isDeterministic() {
        // Pinned: a different value on another launch or build would change the frontend's origin
        // and with it the web view's stored login state.
        #expect(TailcatLocalPort.fnv1a64("") == 0xCBF2_9CE4_8422_2325)
        #expect(TailcatLocalPort.fnv1a64("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(TailcatLocalPort.preferred(for: configuration) == TailcatLocalPort.preferred(for: configuration))
        #expect(
            TailcatLocalPort.preferred(for: configuration)
                == TailcatLocalPort.preferred(forIdentity: "tc1example:8123")
        )
    }

    @Test("A new client key keeps the port, another endpoint gets its own")
    func dependsOnTheEndpointOnly() {
        var rekeyed = configuration
        rekeyed.clientPrivateKey = "privkey:4567"
        var otherPort = configuration
        otherPort.tunnelPort = 8124

        #expect(TailcatLocalPort.preferred(for: rekeyed) == TailcatLocalPort.preferred(for: configuration))
        #expect(TailcatLocalPort.preferred(for: otherPort) != TailcatLocalPort.preferred(for: configuration))
    }

    @Test("Ports stay within the range", arguments: ["", "tc1", "tc1example:1", "tc1example:65535", "x"])
    func staysInRange(identity: String) {
        #expect(TailcatLocalPort.range.contains(TailcatLocalPort.preferred(forIdentity: identity)))
    }

    @Test("Fallback candidates walk forward and wrap within the range")
    func candidatesWrap() {
        #expect(TailcatLocalPort.candidates(startingAt: 30000, count: 3) == [30000, 30001, 30002])
        #expect(TailcatLocalPort.candidates(startingAt: 59998, count: 4) == [59998, 59999, 20000, 20001])
        #expect(TailcatLocalPort.candidates(startingAt: 1, count: 1) == [20000])
    }
}
