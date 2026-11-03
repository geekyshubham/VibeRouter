import Foundation
import Security
import LocalAuthentication

/// Native account discovery never waits indefinitely for the system Keychain.
/// One native operation may run at a time; a stuck security server cannot build
/// an unbounded queue of credential requests or freeze the interface.
enum NativeKeychain {
    private final class Request {
        let finished = DispatchSemaphore(value: 0)
        var result: (Data?, OSStatus)?
    }
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "com.viberouter.keychain", qos: .utility)
    private static var active: (key: String, request: Request)?
    private static var cached: [String: (until: Date, data: Data?, status: OSStatus)] = [:]

    private static func perform(key: String, cache: Bool,
                                operation: @escaping () -> (Data?, OSStatus)) -> (data: Data?, status: OSStatus) {
        lock.lock()
        if cache, let result = cached[key], result.until > Date() {
            lock.unlock()
            return (result.data, result.status)
        }
        let request: Request
        if let active {
            guard cache, active.key == key else { lock.unlock(); return (nil, errSecNotAvailable) }
            request = active.request
        } else {
            request = Request()
            active = (key, request)
            queue.async {
                // LAContext covers modern items; the process-local legacy switch
                // also covers native CLI entries in the file-based login Keychain.
                let allowed = SecKeychainSetUserInteractionAllowed(false)
                let result = allowed == errSecSuccess ? operation() : (nil, allowed)
                lock.lock()
                request.result = result
                if cache {
                    cached[key] = (Date().addingTimeInterval(result.1 == errSecSuccess ? 2 : 30), result.0, result.1)
                } else {
                    cached.removeAll()
                }
                active = nil
                lock.unlock()
                request.finished.signal()
            }
        }
        lock.unlock()
        _ = request.finished.wait(timeout: .now() + 0.5)
        lock.lock()
        let result = request.result ?? (nil, errSecNotAvailable)
        lock.unlock()
        return result
    }

    static func read(service: String, account: String? = nil) -> (data: Data?, status: OSStatus) {
        perform(key: "read:\(service):\(account ?? "")", cache: true) {
            let context = LAContext()
            context.interactionNotAllowed = true
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            query[kSecAttrAccount as String] = account
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { return (result as? Data, status) }
            // Ad-hoc rebuilds change our signature, so a prior "Always Allow"
            // stops matching. Items written via /usr/bin/security trust that
            // tool, which can still read them without a prompt.
            if [errSecAuthFailed, errSecInteractionNotAllowed].contains(status),
               securityToolServices.contains(service),
               let data = readWithSecurityTool(service: service, account: account) {
                return (data, errSecSuccess)
            }
            return (nil, status)
        }
    }

    /// Native CLIs that store their session through /usr/bin/security.
    static let securityToolServices: Set<String> = ["Claude Code-credentials"]

    /// Read-only fallback. Killed after two seconds so a surprise prompt cannot hang the queue.
    private static func readWithSecurityTool(service: String, account: String?) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        process.arguments = arguments + ["-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return Data(text.utf8)
    }

    /// Preserve existing access controls. Denied writes never launch a helper or
    /// delete and recreate a protected credential to get around its ACL.
    static func write(_ data: Data, service: String, account: String) -> Bool {
        perform(key: "write:\(service):\(account)", cache: false) {
            let context = LAContext()
            context.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
            }
            return (nil, status)
        }.status == errSecSuccess
    }
}
