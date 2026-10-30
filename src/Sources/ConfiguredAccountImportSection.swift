import SwiftUI

struct ConfiguredAccountImportSection: View {
    let serviceType: ServiceType
    let connectedAccounts: [AuthAccount]
    let zaiAPIKeys: [String]
    let customCredentials: [String: [CustomProviderCredential]]
    let isImporting: Bool
    let onImport: (DiscoveredConfiguredAccount) -> Void

    @State private var discoveredAccounts: [DiscoveredConfiguredAccount] = []

    @State private var discoveryTask: Task<Void, Never>?
    private var importableAccounts: [DiscoveredConfiguredAccount] { discoveredAccounts }

    var body: some View {
        // Always mount a container so discovery onAppear/task actually runs for every provider.
        VStack(alignment: .leading, spacing: 6) {
            if !importableAccounts.isEmpty {
                Text("Import from apps already signed in on this Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(importableAccounts) { account in
                    Button {
                        onImport(account)
                    } label: {
                        Label(
                            "Import \(account.displayName) from \(account.sourceAppName)",
                            systemImage: "square.and.arrow.down"
                        )
                        .font(.caption)
                    }
                    .controlSize(.small)
                    .disabled(isImporting)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, importableAccounts.isEmpty ? 0 : 28)
        // Zero-size when empty still participates in the view tree for lifecycle.
        .frame(minHeight: importableAccounts.isEmpty ? 0.5 : nil)
        .onChange(of: connectedAccounts) { _ in
            refreshDiscovery()
        }
        .onChange(of: zaiAPIKeys) { _ in
            refreshDiscovery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDirectoryChanged)) { _ in
            refreshDiscovery()
        }
        .task(id: "\(serviceType.rawValue)-import-discovery") {
            refreshDiscovery()
        }
    }

    private func refreshDiscovery() {
        discoveryTask?.cancel()
        let type = serviceType
        let accounts = connectedAccounts
        let keys = zaiAPIKeys
        let credentials = customCredentials
        discoveryTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                ConfiguredAccountDiscovery.discover(for: type).filter {
                    !ConfiguredAccountDiscovery.isAlreadyConnected($0,
                        existingAccounts: accounts, zaiAPIKeys: keys, customCredentials: credentials)
                }
            }.value
            guard !Task.isCancelled else { return }
            discoveredAccounts = result
        }
    }

}
