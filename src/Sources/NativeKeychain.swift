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
            // Never fall back to the `security` command: the no-UI switch above is
            // process-local, so a child process opens a password dialog, and a
            // killed child leaves that dialog behind with nobody to receive it.
            return (status == errSecSuccess ? result as? Data : nil, status)
        }
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
