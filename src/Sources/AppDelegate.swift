import Cocoa
import SwiftUI
import WebKit
import UserNotifications
import Sparkle
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    /// Strong retention while open. Cleared in `windowWillClose` (not the non-existent `windowDidClose`).
    var settingsWindow: NSWindow?
    var serverManager: ServerManager!
    var thinkingProxy: ThinkingProxy!
    let authManager = AuthManager()
    let usageStore = UsageStore()
    let appSettings = AppSettings.shared
    let nativeSession = NativeSessionManager.shared
    private var wakeScheduler: QuotaWakeScheduler!
    private var settingsCancellables = Set<AnyCancellable>()
    private var popoverController: MenuBarPopoverController!
    private lazy var notificationCenter: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    private var notificationPermissionGranted = false
    private let updaterController: SPUStandardUpdaterController
    private var authFileMonitor: DispatchSourceFileSystemObject?
    private var userConfigFileMonitor: DispatchSourceFileSystemObject?
    private var configInputPoller: DispatchSourceTimer?
    private var pendingAuthRefresh: DispatchWorkItem?
    private var polledConfigInputsFingerprint = ""
    private var isStartingServer = false
    private var serverStartGeneration = 0
    
    override init() {
        // Sparkle auto-checks disabled (no feed configured for VibeRouter).
        self.updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    /// Agent apps don't activate an existing instance. A second copy is the usual
    /// "I clicked the app and it crashed" report: duplicate status item, bind fail, quit.
    private static func exitIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard let existing = others.first else { return false }
        NSLog("[VibeRouter] Already running (pid %d); exiting this instance", existing.processIdentifier)
        NSApp.terminate(nil)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement has no Dock icon, so clicking VibeRouter.app starts a second copy
        // that fights for the status item and port 8317 — looks like a crash.
        if Self.exitIfAlreadyRunning() { return }

        // Setup standard Edit menu for keyboard shortcuts (Cmd+C/V/X/A)
        setupMainMenu()

        // Initialize managers
        serverManager = ServerManager()
        thinkingProxy = ThinkingProxy()

        // Sync Vercel AI Gateway config from ServerManager to ThinkingProxy
        syncVercelConfig()
        serverManager.onVercelConfigChanged = { [weak self] in
            self?.syncVercelConfig()
        }

        popoverController = MenuBarPopoverController(
            serverManager: serverManager,
            authManager: authManager,
            usageStore: usageStore,
            thinkingProxy: thinkingProxy,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quit() }
        )

        // Setup menu bar popover
        setupMenuBar()
        usageStore.configure { [weak self] in
            self?.authManager.serviceAccounts.mapValues { $0.accounts } ?? [:]
        }
        usageStore.nativeSession = nativeSession
        authManager.checkAuthStatus()
        usageStore.clearCachedUsage()
        // Load cached model prices immediately and refresh the live feed (models.dev) in the
        // background, so cost estimates track real pricing rather than a frozen table.
        RemotePricingCatalog.bootstrap()
        // Load persisted per-day usage before the first scan, so the date pickers can show
        // history immediately instead of looking empty until a scan lands.
        UsageDailyStore.bootstrap(historyDays: AppSettings.shared.analyticsHistoryDays)
        usageStore.refreshDailySummary()
        usageStore.startAutoRefresh()
        // Keep OAuth access tokens fresh (refresh ~15 minutes before expiry).
        TokenRefreshService.startAutoRefresh()

        setupSessionAndScheduler()
        
        // Warm commonly used icons to avoid first-use disk hits
        preloadIcons()
        
        configureNotifications()

        // Start server automatically
        startServer()

        // Register for notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarStatus),
            name: .serverStatusChanged,
            object: nil
        )

        // Monitor auth directory for credential file changes (app-lifetime scope)
        startMonitoringAuthDirectory()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthDirectoryChanged),
            name: .authDirectoryChanged,
            object: nil
        )
        registerCLICommands()
    }

    /// Allow the separately invoked `viberouter` command to control the already-running
    /// menu-bar process without opening a second app instance or exposing a network port.
    private func registerCLICommands() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(handleCLIServerStart), name: VibeRouterDistributedCommand.serverStart, object: nil)
        center.addObserver(self, selector: #selector(handleCLIServerStop), name: VibeRouterDistributedCommand.serverStop, object: nil)
        center.addObserver(self, selector: #selector(handleCLIServerRestart), name: VibeRouterDistributedCommand.serverRestart, object: nil)
        center.addObserver(self, selector: #selector(handleCLIProviderState(_:)), name: VibeRouterDistributedCommand.providerState, object: nil)
        center.addObserver(self, selector: #selector(handleCLISettingsChanged), name: VibeRouterDistributedCommand.settingsChanged, object: nil)
    }

    @objc private func handleCLIServerStart() {
        if !serverManager.isRunning { startServer() }
    }

    @objc private func handleCLIServerStop() {
        stopServer()
    }

    @objc private func handleCLIServerRestart() {
        isStartingServer = false
        serverStartGeneration += 1
        thinkingProxy.stop()
        serverManager.stop { [weak self] in self?.startServer() }
    }

    @objc private func handleCLIProviderState(_ note: Notification) {
        guard let provider = note.userInfo?["provider"] as? String,
              let enabled = note.userInfo?["enabled"] as? Bool
        else { return }
        serverManager.setProviderEnabled(provider, enabled: enabled)
    }

    @objc private func handleCLISettingsChanged() {
        // Settings were persisted by the CLI. UserDefaults notifications do not cross
        // process boundaries, so rebuild the schedules/config that depend on them.
        usageStore.applyRefreshSettings()
        serverManager.handleObservedConfigInputsChanged()
    }
    
    private func setupSessionAndScheduler() {
        // Detect which account is currently live in each native tool (Codex/Claude/Gemini).
        nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })

        // Automatic "wake 5h window" keep-alive scheduler.
        wakeScheduler = QuotaWakeScheduler(settings: appSettings)
        wakeScheduler.configure(
            usageStore: usageStore,
            accountsProvider: { [weak self] in
                self?.authManager.serviceAccounts.mapValues { $0.accounts } ?? [:]
            },
            proxyPortProvider: { [weak self] in
                Int(self?.thinkingProxy.proxyPort ?? 8317)
            }
        )
        if appSettings.autoWakeEnabled {
            wakeScheduler.start()
        }

        // React to settings changes live.
        appSettings.$autoWakeEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.wakeScheduler.start() } else { self.wakeScheduler.stop() }
            }
            .store(in: &settingsCancellables)

        Publishers.Merge(
            appSettings.$usageRefreshMinutes.map { _ in () },
            appSettings.$statusRefreshMinutes.map { _ in () }
        )
        .dropFirst()
        .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.usageStore.applyRefreshSettings()
        }
        .store(in: &settingsCancellables)

        // Live menu-bar usage badge (peak quota %) — coalesced to avoid churn.
        usageStore.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.updateMenuBarBadge() }
            .store(in: &settingsCancellables)
        appSettings.$menuBarUsageBadge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarBadge() }
            .store(in: &settingsCancellables)
    }

    /// Peak quota usage across all live accounts (for the optional menu-bar badge).
    private func worstUsedPercent() -> Double {
        var worst = 0.0
        for (_, snapshot) in usageStore.usageByAccountID {
            worst = max(worst, snapshot.headlineUsedPercent() ?? 0)
        }
        return worst
    }

    private func updateMenuBarBadge() {
        guard let button = statusItem?.button else { return }
        guard appSettings.menuBarUsageBadge else {
            if !button.title.isEmpty || button.attributedTitle.length > 0 {
                button.attributedTitle = NSAttributedString(string: "")
                button.title = ""
            }
            button.imagePosition = .imageOnly
            return
        }

        let worst = worstUsedPercent()
        guard worst > 0 else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            return
        }

        let color: NSColor
        let remaining = 100 - worst
        if remaining > 50 { color = .systemGreen }
        else if remaining > 20 { color = .systemOrange }
        else { color = .systemRed }

        let title = " \(Int(worst.rounded()))%"
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            ]
        )
        button.imagePosition = .imageLeft
    }

    private func preloadIcons() {        let statusIconSize = NSSize(width: 18, height: 18)
        let serviceIconSize = NSSize(width: 20, height: 20)
        
        let iconsToPreload = [
            ("icon-active.png", statusIconSize),
            ("icon-inactive.png", statusIconSize),
            ("icon-codex.png", serviceIconSize),
            ("icon-claude.png", serviceIconSize),
            ("icon-gemini.png", serviceIconSize),
            ("icon-grok.png", serviceIconSize),
            ("icon-kiro.png", serviceIconSize)
        ]
        
        for (name, size) in iconsToPreload {
            if IconCatalog.shared.image(named: name, resizedTo: size, template: true) == nil {
                NSLog("[IconPreload] Warning: Failed to preload icon '%@'", name)
            }
        }
    }
    
    private func configureNotifications() {
        notificationCenter?.delegate = self
        notificationCenter?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                NSLog("[Notifications] Authorization failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                self?.notificationPermissionGranted = granted
                if !granted {
                    NSLog("[Notifications] Authorization not granted; notifications will be suppressed")
                }
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About VibeRouter", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit VibeRouter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // Edit menu (for Cmd+C/V/X/A to work)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApplication.shared.mainMenu = mainMenu
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = "VibeRouter — click for accounts & usage"
            if let icon = IconCatalog.shared.image(named: "icon-inactive.png", resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
            } else {
                let fallback = NSImage(systemSymbolName: "network.slash", accessibilityDescription: "VibeRouter")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load inactive icon from bundle; using fallback system icon")
            }
        }

        popoverController.attach(to: statusItem)
    }



    @objc func showAbout() {
        AboutWindowController.show()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.bringToFront()
    }

    func createSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeRouter"
        window.setContentSize(NSSize(width: 640, height: 720))
        window.minSize = NSSize(width: 560, height: 560)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = SettingsView(
            serverManager: serverManager,
            authManager: authManager,
            usageStore: usageStore
        )
        window.contentView = NSHostingView(rootView: contentView)

        settingsWindow = window
    }
    
    /// Correct NSWindowDelegate hook — `windowDidClose` is not a real delegate method
    /// (compiler warns it nearly matches `windowDidExpose`), so closed windows were never
    /// cleared. Combined with auth/config observers that called `makeKeyAndOrderFront`, that
    /// made Settings reappear on top of other apps after token/config file churn.
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }

    @objc func toggleServer() {
        if serverManager.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func startServer() {
        // The app autostarts, and a CLI start can arrive while its listeners
        // are still coming up. Share that startup instead of binding twice.
        guard !isStartingServer, !serverManager.isRunning else { return }
        isStartingServer = true
        serverStartGeneration += 1
        // Start the thinking proxy first (port 8317)
        thinkingProxy.start()
        
        // Poll for thinking proxy readiness with timeout
        pollForProxyReadiness(attempts: 0, maxAttempts: 60, intervalMs: 50, generation: serverStartGeneration)
    }
    
    private func pollForProxyReadiness(attempts: Int, maxAttempts: Int, intervalMs: Int, generation: Int) {
        guard isStartingServer, generation == serverStartGeneration else { return }
        // Check if proxy is running
        if thinkingProxy.isRunning {
            // Success - proceed to start backend
            serverManager.start { [weak self] success in
                DispatchQueue.main.async {
                    guard let self, generation == self.serverStartGeneration else { return }
                    self.isStartingServer = false
                    if success {
                        self.updateMenuBarStatus()
                        // User always connects to 8317 (thinking proxy)
                        self.showNotification(title: "Server Started", body: "VibeRouter is now running")
                    } else {
                        // Backend failed - stop the proxy to keep state consistent
                        self.thinkingProxy.stop()
                        self.showNotification(title: "Server Failed", body: "Could not start backend server on port 8318")
                    }
                }
            }
            return
        }
        
        // Check if we've exceeded timeout
        if attempts >= maxAttempts {
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.serverStartGeneration else { return }
                self.isStartingServer = false
                // Clean up partially initialized proxy
                self.thinkingProxy.stop()
                self.showNotification(title: "Server Failed", body: "Could not start thinking proxy on port 8317 (timeout)")
            }
            return
        }
        
        // Schedule next poll
        let interval = Double(intervalMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.pollForProxyReadiness(attempts: attempts + 1, maxAttempts: maxAttempts, intervalMs: intervalMs, generation: generation)
        }
    }

    func stopServer() {
        isStartingServer = false
        serverStartGeneration += 1
        // Stop the thinking proxy first to stop accepting new requests
        thinkingProxy.stop()
        
        // Then stop CLIProxyAPI backend
        serverManager.stop()
        
        updateMenuBarStatus()
    }

    @objc func copyServerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://localhost:\(thinkingProxy.proxyPort)", forType: .string)
        showNotification(title: "Copied", body: "Server URL copied to clipboard")
    }

    @objc func openDashboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ManagementCredentials.secretKey, forType: .string)
        NSWorkspace.shared.open(ManagementCredentials.managementHTMLURL)
    }

    /// Min gap between full quota re-fetches triggered by auth-dir FSEvents (not the user timer).
    private var lastAuthDrivenUsageRefreshAt: Date = .distantPast
    private let authDrivenUsageRefreshMinInterval: TimeInterval = 45

    @objc func handleAuthDirectoryChanged() {
        // Quiet background refresh only — never orderFront/activate. Token refresh and the
        // 5s config fingerprint poll rewrite files often; stealing focus here is what made
        // Settings or the menu-bar chrome jump on top of the user's work intermittently.
        NSLog("[AppDelegate] Auth/config inputs changed — refreshing in background")
        serverManager.handleObservedConfigInputsChanged()
        authManager.checkAuthStatus()
        nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })

        // Debounce quota fetches: FSEvents can fire in bursts when any auth JSON is rewritten.
        // Continuous materialize thrash used to re-enter here every second.
        let now = Date()
        guard now.timeIntervalSince(lastAuthDrivenUsageRefreshAt) >= authDrivenUsageRefreshMinInterval
        else {
            NSLog("[AppDelegate] Skipping quota refresh (debounced; last was < %.0fs ago)", authDrivenUsageRefreshMinInterval)
            return
        }
        lastAuthDrivenUsageRefreshAt = now
        Task {
            await usageStore.refreshVisibleProviders(
                from: ServiceType.allCases,
                accounts: authManager.serviceAccounts.mapValues { $0.accounts }
            )
        }
    }

    @objc func updateMenuBarStatus() {
        // Update icon based on server status
        if let button = statusItem.button {
            let iconName = serverManager.isRunning ? "icon-active.png" : "icon-inactive.png"
            let fallbackSymbol = serverManager.isRunning ? "network" : "network.slash"
            
            if let icon = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
                NSLog("[MenuBar] Loaded %@ icon from cache", serverManager.isRunning ? "active" : "inactive")
            } else {
                let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: serverManager.isRunning ? "Running" : "Stopped")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load %@ icon; using fallback", serverManager.isRunning ? "active" : "inactive")
            }
        }
        updateMenuBarBadge()
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "com.viberouter.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        notificationCenter?.add(request) { error in
            if let error = error {
                NSLog("[Notifications] Failed to deliver notification '%@': %@", title, error.localizedDescription)
            }
        }
    }

    @objc func quit() {
        // Stop server and wait for cleanup before quitting
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        }
        // Give a moment for cleanup to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TokenRefreshService.stopAutoRefresh()
        usageStore.stopAutoRefresh()
        wakeScheduler?.stop()
        NotificationCenter.default.removeObserver(self, name: .serverStatusChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .authDirectoryChanged, object: nil)
        pendingAuthRefresh?.cancel()
        authFileMonitor?.cancel()
        authFileMonitor = nil
        // Final cleanup - stop server if still running
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If server is running, stop it first
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
            // Give server time to stop (up to 3 seconds total with the improved stop method)
            return .terminateNow
        }
        return .terminateNow
    }
    
    // MARK: - Auth Directory Monitoring

    private func startMonitoringAuthDirectory() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

        let fileDescriptor = open(authDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.refreshUserConfigFileMonitor()
            self?.pendingAuthRefresh?.cancel()
            let workItem = DispatchWorkItem {
                self?.postObservedConfigInputsChanged(reason: "Auth directory changed")
            }
            self?.pendingAuthRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        authFileMonitor = source
        refreshUserConfigFileMonitor()
        startPollingConfigInputs()
    }

    private func refreshUserConfigFileMonitor() {
        userConfigFileMonitor?.cancel()
        userConfigFileMonitor = nil

        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
            .appendingPathComponent("config.yaml")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }

        let fileDescriptor = open(configURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self?.refreshUserConfigFileMonitor()
            }
            self?.pendingAuthRefresh?.cancel()
            let workItem = DispatchWorkItem {
                self?.postObservedConfigInputsChanged(reason: "User config changed")
            }
            self?.pendingAuthRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        userConfigFileMonitor = source
    }

    private func startPollingConfigInputs() {
        configInputPoller?.cancel()
        polledConfigInputsFingerprint = currentConfigInputsFingerprint()

        // 5s is plenty for config/auth changes; 1s SHA-256 of credential files burned CPU.
        let poller = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        poller.schedule(deadline: .now() + 5, repeating: 5)
        poller.setEventHandler { [weak self] in
            guard let self else { return }
            let currentFingerprint = self.currentConfigInputsFingerprint()
            guard currentFingerprint != self.polledConfigInputsFingerprint else {
                return
            }
            DispatchQueue.main.async {
                self.polledConfigInputsFingerprint = currentFingerprint
                self.postObservedConfigInputsChanged(reason: "Config input fingerprint changed during poll")
            }
        }
        poller.resume()
        configInputPoller = poller
    }

    private func postObservedConfigInputsChanged(reason: String) {
        polledConfigInputsFingerprint = currentConfigInputsFingerprint()
        NSLog("[AppDelegate] %@ — posting notification", reason)
        NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
    }

    private func currentConfigInputsFingerprint() -> String {
        ConfigInputFingerprint.compute(
            in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api"),
            userConfigFilename: "config.yaml"
        )
    }

    // MARK: - Vercel Config Sync

    private func syncVercelConfig() {
        thinkingProxy.vercelConfig = VercelGatewayConfig(
            enabled: serverManager.vercelGatewayEnabled,
            apiKey: serverManager.vercelApiKey
        )
    }

    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension NSWindow {
    /// LSUIElement apps are never frontmost, and on macOS 14+ activation is cooperative and can
    /// be declined — `makeKeyAndOrderFront` alone then left Settings/About stacked behind the
    /// active app's windows, so clicking "Settings" looked like it did nothing.
    /// `orderFrontRegardless` raises the window even when activation doesn't happen.
    func bringToFront() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}
