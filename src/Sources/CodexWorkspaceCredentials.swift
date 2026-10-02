import CryptoKit
import Foundation

/// Resolves ChatGPT/Codex OAuth credentials that are actually **scoped** to a workspace seat.
///
/// Cockpit Tools stores **one managed account per `chatgpt_account_id`** (Go personal vs Team/Enterprise).
/// OpenAI encodes the seat in the access-token JWT; writing only `tokens.account_id` while keeping
/// another seat's JWT does not switch billing or usage.
///
/// VibeRouter mirrors that model:
/// - Discover seat lineages under `~/.cli-proxy-api/codex-*.json` and Cockpit's
///   `~/.antigravity_cockpit/codex_accounts/*.json`
/// - Materialize each seat to its own auth file so UI dedupe does not collapse them by email
/// - Refresh before switch; refuse to write a dead seat (expired access + failed refresh)
/// - Rank by JWT recency so a stale Cockpit copy cannot beat a newer cli-proxy token
/// - Try each distinct refresh token newest-first; persist rotated tokens before any seat check
enum CodexWorkspaceCredentials {
    struct Payload: Equatable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var accountID: String
        var email: String?
        var planType: String?
        var source: String

        var asAuthDictionary: [String: Any] {
            var out: [String: Any] = [
                "access_token": accessToken,
                "account_id": accountID,
                "type": "codex",
            ]
            if let refreshToken, !refreshToken.isEmpty { out["refresh_token"] = refreshToken }
            if let idToken, !idToken.isEmpty { out["id_token"] = idToken }
            if let email, !email.isEmpty { out["email"] = email }
            if let planType, !planType.isEmpty { out["plan_type"] = planType }
            let exp = accessTokenExpiry(accessToken) ?? Date().addingTimeInterval(3600)
            out["expired"] = isoString(exp)
            out["expires_in"] = max(60, Int(exp.timeIntervalSinceNow))
            out["last_refresh"] = isoString(Date())
            out["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)
            return out
        }

        var isAccessExpired: Bool {
            guard let exp = accessTokenExpiry(accessToken) else { return false }
            // 60s skew — treat near-expiry as expired so switch refreshes first.
            return exp.addingTimeInterval(-60) <= Date()
        }
    }

    enum ResolveError: LocalizedError, Equatable {
        case noSeatLineage(accountID: String)
        case refreshFailed(accountID: String, plan: String?)
        case missingAccessToken

        var errorDescription: String? {
            switch self {
            case .noSeatLineage(let id):
                return """
                no OAuth session for workspace \(id). \
                Re-login to Codex/ChatGPT with that workspace selected, or import the seat from Cockpit Tools.
                """
            case .refreshFailed(let id, let plan):
                let label = plan.flatMap { ChatGPTPlanFormatter.displayName(for: $0) } ?? "that seat"
                return """
                \(label) session expired and refresh failed (account \(id)). \
                Sign in again with that ChatGPT workspace selected — Team and Go keep separate refresh tokens.
                """
            case .missingAccessToken:
                return "stored account is missing access_token"
            }
        }
    }

    // MARK: - Resolve

    /// Best credentials for `preferredAccountID` without network. Prefer JWT-matching lineages.
    static func resolve(
        preferredAccountID: String?,
        seed: [String: Any],
        email hintEmail: String? = nil
    ) -> Payload? {
        let preferred = preferredAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let email = hintEmail ?? TokenRefreshService.seatEmail(seed)

        let candidates = collectCandidates(seed: seed, email: email)
            .filter { !isTombstonedSeat($0.accountID, email: $0.email ?? email) }
        guard !candidates.isEmpty else { return nil }

        if let preferred {
            // Explicit switch target may still use a tombstoned seat if the seed file itself is that seat
            // (user re-added tokens). Otherwise honor tombstone.
            let matches = candidates.filter {
                $0.accountID.caseInsensitiveCompare(preferred) == .orderedSame
            }
            if let best = pickBest(among: matches) { return best }
            // Allow seed if it is the preferred seat even when tombstoned (re-login path).
            if let fromSeed = payload(from: seed, source: "seed", forceAccountID: nil),
               email == nil || fromSeed.email?.caseInsensitiveCompare(email!) == .orderedSame,
               fromSeed.accountID.caseInsensitiveCompare(preferred) == .orderedSame
            {
                return fromSeed
            }
            return nil
        }

        if let fromSeed = payload(from: seed, source: "seed", forceAccountID: nil),
           email == nil || fromSeed.email?.caseInsensitiveCompare(email!) == .orderedSame {
            return fromSeed
        }
        return pickBest(among: candidates)
    }

    /// Resolve + refresh when access is expired/near-expiry (Cockpit prepare_account_for_injection).
    ///
    /// Tries **every distinct refresh token** for the target seat, newest JWT first.
    /// A stale Cockpit copy must not be the only attempt — its dead RT can return
    /// `refresh_token_reused` and revoke the live cli-proxy family.
    static func resolveFresh(
        preferredAccountID: String?,
        seed: [String: Any],
        email hintEmail: String? = nil
    ) async -> Result<Payload, ResolveError> {
        let preferred = preferredAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let email = hintEmail ?? TokenRefreshService.seatEmail(seed)

        let pool: [Payload]
        if let preferred {
            let matches = collectCandidates(seed: seed, email: email)
                .filter { $0.accountID.caseInsensitiveCompare(preferred) == .orderedSame }
                .filter {
                    !isTombstonedSeat($0.accountID, email: $0.email ?? email) || $0.source == "seed"
                }
            if !matches.isEmpty {
                pool = matches
            } else if let fromSeed = payload(from: seed, source: "seed", forceAccountID: nil),
                      email == nil || fromSeed.email?.caseInsensitiveCompare(email!) == .orderedSame,
                      fromSeed.accountID.caseInsensitiveCompare(preferred) == .orderedSame
            {
                pool = [fromSeed]
            } else {
                return .failure(.noSeatLineage(accountID: preferred))
            }
        } else if let resolved = resolve(preferredAccountID: nil, seed: seed, email: hintEmail) {
            pool = [resolved]
        } else {
            return .failure(.missingAccessToken)
        }

        if let live = pickBest(among: pool.filter { !$0.isAccessExpired }) {
            return .success(live)
        }

        var lastPlan = pickBest(among: pool)?.planType
        var lastID = preferred ?? pickBest(among: pool)?.accountID ?? ""

        for candidate in uniqueRefreshLineages(pool) {
            guard let refresh = candidate.refreshToken, !refresh.isEmpty else { continue }
            lastPlan = candidate.planType
            lastID = preferred ?? candidate.accountID
            switch await TokenRefreshService.refreshOpenAIGrant(refreshToken: refresh) {
            case .success(let json):
                guard let access = stringValue(json, keys: ["access_token"]), !access.isEmpty else {
                    continue
                }
                let newAID = chatgptAccountID(from: access) ?? candidate.accountID
                var resolved = candidate
                resolved.accessToken = access
                resolved.refreshToken = stringValue(json, keys: ["refresh_token"]) ?? refresh
                resolved.idToken = stringValue(json, keys: ["id_token"]) ?? candidate.idToken
                resolved.planType = chatgptPlanType(from: access) ?? candidate.planType
                resolved.accountID = newAID
                // Persist *before* the seat check. OpenAI already invalidated `refresh`;
                // dropping the new tokens leaves every sibling file holding a reused RT.
                TokenRefreshService.propagateRotatedTokens(
                    oldRefresh: refresh,
                    updated: resolved.asAuthDictionary
                )
                if let preferred, newAID.caseInsensitiveCompare(preferred) != .orderedSame {
                    continue
                }
                return .success(resolved)
            case .reuseRevoked:
                // Older sibling RTs are the reused family — sending them makes it worse.
                return .failure(.refreshFailed(accountID: lastID, plan: lastPlan))
            case .failed:
                continue
            }
        }

        return .failure(.refreshFailed(accountID: lastID, plan: lastPlan))
    }

    /// All known seat-scoped payloads for this email (for multi-sub usage probes).
    static func allSeats(seed: [String: Any], email hintEmail: String? = nil) -> [Payload] {
        let email = hintEmail ?? TokenRefreshService.seatEmail(seed)
        var byID: [String: Payload] = [:]

        for candidate in collectCandidates(seed: seed, email: email) {
            if isTombstonedSeat(candidate.accountID, email: candidate.email ?? email),
               candidate.source != "seed"
            {
                continue
            }
            let key = candidate.accountID.lowercased() + "|" + (candidate.email ?? "").lowercased()
            if let existing = byID[key] {
                byID[key] = pickBest(among: [existing, candidate]) ?? candidate
            } else {
                byID[key] = candidate
            }
        }
        if let seedPayload = payload(from: seed, source: "seed", forceAccountID: nil) {
            // Active proxy file wins for its JWT seat (even if previously tombstoned — user re-added).
            if email == nil || seedPayload.email?.caseInsensitiveCompare(email!) == .orderedSame {
                byID[seedPayload.accountID.lowercased() + "|" + (seedPayload.email ?? "").lowercased()] = seedPayload
            }
        }
        return Array(byID.values)
    }

    private static func isTombstonedSeat(_ accountID: String, email: String? = nil) -> Bool {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Two Team members share chatgpt_account_id. Only hide this login.
            return AuthAccountLifecycle.isTombstoned(
                AuthAccountLifecycle.seatKey(accountID: id, email: email)
            )
        }
        return AuthAccountLifecycle.isTombstoned("codex:" + id)
    }

    // MARK: - Materialize (Cockpit → ~/.cli-proxy-api seat files)

    /// Normalize **already-present** CLIProxy codex files into stable `codex-seat-{id}.json` siblings.
    ///
    /// Call only from explicit switch/import — **never** from auth scan (writes re-trigger FSEvents
    /// and caused continuous quota refresh).
    ///
    /// Writes only when the candidate is **strictly better** than the on-disk seat (never thrash
    /// between two equal-score sources for the same account_id).
    @discardableResult
    static func materializeSeatAuthFiles(authDirectory: URL? = nil) -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = authDirectory ?? home.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tombstones = AuthAccountLifecycle.loadTombstones(authDirectory: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // Collapse all sources per login (email + account_id), then write at most once per login.
        var bestBySeat: [String: Payload] = [:]
        for file in files where file.pathExtension == "json" {
            let name = file.lastPathComponent.lowercased()
            guard name.hasPrefix("codex-") else { continue }
            guard let json = readJSON(file),
                  let seat = payload(
                    from: json,
                    source: name.hasPrefix("codex-seat-")
                        ? "codex-seat:\(file.lastPathComponent)"
                        : "cli-proxy:\(file.lastPathComponent)",
                    forceAccountID: nil
                  )
            else { continue }

            let key = seat.accountID.lowercased()
            let emailKey = (seat.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let tombstoneKey = AuthAccountLifecycle.seatKey(accountID: key, email: seat.email)
            if tombstones.contains(tombstoneKey) { continue }
            if emailKey.isEmpty, tombstones.contains("codex:" + key) { continue }
            let groupKey = AccountCredentialIdentity.key(seat.asAuthDictionary)
            if let existing = bestBySeat[groupKey] {
                bestBySeat[groupKey] = pickBest(among: [existing, seat]) ?? existing
            } else {
                bestBySeat[groupKey] = seat
            }
        }

        var wrote = 0
        for (_, seat) in bestBySeat {
            // Only materialize from non-seat sources when the seat file is missing/worse.
            if seat.source.hasPrefix("codex-seat:") { continue }
            let url = dir.appendingPathComponent(seatFilename(for: seat))
            if let existing = readJSON(url),
               let existingPayload = payload(from: existing, source: "disk", forceAccountID: nil),
               existingPayload.accountID.caseInsensitiveCompare(seat.accountID) == .orderedSame
            {
                let existingScore = score(existingPayload)
                let seatScore = score(seat)
                // Require strictly better score OR (same score and same access token → no-op).
                if seatScore < existingScore { continue }
                if seatScore == existingScore, seat.accessToken == existingPayload.accessToken {
                    continue
                }
                if seatScore == existingScore, seat.accessToken != existingPayload.accessToken {
                    // Equal score, different token — keep existing to avoid thrash.
                    continue
                }
            }
            if writeJSON(seat.asAuthDictionary, to: url) {
                wrote += 1
            }
        }
        return wrote
    }

    /// Stable filename: `codex-seat-{accountID}-{email}.json` when email is known so two
    /// Team members on the same org do not overwrite each other's seat clone.
    static func seatFilename(for payload: Payload) -> String {
        AccountCredentialIdentity.filename(payload.asAuthDictionary)
    }

    static func seatFilename(accountID: String, email: String? = nil) -> String {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !email.isEmpty
        {
            let safe = email
                .replacingOccurrences(of: "@", with: "_at_")
                .replacingOccurrences(of: "/", with: "_")
            return "codex-seat-\(id)-\(safe).json"
        }
        return "codex-seat-\(id).json"
    }

    /// Persist a seat under its stable seat file (and return the URL).
    @discardableResult
    static func persistSeat(_ payload: Payload, authDirectory: URL? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = authDirectory ?? home.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try? AccountCredentialStore.save(payload.asAuthDictionary, in: dir)
    }

    // MARK: - Ranking

    /// Prefer JWT-matching, non-expired, recency, then source.
    static func pickBest(among candidates: [Payload]) -> Payload? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
    }

    static func score(_ p: Payload) -> Int {
        var s = 0
        if chatgptAccountID(from: p.accessToken)?.caseInsensitiveCompare(p.accountID) == .orderedSame {
            s += 100
        }
        if !p.isAccessExpired { s += 50 }
        if p.refreshToken?.isEmpty == false { s += 10 }
        // Recency beats source. A 47-day-old Cockpit copy used to outrank a 1-day-expired
        // cli-proxy file (+5 vs +2) and its dead RT then revoked the live family.
        if let exp = accessTokenExpiry(p.accessToken) {
            let hours = exp.timeIntervalSinceNow / 3600
            s += Int(max(-400.0, min(400.0, hours.rounded(.towardZero))))
        }
        if p.source.hasPrefix("cockpit") { s += 5 }
        if p.source == "seed" { s += 3 }
        if p.source.hasPrefix("cli-proxy") || p.source.hasPrefix("codex-seat") { s += 2 }
        return s
    }

    /// Distinct refresh tokens for a seat, newest access JWT first.
    static func uniqueRefreshLineages(_ candidates: [Payload]) -> [Payload] {
        let sorted = candidates.sorted { lhs, rhs in
            let leftExp = accessTokenExpiry(lhs.accessToken) ?? .distantPast
            let rightExp = accessTokenExpiry(rhs.accessToken) ?? .distantPast
            if leftExp != rightExp { return leftExp > rightExp }
            return score(lhs) > score(rhs)
        }
        var seen = Set<String>()
        var out: [Payload] = []
        for candidate in sorted {
            let rt = candidate.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rt.isEmpty, seen.insert(rt).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    // MARK: - Collection

    private static func collectCandidates(seed: [String: Any], email: String?) -> [Payload] {
        var out: [Payload] = []
        var seen = Set<String>()

        func append(_ payload: Payload?) {
            guard let payload else { return }
            if let email {
                guard let candidateEmail = payload.email,
                      candidateEmail.caseInsensitiveCompare(email) == .orderedSame else { return }
            }
            let key = payload.accountID.lowercased() + "|" + (payload.email ?? "").lowercased()
                + "|" + SHA256.hash(data: Data(payload.accessToken.utf8)).description
            guard seen.insert(key).inserted else { return }
            out.append(payload)
        }

        append(payload(from: seed, source: "seed", forceAccountID: nil))

        let home = FileManager.default.homeDirectoryForCurrentUser

        let proxyDir = home.appendingPathComponent(".cli-proxy-api")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: proxyDir,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                let name = file.lastPathComponent.lowercased()
                guard name.hasPrefix("codex-"),
                      let json = readJSON(file)
                else { continue }
                let source = name.hasPrefix("codex-seat-")
                    ? "codex-seat:\(file.lastPathComponent)"
                    : "cli-proxy:\(file.lastPathComponent)"
                append(payload(from: json, source: source, forceAccountID: nil))
            }
        }

        let cockpitDir = home.appendingPathComponent(".antigravity_cockpit/codex_accounts")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: cockpitDir,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                guard let json = readJSON(file) else { continue }
                var flat = json
                if let tokens = json["tokens"] as? [String: Any] {
                    for (k, v) in tokens { flat[k] = v }
                }
                let forced = stringValue(json, keys: ["account_id"])
                append(payload(
                    from: flat,
                    source: "cockpit:\(file.lastPathComponent)",
                    forceAccountID: forced
                ))
            }
        }

        let codexAuth = home.appendingPathComponent(".codex/auth.json")
        if let root = readJSON(codexAuth) {
            var flat = root
            if let tokens = root["tokens"] as? [String: Any] {
                for (k, v) in tokens { flat[k] = v }
            }
            append(payload(from: flat, source: "codex-auth.json", forceAccountID: nil))
        }

        return out
    }

    private static func payload(
        from json: [String: Any],
        source: String,
        forceAccountID: String?
    ) -> Payload? {
        guard AccountCredentialIdentity.isConsistent(json) else { return nil }
        guard let access = stringValue(json, keys: ["access_token"]), !access.isEmpty else {
            return nil
        }
        let jwtAccount = chatgptAccountID(from: access)
            ?? chatgptAccountID(from: stringValue(json, keys: ["id_token"]))
        let storedAccount = stringValue(json, keys: ["account_id", "chatgpt_account_id"])
        // Prefer JWT seat — that is what the API actually bills against.
        let accountID = (jwtAccount ?? forceAccountID ?? storedAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID, !accountID.isEmpty else { return nil }

        let plan = chatgptPlanType(from: access)
            ?? chatgptPlanType(from: stringValue(json, keys: ["id_token"]))
            ?? stringValue(json, keys: ["plan_type", "chatgpt_plan_type"])

        let email = TokenRefreshService.seatEmail(json)

        return Payload(
            accessToken: access,
            refreshToken: stringValue(json, keys: ["refresh_token"]),
            idToken: stringValue(json, keys: ["id_token"]),
            accountID: accountID,
            email: email,
            planType: plan,
            source: source
        )
    }

    // MARK: - JWT helpers

    static func chatgptAccountID(from token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_account_id", "account_id"])
    }

    static func chatgptUserID(from token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_user_id", "user_id"])
    }

    static func chatgptPlanType(from token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_plan_type"])
    }

    static func accessTokenExpiry(_ token: String?) -> Date? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let exp = json["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = json["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    static func openAIAuthClaims(from token: String?) -> [String: Any]? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["https://api.openai.com/auth"] as? [String: Any]
    }

    // MARK: - Keychain (Codex CLI / desktop — same as Cockpit)

    static let keychainService = "Codex Auth"

    static func keychainAccountName(codexHome: URL) -> String {
        let path = (codexHome as NSURL).resolvingSymlinksInPath?.path ?? codexHome.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|" + String(hex.prefix(16))
    }

    @discardableResult
    static func writeKeychain(authFileJSON: [String: Any], codexHome: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: authFileJSON, options: [.sortedKeys]),
              let secret = String(data: data, encoding: .utf8)
        else { return false }

        let account = keychainAccountName(codexHome: codexHome)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-s", keychainService,
            "-a", account,
            "-w", secret,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Codex CLI/desktop persist the live session here first; `~/.codex/auth.json` can lag.
    static func readKeychain(codexHome: URL) -> [String: Any]? {
        let account = keychainAccountName(codexHome: codexHome)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService,
            "-a", account,
            "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !output.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - IO

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    @discardableResult
    private static func writeJSON(_ json: [String: Any], to url: URL) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
