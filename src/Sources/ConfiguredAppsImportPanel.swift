import SwiftUI

struct ConfiguredAppsImportPanel: View {
    let authManager: AuthManager
    let serverManager: ServerManager
    let isImporting: Bool
    let onImport: (DiscoveredConfiguredAccount) -> Void
    let onImportAll: ([DiscoveredConfiguredAccount]) -> Void

    @State private var discoveredAccounts: [DiscoveredConfiguredAccount] = []

    @State private var discoveryTask: Task<Void, Never>?
    private var importableAccounts: [DiscoveredConfiguredAccount] { discoveredAccounts }

    var body: some View {
        // Discovery must run even when the list is empty — do not put onAppear
        // only inside the non-empty branch (that never mounts, so discovery never runs).
        Group {
            if !importableAccounts.isEmpty {
                Section("Configured on This Mac") {
                    Text("One-click import from apps already signed in on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(importableAccounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.body)
                                Text("\(providerCategoryLabel(for: account)) · from \(account.sourceAppName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import") {
                                onImport(account)
                            }
                            .controlSize(.small)
                            .disabled(isImporting)
                        }
                    }

                    if importableAccounts.count > 1 {
                        Button {
                            onImportAll(importableAccounts)
                        } label: {
                            Label(
                                "Import All (\(importableAccounts.count))",
                                systemImage: "square.and.arrow.down.on.square"
                            )
                        }
                        .disabled(isImporting)
                    }
                }
            }
        }
        .onChange(of: authManager.serviceAccounts) { _ in
            refreshDiscovery()
        }
        .onChange(of: serverManager.customProviderCredentials) { _ in
            refreshDiscovery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDirectoryChanged)) { _ in
            refreshDiscovery()
        }
        .task(id: "configured-apps-discovery") {
            refreshDiscovery()
        }
    }

    private func refreshDiscovery() {
        discoveryTask?.cancel()
        let accounts = authManager.serviceAccounts
        let keys = serverManager.activeZaiAPIKeys
        let credentials = serverManager.customProviderCredentials
        discoveryTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                ConfiguredAccountDiscovery.discoverAllImportable(
                    connectedAccounts: { accounts[$0]?.accounts ?? [] },
                    zaiAPIKeys: keys, customCredentials: credentials)
            }.value
            guard !Task.isCancelled else { return }
            discoveredAccounts = result
        }
    }

    private func providerCategoryLabel(for account: DiscoveredConfiguredAccount) -> String {
        if let customID = account.customProviderID {
            if customID == ProviderCatalog.openCodeGoProviderName {
                return ProviderCatalog.openCodeGoDisplayName
            }
            return CustomProviderDefinition.defaultTitle(for: customID)
        }
        return account.serviceType.displayName
    }
}
