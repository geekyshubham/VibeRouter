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

    /// - Parameters:
    ///   - waitingUpTo: How long the caller blocks. A slower read keeps running and fills the cache.
    ///   - fresh: Skip the cache, for a switch that must see the newest token.
    static func read(service: String, account: String? = nil,
                     waitingUpTo wait: TimeInterval = 0.5, fresh: Bool = false) -> (data: Data?, status: OSStatus) {
        if securityToolServices.contains(service) {
            return SecurityTool.read(service: service, account: account, wait: wait, fresh: fresh)
        }
        return perform(key: "read:\(service):\(account ?? "")", cache: true) {
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
            return (status == errSecSuccess ? result as? Data : nil, status)
        }
    }

    /// Preserve existing access controls. Denied writes never delete and
    /// recreate a protected credential to get around its ACL.
    static func write(_ data: Data, service: String, account: String, waitingUpTo wait: TimeInterval = 0.5) -> Bool {
        if securityToolServices.contains(service) {
            return SecurityTool.write(data, service: service, account: account, wait: max(wait, 10))
        }
        return perform(key: "write:\(service):\(account)", cache: false) {
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

    // MARK: - Native CLIs that keep their session through /usr/bin/security

    /// Claude Code creates its item with /usr/bin/security, so the item trusts only
    /// that Apple tool. VibeRouter's own signature changes with every ad-hoc build:
    /// the Security API is refused, and an "Always Allow" for one build rewrote the
    /// item's partition list until Claude Code itself prompted on every read. Going
    /// through the same tool reaches the item exactly as Claude Code does, never
    /// creates an item only VibeRouter can open, and never changes its ACL.
    static let securityToolServices: Set<String> = ["Claude Code-credentials"]

    enum SecurityTool {
        private final class Request {
            let group = DispatchGroup()
            var result: (Data?, OSStatus)?
        }
        private static let lock = NSLock()
        private static var active: (key: String, request: Request)?
        private static var cached: [String: (until: Date, data: Data?, status: OSStatus)] = [:]
        /// Set after a refusal, so a damaged item costs at most one dialog per pause.
        private static var pausedUntil = Date.distantPast
        static let path = "/usr/bin/security"
        static let pauseAfterRefusal: TimeInterval = 10 * 60

        static func read(service: String, account: String?, wait: TimeInterval, fresh: Bool) -> (data: Data?, status: OSStatus) {
            var arguments = ["find-generic-password", "-s", service]
            if let account { arguments += ["-a", account] }
            let (output, status) = run(key: "read:\(service):\(account ?? "")", arguments: arguments + ["-w"],
                                       input: nil, wait: wait, cacheFor: 30, fresh: fresh)
            guard status == errSecSuccess else { return (nil, status) }
            return (output.flatMap(decodePassword), status)
        }

        /// The secret travels on stdin through `security -i`, never in argv.
        static func write(_ data: Data, service: String, account: String, wait: TimeInterval) -> Bool {
            let command = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -X \(hex(data))\n"
            let status = run(key: "write:\(service):\(account)", arguments: ["-i"],
                             input: Data(command.utf8), wait: wait, cacheFor: nil, fresh: true).1
            lock.lock()
            cached = cached.filter { !$0.key.hasPrefix("read:\(service):") }
            lock.unlock()
            return status == errSecSuccess
        }

        /// One helper at a time. A helper that outlives `wait` is left to finish:
        /// it may be showing a dialog, and killing it would orphan that dialog.
        private static func run(key: String, arguments: [String], input: Data?, wait: TimeInterval,
                                cacheFor: TimeInterval?, fresh: Bool) -> (Data?, OSStatus) {
            let deadline = Date().addingTimeInterval(wait)
            while true {
                lock.lock()
                if !fresh, let hit = cached[key], hit.until > Date() {
                    lock.unlock()
                    return (hit.data, hit.status)
                }
                if Date() < pausedUntil { lock.unlock(); return (nil, errSecInteractionNotAllowed) }
                if let active {
                    let joinable = active.key == key && !fresh && input == nil
                    lock.unlock()
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0, active.request.group.wait(timeout: .now() + remaining) == .success else {
                        return (nil, errSecNotAvailable)
                    }
                    if joinable { return active.request.result ?? (nil, errSecNotAvailable) }
                    continue
                }
                let request = Request()
                request.group.enter()
                active = (key, request)
                lock.unlock()
                start(request, key: key, arguments: arguments, input: input, cacheFor: cacheFor)
                guard request.group.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
                    return (nil, errSecNotAvailable)
                }
                return request.result ?? (nil, errSecNotAvailable)
            }
        }

        private static func start(_ request: Request, key: String, arguments: [String], input: Data?, cacheFor: TimeInterval?) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            let buffer = OutputBuffer()
            output.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                buffer.append(output.fileHandleForReading.readDataToEndOfFile())
                let outcome = SecurityTool.status(exitCode: process.terminationStatus)
                lock.lock()
                request.result = (outcome == errSecSuccess ? buffer.data : nil, outcome)
                if let cacheFor { cached[key] = (Date().addingTimeInterval(cacheFor), request.result?.0, outcome) }
                if outcome != errSecSuccess, outcome != errSecItemNotFound {
                    pausedUntil = Date().addingTimeInterval(pauseAfterRefusal)
                    NSLog("[NativeKeychain] /usr/bin/security was refused (exit %d); pausing Claude Code Keychain access",
                          process.terminationStatus)
                }
                active = nil
                lock.unlock()
                request.group.leave()
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                request.result = (nil, errSecNotAvailable)
                active = nil
                lock.unlock()
                request.group.leave()
                return
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }

        private final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
            var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        }

        /// `security` exits with the failing call's OSStatus truncated to a byte; 44 is errSecItemNotFound.
        static func status(exitCode: Int32) -> OSStatus {
            switch exitCode {
            case 0: return errSecSuccess
            case 44: return errSecItemNotFound
            default: return errSecAuthFailed
            }
        }

        /// `-w` prints text as is and anything non-printable as hex.
        static func decodePassword(_ output: Data) -> Data? {
            guard var text = String(data: output, encoding: .utf8) else { return nil }
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
            guard !text.isEmpty else { return nil }
            if text.first != "{", text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) {
                var bytes = Data(capacity: text.count / 2)
                var index = text.startIndex
                while index < text.endIndex {
                    let next = text.index(index, offsetBy: 2)
                    guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
                    bytes.append(byte)
                    index = next
                }
                return bytes
            }
            return Data(text.utf8)
        }

        static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

        static func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
}
