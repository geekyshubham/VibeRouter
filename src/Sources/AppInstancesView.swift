import SwiftUI

struct AppInstancesView: View {
    @ObservedObject var authManager: AuthManager
    var usageStore: UsageStore? = nil

    @State private var instances: [ManagedAppInstance] = []
    @State private var runningIDs: Set<String> = []
    @State private var creatingProvider: ServiceType = .cursor
    @State private var creatingName = ""
    @State private var creatingAccountID: String? = nil
    @State private var creatingSurface: ManagedAppInstance.Surface = .app
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var launchingID: String?
    @State private var deleteTargetID: String?
    @State private var renamingID: String?
    @State private var renameText = ""

    private var runningCount: Int { runningIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            howToCard
            newInstanceCard

            HStack(spacing: 8) {
                Text("Instances")
                    .font(.headline)
                if instances.isEmpty {
                    Text("none yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(instances.count) total\(runningCount > 0 ? " · \(runningCount) running" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Refresh") { reload() }
                    .controlSize(.small)
                    .help("Re-read saved instances and running state")
            }
            .padding(.horizontal, 4)

            if instances.isEmpty {
                emptyCard
            } else {
                ForEach(instances) { instance in
                    instanceCard(instance)
                }
            }

            if let statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? MenuBarDesign.danger : MenuBarDesign.success)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? MenuBarDesign.danger : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background((statusIsError ? MenuBarDesign.danger : MenuBarDesign.success).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(4)
        .onAppear(perform: reload)
    }

    // MARK: - How to use

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(MenuBarDesign.accent)
                Text("How instances work")
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("1 · Pick an app, where it runs (app window or CLI in Terminal) and a name, optionally bind one VibeRouter account, then Create.")
                Text("2 · Start launches a separate copy with its own folder — login, chats and settings stay apart from the main app and every other copy.")
                Text("3 · Each account can be signed in to one copy at a time. VibeRouter keeps the copy's login and its own account file in step, so neither expires.")
                Text("4 · Stop quits that copy. Reveal opens its folder. Duplicate makes an unbound copy for another account.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Tip: bind each Antigravity copy to a different account to run your 10-account fill-first pool side by side. Re-bind to the next healthy account when one hits its limit.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - New instance

    private var newInstanceCard: some View {
        let tint = MenuBarDesign.providerTint(for: creatingProvider)
        return VStack(alignment: .leading, spacing: 8) {
            Text("New instance")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Picker("App", selection: $creatingProvider) {
                    ForEach(AppInstanceManager.launchableProviders, id: \.rawValue) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 190)
                .onChange(of: creatingProvider) { provider in
                    creatingAccountID = nil
                    creatingSurface = AppInstanceManager.surfaces(for: provider)[0]
                }
            }
            if AppInstanceManager.surfaces(for: creatingProvider).count > 1 {
                Picker("Runs as", selection: $creatingSurface) {
                    ForEach(AppInstanceManager.surfaces(for: creatingProvider), id: \.self) { surface in
                        Text(AppInstanceManager.surfaceLabel(surface, type: creatingProvider)).tag(surface)
                    }
                }
                .pickerStyle(.segmented)
            }
            TextField("Name (e.g. Antigravity A1)", text: $creatingName)
                .textFieldStyle(.roundedBorder)
            if creatingAcceptsAccount {
                Picker("Bound account (optional)", selection: $creatingAccountID) {
                    Text("None — manual sign-in").tag(Optional<String>.none)
                    ForEach(accounts(for: creatingProvider), id: \.id) { account in
                        Text(boundLabel(account)).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.menu)
                .help("Sign this VibeRouter account in to the isolated copy on Start")
            } else {
                Text("The Claude desktop app signs in with claude.ai in its own window. To run a VibeRouter Claude account, choose Claude Code in Terminal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Create instance") {
                    let name = creatingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = name.isEmpty ? "\(creatingProvider.displayName) \(instances.count + 1)" : name
                    var instance = ManagedAppInstance.make(name: label, provider: creatingProvider)
                    instance.surface = creatingSurface.rawValue
                    instance.boundAccountFile = creatingAcceptsAccount ? creatingAccountID : nil
                    AppInstanceManager.upsert(instance)
                    creatingName = ""
                    creatingAccountID = nil
                    statusIsError = false
                    statusMessage = "Created \(label) — press Start to launch it."
                    reload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(tint)
                .disabled(!AppInstanceManager.launchableProviders.contains(creatingProvider))
            }
        }
        .padding(12)
        .cardSurface(tint: tint)
    }

    private var creatingAcceptsAccount: Bool {
        var probe = ManagedAppInstance.make(name: "", provider: creatingProvider)
        probe.surface = creatingSurface.rawValue
        return AppInstanceManager.acceptsBoundAccount(probe)
    }

    // MARK: - Instance cards

    private var emptyCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.square.dashed")
                .foregroundStyle(.secondary)
            Text("No instances yet — create one above to run isolated copies side by side.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func instanceCard(_ instance: ManagedAppInstance) -> some View {
        let tint = instance.serviceType.map(MenuBarDesign.providerTint) ?? .secondary
        let running = runningIDs.contains(instance.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(running ? MenuBarDesign.success : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .help(running ? "Running" : "Stopped")
                if renamingID == instance.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button("Save") {
                        var updated = instance
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { updated.name = trimmed }
                        AppInstanceManager.upsert(updated)
                        renamingID = nil
                        reload()
                    }
                    .controlSize(.small)
                    Button("Cancel", role: .cancel) { renamingID = nil }
                        .controlSize(.small)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(instance.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text("\(instance.serviceType.map { AppInstanceManager.surfaceLabel(AppInstanceManager.surface(of: instance), type: $0) } ?? instance.provider) · \(running ? "running" : "stopped")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        renamingID = instance.id
                        renameText = instance.name
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rename instance")
                }
            }

            if AppInstanceManager.acceptsBoundAccount(instance) {
                HStack(spacing: 6) {
                    Text("Account")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: boundAccountBinding(instance)) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(accounts(for: instance), id: \.id) { account in
                            Text(boundLabel(account)).tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    if let badge = boundQuotaBadge(instance) {
                        Text(badge)
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.secondary)
                            .help("Peak quota usage on the bound account")
                    }
                    Spacer(minLength: 0)
                }
                .help(running ? "Takes effect on the next Start" : "Signed in to this copy on Start")
            } else {
                Text("Signs in with claude.ai inside its own window")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(instance.userDataDir)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(instance.userDataDir)

            HStack(spacing: 6) {
                if launchingID == instance.id {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption2).foregroundStyle(.secondary)
                } else if running {
                    Button("Stop") { apply(AppInstanceManager.stop(instance)); reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if let type = instance.serviceType, !AppInstanceManager.isAppInstalled(for: instance) {
                    Text(AppInstanceManager.surface(of: instance) == .terminal
                         ? "\(AppInstanceManager.cliName(for: type)) command not found — install it to Start"
                         : "\(type.displayName) app not found — install it in /Applications to Start")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Start") { Task { await launch(instance) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(tint)
                }
                Button("Reveal") { AppInstanceManager.revealInFinder(instance) }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Open this instance's data folder in Finder")
                Button("Duplicate") {
                    let copy = AppInstanceManager.duplicate(instance)
                    statusIsError = false
                    statusMessage = "Duplicated as \(copy.name) — bind another account to run two copies side by side."
                    reload()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if deleteTargetID == instance.id {
                    Button("Confirm", role: .destructive) {
                        AppInstanceManager.delete(instance)
                        deleteTargetID = nil
                        reload()
                    }
                    .controlSize(.small)
                    Button("Keep", role: .cancel) { deleteTargetID = nil }
                        .controlSize(.small)
                } else {
                    Button("Delete", role: .destructive) { deleteTargetID = instance.id }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .cardSurface(tint: tint)
    }

    // MARK: - Helpers

    private func boundAccountBinding(_ instance: ManagedAppInstance) -> Binding<String?> {
        Binding(
            get: { instance.boundAccountFile },
            set: { newValue in
                var updated = instance
                updated.boundAccountFile = newValue
                AppInstanceManager.upsert(updated)
                reload()
            }
        )
    }

    private func accounts(for provider: ServiceType) -> [AuthAccount] {
        authManager.accounts(for: provider)
            .sorted { $0.baseDisplayName.localizedCaseInsensitiveCompare($1.baseDisplayName) == .orderedAscending }
    }

    private func accounts(for instance: ManagedAppInstance) -> [AuthAccount] {
        guard let type = instance.serviceType else { return [] }
        return accounts(for: type)
    }

    private func boundAccount(for instance: ManagedAppInstance) -> AuthAccount? {
        guard let file = instance.boundAccountFile, !file.isEmpty else { return nil }
        return accounts(for: instance).first { $0.id == file }
    }

    private func boundLabel(_ account: AuthAccount) -> String {
        if let peak = peakUsed(account) {
            return "\(account.baseDisplayName) · \(Int(peak.rounded()))%"
        }
        return account.baseDisplayName
    }

    private func peakUsed(_ account: AuthAccount) -> Double? {
        usageStore?.snapshot(for: account)?.headlineUsedPercent()
    }

    private func boundQuotaBadge(_ instance: ManagedAppInstance) -> String? {
        guard let account = boundAccount(for: instance),
              let peak = peakUsed(account)
        else { return nil }
        return "\(Int(peak.rounded()))% used"
    }

    private func launch(_ instance: ManagedAppInstance) async {
        launchingID = instance.id
        let result = await AppInstanceManager.launch(instance)
        launchingID = nil
        apply(result)
        reload()
    }

    private func apply(_ result: AppInstanceLaunchResult) {
        switch result {
        case .launched(let message):
            statusIsError = false
            statusMessage = message
        case .failure(let message):
            statusIsError = true
            statusMessage = message
        }
    }

    private func reload() {
        instances = AppInstanceManager.load()
        runningIDs = Set(instances.filter(AppInstanceManager.isRunning).map(\.id))
        if let target = deleteTargetID, !instances.contains(where: { $0.id == target }) {
            deleteTargetID = nil
        }
    }
}
