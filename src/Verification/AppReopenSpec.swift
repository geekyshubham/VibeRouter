import AppKit
import Foundation
import Security
@testable import CLIProxyMenuBar

private final class ReopenDelegate: AppDelegate {
    var interfaceRequests = 0
    override func openSettings() { interfaceRequests += 1 }
}

@main
struct AppReopenSpec {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ReopenDelegate()
        precondition(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        precondition(delegate.interfaceRequests == 1, "opening a running menu-bar app must reveal its interface")
        precondition(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true))
        precondition(delegate.interfaceRequests == 2, "reopening must also raise an existing window")
        precondition(delegate.serverManager == nil, "reopening must not start a second proxy")

        let started = Date()
        let missing = NativeKeychain.read(service: "com.viberouter.verification.missing.\(UUID().uuidString)")
        precondition(missing.data == nil)
        precondition(missing.status != errSecSuccess)
        precondition(Date().timeIntervalSince(started) < 5, "background reads must not wait for a password dialog")
        let existingStarted = Date()
        _ = NativeKeychain.read(service: "Claude Code-credentials")
        precondition(Date().timeIntervalSince(existingStarted) < 1.5,
                     "an inaccessible native credential cannot block the app")
        for _ in 0..<10 { _ = NativeKeychain.read(service: "Claude Code-credentials") }
        precondition(Date().timeIntervalSince(existingStarted) < 6,
                     "overlapping requests cannot build a queue of password prompts")
        let keychainSource = try! String(contentsOfFile: "src/Sources/NativeKeychain.swift", encoding: .utf8)
        precondition(keychainSource.components(separatedBy: "context.interactionNotAllowed = true").count == 3,
                     "both reads and writes must disable authentication UI")
        precondition(!keychainSource.contains(".terminate()") && !keychainSource.contains("kill("),
                     "a Keychain helper that may be showing a dialog must never be killed")
        precondition(keychainSource.contains("pauseAfterRefusal"), "a refused Keychain helper must back off")
        for name in ["TokenRefreshService", "NativeSessionManager", "CodexWorkspaceCredentials", "AntigravityCLIToken"] {
            let source = try! String(contentsOfFile: "src/Sources/\(name).swift", encoding: .utf8)
            precondition(!source.contains("/usr/bin/security"), "credential paths must not spawn password-capable helper processes")
        }
        print("PASS: app reopen reveals its interface without duplicating the proxy; Keychain discovery returns without UI")
    }
}
