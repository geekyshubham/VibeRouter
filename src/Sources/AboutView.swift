import SwiftUI
import AppKit

/// Product About panel — keyword-rich copy for support, App Store–style credibility,
/// and consistency with the GitHub About / README SEO description.
struct AboutView: View {
    var onClose: (() -> Void)?

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.tagline)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(Self.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    featureBullets

                    disclaimer

                    links
                }
                .padding(16)
            }
            Divider().opacity(0.25)
            HStack {
                Spacer()
                Button("Close") { onClose?() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 480)
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon
            VStack(alignment: .leading, spacing: 3) {
                Text("VibeRouter")
                    .font(.title2.weight(.bold))
                Text(version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("macOS menu bar · AI usage limits · local proxy")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let nsimage = NSApp.applicationIconImage {
            Image(nsImage: nsimage)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let glyph = IconCatalog.shared.image(named: "glyph.png", resizedTo: NSSize(width: 36, height: 36)) {
            // Stay on-brand even if the app icon is unavailable: the rocket glyph
            // on the accent chip, matching the web BrandMark and menu bar mark.
            Image(nsImage: glyph)
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [MenuBarDesign.accent, MenuBarDesign.accent.opacity(0.82)],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
        } else {
            Image(systemName: "network")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(MenuBarDesign.accent)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
        }
    }

    private var featureBullets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why VibeRouter")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            bullet("Live usage limits & reset countdowns (Codex, Claude Code, Gemini, Kiro, Copilot, more)")
            bullet("Local token/credit analytics and estimated API-equivalent $")
            bullet("Multi-account import, one-click account switch, proactive token refresh")
            bullet("Auto “wake 5h window” keep-alive for supported providers")
            bullet("Provider status & incidents · glass menu bar UX")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MenuBarDesign.accent)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Attribution")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Self.attribution)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 6) {
            linkRow(title: "GitHub · Releases", url: "https://github.com/Geekyshubham/vibeproxy-ultra/releases")
            linkRow(title: "Report an issue", url: "https://github.com/Geekyshubham/vibeproxy-ultra/issues")
            linkRow(title: "Source repository", url: "https://github.com/Geekyshubham/vibeproxy-ultra")
        }
    }

    @ViewBuilder
    private func linkRow(title: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                }
            }
            .foregroundStyle(MenuBarDesign.accent)
        }
    }

    // MARK: - Product copy

    static let tagline =
        "VibeRouter — macOS menu bar proxy with live AI usage limits, quotas, and analytics."

    static let summary =
        "Route Claude Code, ChatGPT/Codex, Gemini, Antigravity, GitHub Copilot, Kiro, Grok, Z.AI, OpenCode, and more through a local proxy — with live usage limits, credit/token analytics, account switching, and session keep-alive."

    static let attribution =
        "© 2026 Geekyshubham · VibeRouter · MIT License. Not affiliated with OpenAI, Anthropic, Google, xAI, GitHub, or any AI provider. Use at your own risk regarding provider terms of service."
}

// MARK: - Presenter

enum AboutWindowController {
    private static var window: NSWindow?

    static func show() {
        if let window, window.isVisible {
            window.bringToFront()
            return
        }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About VibeRouter"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: AboutView {
            panel.close()
        })
        panel.bringToFront()
        window = panel
    }
}
