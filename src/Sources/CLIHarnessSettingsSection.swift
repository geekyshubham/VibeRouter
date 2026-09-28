import SwiftUI

/// Settings section: detect installed coding CLIs and one-click Autoconfigure to VibeRouter.
struct CLIHarnessSettingsSection: View {
    var proxyPort: Int = 8317

    @State private var harnesses: [CLIHarness] = []
    @State private var message: String?
    @State private var ok: Bool?
    @State private var working = false

    var body: some View {
        Section {
            ForEach(harnesses.filter(\.isInstalled)) { harness in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: harness.kind.systemImage)
                        .foregroundStyle(MenuBarDesign.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(harness.kind.displayName)
                            .font(.body.weight(.medium))
                        Text(harness.isConfigured ? "Pointing at VibeRouter" : harness.kind.notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if harness.kind.supportsAutoconfigure {
                        Button(harness.isConfigured ? "Update" : "Autoconfigure") {
                            configure(harness.kind)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(working)
                    } else {
                        Text(harness.isConfigured ? "OK" : "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if harnesses.filter(\.isInstalled).isEmpty {
                Text("No coding CLIs detected (Claude Code, Codex, OpenCode, Gemini, …)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Rescan") {
                    harnesses = CLIHarnessAutoconfigure.discover(proxyPort: proxyPort)
                }
                .disabled(working)

                Spacer()

                Button {
                    configureAll()
                } label: {
                    if working {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Autoconfigure all")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || harnesses.filter { $0.isInstalled && $0.kind.supportsAutoconfigure }.isEmpty)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(ok == true ? MenuBarDesign.success : .orange)
                    .textSelection(.enabled)
            }
        } header: {
            Text("CLI tools → proxy")
        } footer: {
            Text("Writes proxy config into each tool (Claude Code: settings.viberouter.json + claude-viberouter, with separate session settings so `claude` keeps your subscription). Backup: *.viberouter-bak.")
                .font(.caption2)
        }
        .onAppear {
            harnesses = CLIHarnessAutoconfigure.discover(proxyPort: proxyPort)
        }
    }

    private func configure(_ kind: CLIHarness.Kind) {
        working = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try CLIHarnessAutoconfigure.autoconfigure(kind, proxyPort: proxyPort)
                DispatchQueue.main.async {
                    working = false
                    ok = true
                    message = "✓ \(msg)"
                    harnesses = CLIHarnessAutoconfigure.discover(proxyPort: proxyPort)
                }
            } catch {
                DispatchQueue.main.async {
                    working = false
                    ok = false
                    message = error.localizedDescription
                }
            }
        }
    }

    private func configureAll() {
        working = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CLIHarnessAutoconfigure.autoconfigureAll(proxyPort: proxyPort)
            DispatchQueue.main.async {
                working = false
                ok = result.failed.isEmpty
                if result.ok.isEmpty {
                    message = result.failed.joined(separator: "\n")
                } else {
                    message = result.ok.map { "✓ \($0)" }.joined(separator: "\n")
                    if !result.failed.isEmpty {
                        message = (message ?? "") + "\n" + result.failed.joined(separator: "\n")
                    }
                }
                harnesses = CLIHarnessAutoconfigure.discover(proxyPort: proxyPort)
            }
        }
    }
}
