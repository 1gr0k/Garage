import SwiftUI

struct SyncSettingsView: View {
    @Environment(SyncViewModel.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingForget = false
    @State private var serverText = ""
    /// Lives only here, in memory, until registration; never stored or passed on.
    @State private var secret = ""

    var body: some View {
        Form {
            serverSection
            syncSection
        }
        .navigationTitle("Synchronization")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
                    .accessibilityIdentifier(AccessibilityID.SyncSettings.close)
            }
        }
        .task {
            if serverText.isEmpty { serverText = sync.serverURL?.absoluteString ?? "" }
            await sync.refresh()
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Server address", text: $serverText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(sync.isRegistered)
            if sync.isRegistered {
                Label("Device registered", systemImage: "checkmark.circle")
                Button("Forget Device", role: .destructive) { isConfirmingForget = true }
                    .confirmationDialog(
                        "Forget this device?", isPresented: $isConfirmingForget, titleVisibility: .visible
                    ) {
                        Button("Forget Device", role: .destructive) {
                            Task { await sync.forgetDevice() }
                        }
                    } message: {
                        Text("Synchronization will stop and its state will be reset. Data on this device stays.")
                    }
            } else {
                SecureField("Setup secret", text: $secret)
                Button {
                    Task { await register() }
                } label: {
                    HStack {
                        Text("Register Device")
                        if sync.isRegistering { ProgressView() }
                    }
                }
                .disabled(serverText.isEmpty || secret.isEmpty || sync.isRegistering)
            }
        }
    }

    private var syncSection: some View {
        Section("Synchronization") {
            Button {
                sync.startSync()
            } label: {
                HStack {
                    Text("Sync Now")
                    if sync.isSyncing { ProgressView() }
                }
            }
            .disabled(!sync.isRegistered || sync.isSyncing || sync.isForgetting)
            if let lastSyncAt = sync.lastSyncAt {
                Text("Last sync: \(lastSyncAt.formatted(.relative(presentation: .named)))")
            } else {
                Text("Not synced yet")
            }
            Text("\(sync.pendingCount) changes waiting")
            if sync.receiptFailureCount > 0 {
                Text("\(sync.receiptFailureCount) receipts not transferred")
            }
            if let error = sync.lastError {
                Text(verbatim: error).foregroundStyle(.red)
            }
        }
    }

    private func register() async {
        if await sync.register(serverURL: serverText, secret: secret) { secret = "" }
    }
}
