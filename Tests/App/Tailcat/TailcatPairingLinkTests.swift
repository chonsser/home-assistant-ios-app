import Foundation
@testable import Shared
import Testing

@Suite("Tailcat pairing link")
struct TailcatPairingLinkTests {
    private static let address = "tc1example"
    private static let key = "privkey:0123456789abcdef"

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("A complete link carries the tunnel configuration and the server name")
    func parsesCompleteLink() throws {
        let link = try TailcatPairingLink(url: url(
            "homeassistant://tailcat/pair?address=\(Self.address)&key=privkey%3A0123456789abcdef&port=8123&name=My%20Home"
        ))

        #expect(link.configuration == TailcatConfiguration(
            address: Self.address,
            clientPrivateKey: Self.key,
            tunnelPort: 8123
        ))
        #expect(link.name == "My Home")
    }

    @Test("The name is optional")
    func nameIsOptional() throws {
        let link = try TailcatPairingLink(url: url(
            "homeassistant://tailcat/pair?address=\(Self.address)&key=\(Self.key)&port=1"
        ))

        #expect(link.name == nil)
        #expect(link.configuration.tunnelPort == 1)
    }

    @Test("Development builds' scheme is accepted, pasted text is trimmed")
    func acceptsDevelopmentSchemeAndTrims() throws {
        let link = try TailcatPairingLink(
            string: "  homeassistant-dev://tailcat/pair?address=\(Self.address)&key=\(Self.key)&port=65535\n"
        )

        #expect(link.configuration.tunnelPort == 65535)
    }

    @Test(
        "Links that are not the pairing route are rejected",
        arguments: [
            "https://tailcat/pair?address=tc1&key=privkey:1&port=1",
            "homeassistant://invite/pair?address=tc1&key=privkey:1&port=1",
            "homeassistant://tailcat/unpair?address=tc1&key=privkey:1&port=1",
            "homeassistant://tailcat?address=tc1&key=privkey:1&port=1",
            "not a url",
        ]
    )
    func rejectsOtherRoutes(string: String) {
        #expect(throws: TailcatPairingLinkError.invalidLink) {
            try TailcatPairingLink(string: string)
        }
    }

    @Test(
        "The address must be a Tailcat address",
        arguments: ["", "&address=", "&address=xx1abc", "&address=tc", "&address=tc1&address=tc2"]
    )
    func rejectsInvalidAddress(query: String) throws {
        let link = try url("homeassistant://tailcat/pair?key=\(Self.key)&port=8123\(query)")
        #expect(throws: TailcatPairingLinkError.invalidAddress) {
            try TailcatPairingLink(url: link)
        }
    }

    @Test(
        "The key must be a Tailcat private key",
        arguments: ["", "&key=", "&key=nodekey:abc", "&key=privkey:", "&key=privkey%3Aa%20b"]
    )
    func rejectsInvalidKey(query: String) throws {
        let link = try url("homeassistant://tailcat/pair?address=\(Self.address)&port=8123\(query)")
        #expect(throws: TailcatPairingLinkError.invalidKey) {
            try TailcatPairingLink(url: link)
        }
    }

    @Test(
        "The port must be within 1-65535",
        arguments: ["", "&port=", "&port=0", "&port=65536", "&port=-1", "&port=80a", "&port=%EF%BC%98"]
    )
    func rejectsInvalidPort(query: String) throws {
        let link = try url("homeassistant://tailcat/pair?address=\(Self.address)&key=\(Self.key)\(query)")
        #expect(throws: TailcatPairingLinkError.invalidPort) {
            try TailcatPairingLink(url: link)
        }
    }

    @Test("Every rejection explains itself")
    func errorsAreLocalized() {
        for error in [
            TailcatPairingLinkError.invalidLink,
            .invalidAddress,
            .invalidKey,
            .invalidPort,
        ] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("The configuration never prints its secrets")
    func descriptionIsRedacted() {
        let configuration = TailcatConfiguration(address: Self.address, clientPrivateKey: Self.key, tunnelPort: 8123)

        #expect(!String(describing: configuration).contains(Self.address))
        #expect(!String(describing: configuration).contains(Self.key))
        #expect(!String(reflecting: configuration).contains(Self.key))
    }
}
