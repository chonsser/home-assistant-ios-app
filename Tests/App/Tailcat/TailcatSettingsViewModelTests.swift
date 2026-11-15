import AVFoundation
import Foundation
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite("Tailcat settings")
@MainActor
struct TailcatSettingsViewModelTests {
    private static let link =
        "homeassistant://tailcat/pair?address=tc1example&key=privkey%3A0123&port=8123&name=Home"
    private static let configuration = TailcatConfiguration(
        address: "tc1example",
        clientPrivateKey: "privkey:0123",
        tunnelPort: 8123
    )

    private func makeViewModel(
        server: Server = .fake(),
        cameraAuthorizationStatus: AVAuthorizationStatus = .authorized,
        hasCamera: Bool = true
    ) -> TailcatSettingsViewModel {
        TailcatSettingsViewModel(
            server: server,
            attach: { configuration, server in server.update { $0.connection.tailcat = configuration } },
            remove: { server in server.update { $0.connection.tailcat = nil } },
            cameraAuthorizationStatus: { cameraAuthorizationStatus },
            hasCamera: { hasCamera }
        )
    }

    @Test("A server without a pairing says so")
    func notPaired() {
        let viewModel = makeViewModel()

        #expect(!viewModel.isPaired)
        #expect(viewModel.statusText == L10n.Settings.ConnectionSection.Tailcat.Status.notPaired)
        #expect(!viewModel.canPairFromText)
    }

    @Test("Pasting a pairing link pairs the server")
    func pairsFromPastedLink() {
        let server = Server.fake()
        let viewModel = makeViewModel(server: server)

        viewModel.linkText = Self.link
        viewModel.pairFromText()

        #expect(server.info.connection.tailcat == Self.configuration)
        #expect(viewModel.isPaired)
        #expect(viewModel.linkText.isEmpty)
        #expect(viewModel.showsPairedConfirmation)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A scanned code pairs the server and closes the scanner")
    func pairsFromScan() {
        let server = Server.fake()
        let viewModel = makeViewModel(server: server)
        viewModel.isScanning = true

        viewModel.pairFromScan(Self.link)

        #expect(!viewModel.isScanning)
        #expect(server.info.connection.tailcat == Self.configuration)
    }

    @Test("An invalid link explains what is wrong and changes nothing")
    func rejectsInvalidLink() {
        let server = Server.fake()
        let viewModel = makeViewModel(server: server)

        viewModel.linkText = "homeassistant://tailcat/pair?address=tc1example&key=privkey%3A0123&port=0"
        viewModel.pairFromText()

        #expect(server.info.connection.tailcat == nil)
        #expect(viewModel.errorMessage == TailcatPairingLinkError.invalidPort.errorDescription)
        #expect(viewModel.showsError)
        viewModel.showsError = false
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Removing the pairing unpairs the server")
    func removesPairing() {
        let server = Server.fake { $0.connection.tailcat = Self.configuration }
        let viewModel = makeViewModel(server: server)
        #expect(viewModel.isPaired)

        viewModel.confirmRemoval()
        #expect(viewModel.isRemoveConfirmationPresented)
        viewModel.removePairing()

        #expect(server.info.connection.tailcat == nil)
        #expect(!viewModel.isPaired)
    }

    @Test("Without camera access the scanner falls back to typing the link in")
    func scannerStatus() {
        #expect(makeViewModel().scannerStatus == .scanning)
        #expect(makeViewModel(cameraAuthorizationStatus: .notDetermined).scannerStatus == .scanning)
        #expect(makeViewModel(cameraAuthorizationStatus: .denied).scannerStatus == .unavailable(
            L10n.Settings.ConnectionSection.Tailcat.Scanner.unavailable
        ))
        #expect(makeViewModel(hasCamera: false).scannerStatus == .unavailable(
            L10n.Settings.ConnectionSection.Tailcat.Scanner.unavailable
        ))
    }
}
