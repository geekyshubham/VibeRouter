import Cocoa

if VibeRouterCLI.shouldRun(arguments: CommandLine.arguments) {
    Task { @MainActor in
        let exitCode = await VibeRouterCLI.run(arguments: CommandLine.arguments)
        exit(exitCode)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
