import Foundation

extension Notification.Name {
    static let serverStatusChanged = Notification.Name("ServerStatusChanged")
    static let authDirectoryChanged = Notification.Name("AuthDirectoryChanged")
}

/// Cross-process commands sent by the `viberouter` CLI to the running menu-bar app.
/// Distributed notifications deliberately carry no credentials or account payloads.
enum VibeRouterDistributedCommand {
    static let serverStart = Notification.Name("com.viberouter.cli.server.start")
    static let serverStop = Notification.Name("com.viberouter.cli.server.stop")
    static let serverRestart = Notification.Name("com.viberouter.cli.server.restart")
    static let providerState = Notification.Name("com.viberouter.cli.provider.state")
    static let settingsChanged = Notification.Name("com.viberouter.cli.settings.changed")
}
