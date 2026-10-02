import Foundation

/// Append-only record of every Kiro reply served through VibeRouter's proxy, so that
/// proxy traffic is attributed to Kiro (credits + estimated tokens) instead of being
/// mistaken for Anthropic API usage in Claude Code's own transcripts.
enum KiroProxyUsageLedger {
    enum TokenSource: String, Codable, Equatable {
        case kiroMetadata = "kiro-metadata"
        case contextPercentage = "context-pct"
        case payloadBytes = "payload-bytes"
        case claudeLog = "claude-log"
    }

    struct Entry: Codable, Equatable {
        var id: String
        var timestamp: Date
        var model: String
        var credits: Double?
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var tokenSource: TokenSource
        var contextUsagePercentage: Double?
        var account: String?
        var accountUserHash: String?
        var claudeMessageID: String?

        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    }

    private static let lock = NSLock()

    static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = dir.appendingPathComponent("VibeRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("kiro-proxy-usage.jsonl")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func append(_ entry: Entry, to url: URL? = fileURL) {
        guard let url, var line = try? encoder().encode(entry) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private struct Parsed {
        var fileNumber: Int
        var size: Int
        var mtime: Date
        /// Bytes consumed through the last complete line, so appends resume from here.
        var offset: Int
        var entries: [Entry] = []
        var seen = Set<String>()
        var latestAccount: (timestamp: Date, account: String)?
        var oldest: Date?

        mutating func ingest(_ data: Data, decoder: JSONDecoder) {
            guard let end = data.lastIndex(of: 0x0A) else { return }
            for line in data[..<end].split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                      seen.insert(entry.id).inserted
                else { continue }
                entries.append(entry)
                oldest = min(oldest ?? entry.timestamp, entry.timestamp)
                if let account = entry.account, entry.timestamp >= (latestAccount?.timestamp ?? .distantPast) {
                    latestAccount = (entry.timestamp, account)
                }
            }
            offset += data.distance(from: data.startIndex, to: end) + 1
        }
    }

    private static var parsedCache: [String: Parsed] = [:]

    /// The login (`cli-social`, `cli-oidc`, or `auth-file:<name>`) billed by the newest request.
    static func latestAccount(from url: URL? = fileURL) -> String? {
        guard let url else { return nil }
        return parsed(url)?.latestAccount?.account
    }

    /// Entries at or after `since`, de-duplicated by `id` (first occurrence wins).
    static func read(since: Date? = nil, from url: URL? = fileURL, now: Date = Date()) -> [Entry] {
        guard let url, var state = parsed(url) else { return [] }
        if let cutoff = retentionCutoff(now: now), let oldest = state.oldest, oldest < cutoff {
            compact(url, keepingSince: cutoff)
            state = parsed(url) ?? state
        }
        guard let since else { return state.entries }
        return state.entries.filter { $0.timestamp >= since }
    }

    private static func retentionCutoff(now: Date) -> Date? {
        Calendar.current.date(byAdding: .day, value: -UsageDailyStore.retentionDays, to: Calendar.current.startOfDay(for: now))
    }

    /// Decodes only what changed since the last call: nothing when (inode, size, mtime) match, the appended tail when the file grew.
    private static func parsed(_ url: URL) -> Parsed? {
        lock.lock()
        defer { lock.unlock() }
        let key = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: key) else {
            parsedCache[key] = nil
            return nil
        }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let mtime = attributes[.modificationDate] as? Date ?? .distantPast
        if let cached = parsedCache[key], cached.fileNumber == fileNumber, cached.size == size, cached.mtime == mtime {
            return cached
        }
        var state = Parsed(fileNumber: fileNumber, size: size, mtime: mtime, offset: 0)
        if let cached = parsedCache[key], cached.fileNumber == fileNumber, size >= cached.offset {
            state = cached
            state.size = size
            state.mtime = mtime
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(state.offset))
            let tail = try handle.readToEnd() ?? Data()
            state.ingest(tail, decoder: decoder())
        } catch {
            return nil
        }
        parsedCache[key] = state
        return state
    }

    /// Rewrites the ledger without entries older than `cutoff` (and without duplicate ids).
    static func compact(_ url: URL, keepingSince cutoff: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = decoder()
        let encoder = encoder()
        var seen = Set<String>()
        var kept = Data()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  entry.timestamp >= cutoff,
                  seen.insert(entry.id).inserted,
                  var encoded = try? encoder.encode(entry)
            else { continue }
            encoded.append(0x0A)
            kept.append(encoded)
        }
        guard (try? kept.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        parsedCache[url.path] = nil
    }
}
