import AVFoundation
import Foundation
import HADesignSystem
import Shared

/// Backs the Tailcat section of a server's connection settings: whether the server is paired, which
/// URL the app uses right now, and pairing or unpairing it.
@MainActor
final class TailcatSettingsViewModel: ObservableObject {
    let server: Server

    @Published private(set) var isPaired = false
    @Published private(set) var activeURLType: ConnectionInfo.URLType = .none
    @Published var linkText = ""
    @Published var isScanning = false
    @Published var isRemoveConfirmationPresented = false
    @Published var errorMessage: String?
    @Published var showsPairedConfirmation = false

    private let attach: (TailcatConfiguration, Server) -> Void
    private let remove: (Server) -> Void
    private let cameraAuthorizationStatus: () -> AVAuthorizationStatus
    private let hasCamera: () -> Bool

    init(
        server: Server,
        attach: @escaping (TailcatConfiguration, Server) -> Void = { TailcatServerPairing.attach($0, to: $1) },
        remove: @escaping (Server) -> Void = { TailcatServerPairing.remove(from: $0) },
        cameraAuthorizationStatus: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .video)
        },
        hasCamera: @escaping () -> Bool = { AVCaptureDevice.default(for: .video) != nil }
    ) {
        self.server = server
        self.attach = attach
        self.remove = remove
        self.cameraAuthorizationStatus = cameraAuthorizationStatus
        self.hasCamera = hasCamera
        refresh()
    }

    var showsError: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    var statusText: String {
        isPaired
            ? L10n.Settings.ConnectionSection.Tailcat.Status.paired
            : L10n.Settings.ConnectionSection.Tailcat.Status.notPaired
    }

    var canPairFromText: Bool {
        !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The camera may be used unless the user or a restriction said otherwise, or there is none.
    var scannerStatus: HAQRScannerStatus {
        switch cameraAuthorizationStatus() {
        case .denied, .restricted:
            return .unavailable(L10n.Settings.ConnectionSection.Tailcat.Scanner.unavailable)
        default:
            return hasCamera() ? .scanning : .unavailable(L10n.Settings.ConnectionSection.Tailcat.Scanner.unavailable)
        }
    }

    func refresh() {
        var connection = server.info.connection
        isPaired = connection.tailcat != nil
        _ = connection.evaluateActiveURL()
        activeURLType = connection.activeURLType
    }

    func pairFromText() {
        pair(with: linkText)
    }

    func pairFromScan(_ value: String) {
        isScanning = false
        pair(with: value)
    }

    func confirmRemoval() {
        isRemoveConfirmationPresented = true
    }

    func removePairing() {
        remove(server)
        refresh()
    }

    private func pair(with text: String) {
        do {
            let link = try TailcatPairingLink(string: text)
            attach(link.configuration, server)
            linkText = ""
            refresh()
            showsPairedConfirmation = true
        } catch {
            // Never log the link itself: it carries the tunnel's secrets.
            Current.Log.error("Rejected Tailcat pairing link: \(error)")
            errorMessage = error.localizedDescription
        }
    }
}
