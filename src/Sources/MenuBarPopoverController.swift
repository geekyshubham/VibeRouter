import AppKit
import SwiftUI

final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private weak var statusItem: NSStatusItem?

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private let serverManager: ServerManager
    private let authManager: AuthManager
    private let usageStore: UsageStore
    private let thinkingProxy: ThinkingProxy
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(
        serverManager: ServerManager,
        authManager: AuthManager,
        usageStore: UsageStore,
        thinkingProxy: ThinkingProxy,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.serverManager = serverManager
        self.authManager = authManager
        self.usageStore = usageStore
        self.thinkingProxy = thinkingProxy
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init()

        // Semitransient keeps the panel open while interacting with buttons (Wake, tabs).
        // Transient often swallows the first click and closes before the action runs.
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
    }

    func attach(to statusItem: NSStatusItem) {
        self.statusItem = statusItem
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            showPopover()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)

        // Determine the popover height EXPLICITLY (not content-driven). An NSPopover
        // otherwise grows to fit its SwiftUI content and, with many providers, runs
        // off the top of the screen. We compute a height that fits below the menu bar
        // and above the Dock (reserving room for the popover arrow), then force it via
        // `contentSize` + `sizingOptions = []` so the ScrollView scrolls inside a
        // fixed frame instead of expanding the window.
        let screen = button.window?.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 800
        let panelHeight = max(400, min(visibleHeight - 56, 820))

        let panelView = MenuBarPanelView(
            serverManager: serverManager,
            authManager: authManager,
            usageStore: usageStore,
            proxyPort: Int(thinkingProxy.proxyPort),
            panelHeight: panelHeight,
            onOpenSettings: { [weak self] in
                self?.closePopover()
                self?.onOpenSettings()
            },
            onToggleServer: { [weak self] in
                self?.toggleServer()
            },
            onCopyURL: { [weak self] in
                self?.copyServerURL()
            },
            onOpenDashboard: { [weak self] in
                self?.openDashboard()
            },
            onQuit: { [weak self] in
                self?.closePopover()
                self?.onQuit()
            }
        )

        let hosting = NSHostingController(rootView: panelView)
        // Stop the hosting controller from resizing the popover to fit content.
        hosting.sizingOptions = []
        let size = NSSize(width: MenuBarDesign.panelWidth, height: panelHeight)
        hosting.preferredContentSize = size
        popover.contentViewController = hosting
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitors()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopoverIfClickIsOutside()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopoverIfClickIsOutside()
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func closePopoverIfClickIsOutside() {
        guard popover.isShown else { return }
        guard let popoverWindow = popover.contentViewController?.view.window else {
            closePopover()
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if popoverWindow.frame.contains(mouseLocation) {
            return
        }

        if let statusButton = statusItem?.button,
           let statusWindow = statusButton.window
        {
            let buttonFrame = statusButton.convert(statusButton.bounds, to: nil)
            let screenButtonFrame = statusWindow.convertToScreen(buttonFrame)
            if screenButtonFrame.contains(mouseLocation) {
                return
            }
        }

        closePopover()
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: serverManager.isRunning ? "Stop Server" : "Start Server", action: #selector(toggleServerAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Settings", action: #selector(openSettingsAction), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Server URL", action: #selector(copyURLAction), keyEquivalent: "")
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboardAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit VibeRouter", action: #selector(quitAction), keyEquivalent: "q")

        for item in menu.items {
            item.target = self
            if item.title == "Copy Server URL" || item.title == "Open Dashboard" {
                item.isEnabled = serverManager.isRunning
            }
        }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleServerAction() { toggleServer() }
    @objc private func openSettingsAction() { onOpenSettings() }
    @objc private func copyURLAction() { copyServerURL() }
    @objc private func openDashboardAction() { openDashboard() }
    @objc private func quitAction() { onQuit() }

    private func toggleServer() {
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        } else {
            thinkingProxy.start()
            serverManager.start { _ in }
        }
    }

    private func copyServerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://localhost:\(thinkingProxy.proxyPort)", forType: .string)
    }

    private func openDashboard() {
        // Management key for /management.html login (empty key disables the API with 404).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ManagementCredentials.secretKey, forType: .string)
        NSWorkspace.shared.open(ManagementCredentials.managementHTMLURL)
    }
}
