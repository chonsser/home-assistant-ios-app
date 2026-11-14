import HADesignSystem
import Shared
import SwiftUI

/// Pairs a server with a Tailcat tunnel, shows the pairing state, and removes it.
struct TailcatSettingsView: View {
    @StateObject private var viewModel: TailcatSettingsViewModel

    init(viewModel: @autoclosure @escaping () -> TailcatSettingsViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(L10n.Settings.ConnectionSection.Tailcat.Status.title)
                    Spacer()
                    Text(viewModel.statusText)
                        .foregroundStyle(.secondary)
                }
                if viewModel.isPaired {
                    HStack {
                        Text(L10n.Settings.ConnectionSection.Tailcat.ActiveUrl.title)
                        Spacer()
                        Text(viewModel.activeURLType.description)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text(L10n.Settings.ConnectionSection.Tailcat.footer)
            }

            Section {
                TextField(L10n.Settings.ConnectionSection.Tailcat.Pair.linkPlaceholder, text: $viewModel.linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .privacySensitive()
                    .onSubmit(viewModel.pairFromText)
                Button(L10n.Settings.ConnectionSection.Tailcat.Pair.button, action: viewModel.pairFromText)
                    .disabled(!viewModel.canPairFromText)
                Button {
                    viewModel.isScanning = true
                } label: {
                    Label(L10n.Settings.ConnectionSection.Tailcat.Pair.scan, systemSymbol: .qrcodeViewfinder)
                }
            } header: {
                Text(L10n.Settings.ConnectionSection.Tailcat.Pair.header)
            } footer: {
                if viewModel.isPaired {
                    Text(L10n.Settings.ConnectionSection.Tailcat.Pair.repairFooter)
                }
            }

            if viewModel.isPaired {
                Section {
                    Button(role: .destructive, action: viewModel.confirmRemoval) {
                        Text(L10n.Settings.ConnectionSection.Tailcat.Remove.title)
                    }
                    .confirmationDialog(
                        L10n.Settings.ConnectionSection.Tailcat.Remove.title,
                        isPresented: $viewModel.isRemoveConfirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button(
                            L10n.Settings.ConnectionSection.Tailcat.Remove.title,
                            role: .destructive,
                            action: viewModel.removePairing
                        )
                        Button(L10n.cancelLabel, role: .cancel) {}
                    } message: {
                        Text(L10n.Settings.ConnectionSection.Tailcat.Remove.message)
                    }
                }
            }
        }
        .navigationTitle(L10n.Settings.ConnectionSection.Tailcat.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: viewModel.refresh)
        .sheet(isPresented: $viewModel.isScanning) {
            NavigationStack {
                ScrollView {
                    HAQRScanner(
                        status: viewModel.scannerStatus,
                        description: L10n.Settings.ConnectionSection.Tailcat.Scanner.title,
                        onScan: viewModel.pairFromScan
                    )
                    .frame(maxWidth: .infinity)
                    .padding(DesignSystem.Spaces.two)
                }
                .navigationTitle(L10n.Settings.ConnectionSection.Tailcat.Pair.scan)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        CloseButton {
                            viewModel.isScanning = false
                        }
                    }
                }
            }
        }
        .alert(
            L10n.Tailcat.Pairing.Error.title,
            isPresented: $viewModel.showsError
        ) {
            Button(L10n.okLabel, role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            L10n.Settings.ConnectionSection.Tailcat.title,
            isPresented: $viewModel.showsPairedConfirmation
        ) {
            Button(L10n.okLabel, role: .cancel) {}
        } message: {
            Text(L10n.Settings.ConnectionSection.Tailcat.Pair.success)
        }
    }
}

#Preview {
    NavigationStack {
        TailcatSettingsView(viewModel: TailcatSettingsViewModel(server: ServerFixture.standard))
    }
}
