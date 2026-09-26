import Foundation

/// Banked manual rate-limit resets across providers — the ability to *see* the
/// inventory and *redeem* one on demand (clears current limits immediately,
/// same idea as QuotaWakeService but consuming a real reset instead of waking
/// a rolling window).
///
/// Today: ChatGPT/Codex (`wham/rate-limit-reset-credits`), SuperGrok
/// (`prod_mc_billing.ConsumerUiSvc/GetRemainingResets|RedeemReset`), and
/// Claude (`/api/oauth/usage` cedar_ember + juniper_tide, redeemed at
/// `/api/organizations/{org}/reset_rate_limits`). New providers only need a
/// listing + redeem implementation plus `supports(_:)`.
enum RateLimitResetService {
    enum ResetResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    /// Providers whose reset banks VibeRouter can read today.
    static func supports(_ type: ServiceType) -> Bool {
        switch type {
        case .codex, .grok, .claude:
            return true
        default:
            return false
        }
    }

    /// Redeems (applies) one reset for this account right now.
    static func redeem(account: AuthAccount) async -> ResetResult {
        guard supports(account.type) else {
            return .failure(message: "\(account.type.displayName) does not support rate-limit resets")
        }

        // Always refresh first so direct-auth calls use a live access token.
        _ = await TokenRefreshService.refreshAccountFile(account.filePath)

        switch account.type {
        case .codex:
            return await redeemCodex(account: account)
        case .grok:
            return await redeemGrok(account: account)
        case .claude:
            return await redeemClaude(account: account)
        default:
            return .failure(message: "\(account.type.displayName) does not support rate-limit resets")
        }
    }

    // MARK: - ChatGPT / Codex

    private static func redeemCodex(account: AuthAccount) async -> ResetResult {
        guard let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
              let accessToken = stringValue(payload, keys: ["access_token"])
        else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName)")
        }
        let jwtAccountID = chatgptAccountIDFromJWT(accessToken)
            ?? chatgptAccountIDFromJWT(stringValue(payload, keys: ["id_token"]))
        let accountID = stringValue(payload, keys: ["account_id"]) ?? jwtAccountID

        let credits = await NativeUsageFetcher.fetchCodexAvailableResets(
            accessToken: accessToken,
            chatGPTAccountID: accountID
        )
        guard let credits else {
            return .failure(message: "Could not reach ChatGPT resets — check connection and retry (nothing was consumed).")
        }
        guard let credit = preferredCodexCredit(credits) else {
            return .failure(message: "No usable ChatGPT rate-limit reset found — nothing to apply.")
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume") else {
            return .failure(message: "Invalid reset URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        let redeemRequestID = UUID().uuidString.lowercased()
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "credit_id": credit.id,
            "redeem_request_id": redeemRequestID,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid reset response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(
                    message: "ChatGPT session expired while applying the reset — re-authenticate and retry (the reset is still banked)."
                )
            }
            guard (200...299).contains(http.statusCode) else {
                let snippet = String(data: data.prefix(200), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                return .failure(message: "Could not apply ChatGPT reset (HTTP \(http.statusCode)). \(snippet)")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["code"] as? String
            let windowsReset = json?["windows_reset"] as? Int ?? 0
            if let code, code.lowercased() != "reset", code.lowercased() != "ok" {
                return .failure(message: "ChatGPT did not apply the reset (\(code)). Try again shortly.")
            }
            var line = "Applied ChatGPT rate-limit reset"
            if windowsReset > 0 { line += " · \(windowsReset) limit window\(windowsReset == 1 ? "" : "s") cleared" }
            return .success(message: line + ".")
        } catch {
            return .failure(message: "Reset request failed: \(error.localizedDescription)")
        }
    }

    /// Prefer the soonest-expiring credit so nothing is wasted to expiry.
    private static func preferredCodexCredit(_ credits: [NativeUsageFetcher.CodexResetCredit]) -> NativeUsageFetcher.CodexResetCredit? {
        credits.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }.first
    }

    // MARK: - SuperGrok

    /// gRPC-web endpoint for the consumer billing UI (Settings → Usage page).
    private static let grokEndpointBase = "https://grok.com/prod_mc_billing.ConsumerUiSvc"

    struct GrokResetToken: Equatable {
        let tokenID: String
        let validFrom: Date?
        let validUntil: Date?

        func isCurrentlyValid(now: Date = Date()) -> Bool {
            if let validFrom, validFrom > now { return false }
            if let validUntil, validUntil <= now { return false }
            return !tokenID.isEmpty
        }
    }

    enum GrokResetsOutcome: Equatable {
        case success([GrokResetToken])
        case failure(String)
    }

    /// Lists remaining SuperGrok usage resets (one-time "clear your weekly pool").
    static func fetchGrokRemainingResets(accessToken: String) async -> GrokResetsOutcome {
        guard let url = URL(string: "\(grokEndpointBase)/GetRemainingResets") else {
            return .failure("Invalid reset URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = grpcWebFrame(Data())
        applyGrokHeaders(to: &request, accessToken: accessToken)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure("Grok resets returned HTTP \(http.statusCode)")
            }
            if let grpcError = grokGRPCFailure(data) {
                return .failure(grpcError)
            }
            return .success(parseGrokRemainingResets(data))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Bank for snapshots; nil when the endpoint is unavailable or empty.
    static func fetchGrokBank(accessToken: String) async -> RateLimitResetBank? {
        switch await fetchGrokRemainingResets(accessToken: accessToken) {
        case .success(let tokens):
            let valid = tokens.filter { $0.isCurrentlyValid() }
            let next = valid.compactMap(\.validUntil).sorted().first
            return RateLimitResetBank(
                availableCount: valid.count,
                nextExpiresAt: next,
                sampleTitle: valid.isEmpty ? nil : "Clears your full weekly pool once",
                canRedeem: true
            )
        case .failure:
            return nil
        }
    }

    private static func redeemGrok(account: AuthAccount) async -> ResetResult {
        let label = account.baseDisplayName
        for candidate in await grokTokenCandidates(for: account) {
            switch await fetchGrokRemainingResets(accessToken: candidate) {
            case .success(let tokens):
                let valid = tokens.filter { $0.isCurrentlyValid() }
                guard let token = valid.sorted(by: { ($0.validUntil ?? .distantFuture) < ($1.validUntil ?? .distantFuture) }).first else {
                    return .failure(message: "No SuperGrok usage resets left for \(label).")
                }
                return await submitGrokRedeem(tokenID: token.tokenID, accessToken: candidate, label: label)
            case .failure(let message):
                if isGrokAuthFailure(message) { continue }
                return .failure(message: friendlyGrokResetError(message))
            }
        }
        return .failure(
            message: "Could not reach Grok resets for \(label) — run `grok login` or reconnect Grok in Settings."
        )
    }

    private static func submitGrokRedeem(tokenID: String, accessToken: String, label: String) async -> ResetResult {
        guard let url = URL(string: "\(grokEndpointBase)/RedeemReset") else {
            return .failure(message: "Invalid reset URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = grokRedeemRequestBody(tokenID: tokenID)
        applyGrokHeaders(to: &request, accessToken: accessToken)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid reset response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(message: "Grok rejected the reset request — run `grok login` and retry (the reset is still banked).")
            }
            guard (200...299).contains(http.statusCode),
                  grokGRPCFailure(data) == nil
            else {
                let grpcError = grokGRPCFailure(data)
                return .failure(message: friendlyGrokResetError(grpcError ?? "Grok reset returned HTTP \(http.statusCode)"))
            }
            return .success(message: "Redeemed SuperGrok usage reset for \(label) — your weekly pool was cleared.")
        } catch {
            return .failure(message: friendlyGrokResetError(error.localizedDescription))
        }
    }

    /// Token order mirrors fetchGrokUsage: live ~/.grok CLI token first, then the auth file.
    private static func grokTokenCandidates(for account: AuthAccount) async -> [String] {
        var candidates: [String] = []
        func append(_ token: String?) {
            guard let token, !token.isEmpty, !candidates.contains(token) else { return }
            candidates.append(token)
        }

        let local = NativeUsageFetcher.readGrokAppPayload()
        let filePayload = NativeUsageFetcher.readAuthPayload(at: account.filePath) ?? [:]
        let ordered = NativeUsageFetcher.grokBillingTokenCandidates(
            accountPayload: filePayload,
            localGrok: local
        )
        for candidate in ordered {
            append(candidate.token)
        }

        return candidates
    }

    // MARK: - gRPC-web plumbing

    private static func applyGrokHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
    }

    /// grpc-web frame: 1 flag byte (0 = data) + 4 big-endian length bytes + payload.
    static func grpcWebFrame(_ payload: Data) -> Data {
        var out = Data([0x00])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// ConsumerRedeemResetReq{token_id = 10} wrapped in a grpc-web frame.
    static func grokRedeemRequestBody(tokenID: String) -> Data {
        var message = Data([0x52]) // field 10, wire type 2
        message.appendProtoVarint(tokenID.utf8.count)
        message.append(contentsOf: tokenID.utf8)
        return grpcWebFrame(message)
    }

    /// Parses GetRemainingResets responses (repeated ConsumerResetToken = field 10).
    static func parseGrokRemainingResets(_ data: Data, now: Date = Date()) -> [GrokResetToken] {
        let frames = NativeUsageFetcher.grokGRPCWebDataFrames(from: data)
        guard !frames.isEmpty || grokLooksLikeProtobuf(data) else { return [] }
        let payloads = frames.isEmpty ? [data] : frames

        var tokens: [GrokResetToken] = []
        for payload in payloads {
            var reader = ProtoReader(payload)
            while let field = reader.next() {
                guard field.fieldNumber == 10, case .lengthDelimited(let message)? = field.value else { continue }
                tokens.append(parseGrokResetToken(message))
            }
        }
        return tokens.filter { $0.isCurrentlyValid(now: now) }
    }

    private static func parseGrokResetToken(_ message: Data) -> GrokResetToken {
        var tokenID = ""
        var validFrom: Date?
        var validUntil: Date?
        var reader = ProtoReader(message)
        while let field = reader.next() {
            switch (field.fieldNumber, field.value) {
            case (10, .lengthDelimited(let data)):
                tokenID = String(data: data, encoding: .utf8) ?? ""
            case (20, .lengthDelimited(let data)):
                validFrom = Self.parseTimestamp(data)
            case (30, .lengthDelimited(let data)):
                validUntil = Self.parseTimestamp(data)
            default:
                break
            }
        }
        return GrokResetToken(tokenID: tokenID, validFrom: validFrom, validUntil: validUntil)
    }

    /// google.protobuf.Timestamp{seconds = 1, nanos = 2}.
    private static func parseTimestamp(_ message: Data) -> Date? {
        var reader = ProtoReader(message)
        while let field = reader.next() {
            if field.fieldNumber == 1, case .varint(let seconds)? = field.value,
               seconds > 1_500_000_000, seconds < 4_000_000_000
            {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
        }
        return nil
    }

    /// Non-nil when the trailer reports a gRPC failure.
    static func grokGRPCFailure(_ data: Data) -> String? {
        let trailers = NativeUsageFetcher.grokGRPCWebTrailerFields(from: data)
        guard let rawStatus = trailers["grpc-status"], let status = Int(rawStatus), status != 0 else {
            return nil
        }
        let message = (trailers["grpc-message"] ?? "Grok reset request failed")
            .removingPercentEncoding?
            .replacingOccurrences(of: "+", with: " ")
            ?? "Grok reset request failed"
        return "grpc \(status): \(message)"
    }

    private static func isGrokAuthFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unauthenticated") || lower.contains("grpc 16") || lower.contains("grpc 7")
    }

    private static func friendlyGrokResetError(_ raw: String) -> String {
        if isGrokAuthFailure(raw) {
            return "Grok rejected the reset request — run `grok login` (the reset is still banked)."
        }
        return "Could not apply Grok reset: \(raw)"
    }

    private static func grokLooksLikeProtobuf(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    // MARK: - Minimal protobuf reader

    struct ProtoField {
        enum Value {
            case varint(UInt64)
            case fixed64(Data)
            case lengthDelimited(Data)
            case fixed32(Data)
        }

        let fieldNumber: UInt64
        let value: Value?
    }

    struct ProtoReader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        mutating func next() -> ProtoField? {
            while index < bytes.count {
                let fieldStart = index
                guard let key = readVarint() else {
                    index = fieldStart + 1
                    continue
                }
                let fieldNumber = key >> 3
                let wireType = key & 0x07
                guard fieldNumber > 0 else {
                    index = fieldStart + 1
                    continue
                }
                switch wireType {
                case 0:
                    if let value = readVarint() {
                        return ProtoField(fieldNumber: fieldNumber, value: .varint(value))
                    }
                    index = fieldStart + 1
                case 1:
                    guard index + 8 <= bytes.count else { return nil }
                    let data = Data(bytes[index..<index + 8])
                    index += 8
                    return ProtoField(fieldNumber: fieldNumber, value: .fixed64(data))
                case 2:
                    guard let length = readVarint(), length <= UInt64(bytes.count - index) else {
                        index = fieldStart + 1
                        continue
                    }
                    let data = Data(bytes[index..<index + Int(length)])
                    index += Int(length)
                    return ProtoField(fieldNumber: fieldNumber, value: .lengthDelimited(data))
                case 5:
                    guard index + 4 <= bytes.count else { return nil }
                    let data = Data(bytes[index..<index + 4])
                    index += 4
                    return ProtoField(fieldNumber: fieldNumber, value: .fixed32(data))
                default:
                    index = fieldStart + 1
                }
            }
            return nil
        }

        private mutating func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
    }

    // MARK: - Claude

    /// One spendable or banked Claude reset.
    /// Cedar (`cedar_ember`) is the saved "Reset for free" grant. Juniper
    /// (`juniper_tide`) is Claude Code's weekly `/limit-reset` (session only).
    struct ClaudeResetOffer: Equatable {
        enum Program: String, Equatable {
            case cedar = "cedar_ember"
            case juniper = "juniper_tide"
        }

        let program: Program
        let id: String
        let title: String
        let remaining: Int
        let expiresAt: Date?
        /// Server will accept a redeem of this offer right now.
        let usableNow: Bool
        /// Cedar only: this grant is `next_grant_id`.
        let isNext: Bool
    }

    struct ClaudeResetInventory: Equatable {
        let bank: RateLimitResetBank
        /// Offer `redeem` will POST. Nil when nothing is spendable yet.
        let offer: ClaudeResetOffer?
        /// OAuth was told the saved grant lives on claude.ai, not this token.
        let surfaceBlind: Bool
    }

    private static let claudeOAuthBase = "https://api.anthropic.com/api/oauth"
    private static let claudeAPIBase = "https://api.anthropic.com"
    /// Claude answers `ineligible_reason=cli_version` when this UA is older
    /// than the CLI build that speaks the reset API. Prefer the installed
    /// `claude` version; the floor is the build this client was checked against.
    private static let claudeResetUserAgent: String = {
        if let version = installedClaudeCodeVersion() {
            return "claude-code/\(version)"
        }
        return "claude-code/2.1.283"
    }()

    /// Bank for snapshots. Nil when the probes fail, or when the only answer
    /// is "this grant is web-only" — that must not paint "no resets left".
    static func fetchClaudeBank(accessToken: String) async -> RateLimitResetBank? {
        guard let listing = await listClaudeResets(accessToken: accessToken) else { return nil }
        return claudeBankForDisplay(listing)
    }

    /// Nil when there is nothing honest to paint (probe miss, or a web-only grant).
    static func claudeBankForDisplay(_ listing: ClaudeResetInventory) -> RateLimitResetBank? {
        if listing.surfaceBlind && listing.bank.availableCount == 0 { return nil }
        return listing.bank
    }

    /// `cedar_ember=1` is the anytime read. The spendable grant Claude Code
    /// shows at a limit lives on `cedar_ember` inside `at_wall=1` — a
    /// surface-blind anytime body must not hide that grant.
    static func preferClaudeResetInventory(
        anytime: ClaudeResetInventory?,
        atWall: ClaudeResetInventory?
    ) -> ClaudeResetInventory? {
        switch (anytime, atWall) {
        case (nil, nil):
            return nil
        case (let listing?, nil), (nil, let listing?):
            return listing
        case (let anytime?, let atWall?):
            if atWall.offer != nil { return atWall }
            if anytime.offer != nil { return anytime }
            if atWall.bank.availableCount > 0 { return atWall }
            if anytime.bank.availableCount > 0 { return anytime }
            // Neither read has a grant. Keep the surface-blind anytime body
            // so a web-only grant stays blank instead of "none left".
            if anytime.surfaceBlind { return anytime }
            return atWall
        }
    }

    /// Pure parse of the two usage-probe fields. `*Reached == false` means the
    /// HTTP probe failed. A reached nil field is an authoritative empty.
    static func parseClaudeResetInventory(
        cedarField: [String: Any]?,
        cedarReached: Bool,
        juniperField: [String: Any]?,
        juniperReached: Bool,
        now: Date = Date()
    ) -> ClaudeResetInventory? {
        if !cedarReached && !juniperReached { return nil }

        let cedar = cedarReached ? parseCedarStatus(cedarField, now: now) : CedarStatus(offers: [], surfaceBlind: false)
        let juniper = juniperReached ? parseJuniperOffer(juniperField) : nil
        // A failed cedar probe plus no juniper reset is "unknown", not "none left".
        if !cedarReached && juniper == nil { return nil }
        // ponytail: OAuth only. A cedar grant with ineligible_reason=surface is
        // the claude.ai session, not this token. Upgrade path is the desktop
        // sessionKey cookie — another OAuth probe will not see the grant id.

        var offers = cedar.offers
        if let juniper { offers.append(juniper) }
        let offer = preferredClaudeOffer(offers)
        let count = offers.reduce(0) { $0 + max(0, $1.remaining) }
        let expires = offers.compactMap(\.expiresAt).min()
        let title: String? = {
            if let offer { return offer.title }
            if count > 0 { return "Saved until you reach a usage limit" }
            return nil
        }()
        return ClaudeResetInventory(
            bank: RateLimitResetBank(
                availableCount: count,
                nextExpiresAt: expires,
                sampleTitle: title,
                canRedeem: offer != nil
            ),
            offer: offer,
            surfaceBlind: cedar.surfaceBlind && cedar.offers.isEmpty
        )
    }

    private struct CedarStatus {
        var offers: [ClaudeResetOffer]
        var surfaceBlind: Bool
    }

    private static func parseCedarStatus(_ field: [String: Any]?, now: Date) -> CedarStatus {
        guard let field else { return CedarStatus(offers: [], surfaceBlind: false) }
        let reason = (stringValue(field, keys: ["ineligible_reason"]) ?? "").lowercased()
        let eligible = boolValue(field, key: "eligible") ?? false
        let nextID = stringValue(field, keys: ["next_grant_id"])
        let cooldown = parseISO8601(stringValue(field, keys: ["cooldown_until"]))
        let coolingDown = cooldown.map { $0 > now } ?? false
        let rawGrants = field["grants"] as? [[String: Any]] ?? []

        var offers: [ClaudeResetOffer] = []
        for grant in rawGrants {
            guard let id = stringValue(grant, keys: ["id"]), isCedarGrantID(id) else { continue }
            let remaining = intValue(grant, keys: ["resets_left"]) ?? 0
            guard remaining > 0 else { continue }
            if boolValue(grant, key: "paused") == true { continue }
            let starts = parseISO8601(stringValue(grant, keys: ["starts_at"]))
            if let starts, starts > now { continue }
            let ends = parseISO8601(stringValue(grant, keys: ["ends_at"]))
            if let ends, ends <= now { continue }
            let usableFlag = boolValue(grant, key: "usable_now") ?? false
            let isNext = nextID == id
            let clears = stringList(grant["clears"])
            offers.append(
                ClaudeResetOffer(
                    program: .cedar,
                    id: id,
                    title: cedarTitle(label: stringValue(grant, keys: ["label"]), clears: clears),
                    remaining: remaining,
                    expiresAt: ends,
                    usableNow: eligible && isNext && usableFlag && !coolingDown,
                    isNext: isNext
                )
            )
        }
        let surfaceBlind = reason == "surface" && offers.isEmpty
        return CedarStatus(offers: offers, surfaceBlind: surfaceBlind)
    }

    private static func parseJuniperOffer(_ field: [String: Any]?) -> ClaudeResetOffer? {
        guard let field else { return nil }
        let eligible = boolValue(field, key: "eligible") ?? false
        let arm = (stringValue(field, keys: ["arm"]) ?? "").lowercased()
        let available = boolValue(field, key: "available") ?? false
        guard eligible, arm == "reset", available else { return nil }
        return ClaudeResetOffer(
            program: .juniper,
            id: ClaudeResetOffer.Program.juniper.rawValue,
            title: "Session limit reset",
            remaining: 1,
            expiresAt: nil,
            usableNow: true,
            isNext: true
        )
    }

    /// Spendable cedar (the server-selected grant) first, then juniper.
    /// A saved-but-not-yet-usable cedar grant stays in the count and is not offered.
    private static func preferredClaudeOffer(_ offers: [ClaudeResetOffer]) -> ClaudeResetOffer? {
        if let cedar = offers.first(where: { $0.program == .cedar && $0.usableNow && $0.isNext }) {
            return cedar
        }
        return offers.first(where: { $0.program == .juniper && $0.usableNow })
    }

    private static func cedarTitle(label: String?, clears: [String]) -> String {
        if let label, !label.isEmpty { return label }
        let session = clears.contains("five_hour")
        let weekly = clears.contains("seven_day") || clears.contains("seven_day_overage_included")
        if session && weekly { return "Full reset (weekly + session)" }
        if session { return "Session limit reset" }
        if weekly { return "Weekly limit reset" }
        return "Claude limit reset"
    }

    private static func isCedarGrantID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...40).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95 || byte == 45
        }
    }

    private static func listClaudeResets(accessToken: String) async -> ClaudeResetInventory? {
        async let anytime = probeClaudeUsage(
            accessToken: accessToken,
            query: "cedar_ember=1&skip_spend=1"
        )
        async let wall = probeClaudeUsage(
            accessToken: accessToken,
            query: "at_wall=1&skip_spend=1"
        )
        let anytimeProbe = await anytime
        let wallProbe = await wall
        let anytimeCedar = anytimeProbe.field("cedar_ember")
        let wallCedar = wallProbe.field("cedar_ember")
        let wallJuniper = wallProbe.field("juniper_tide")
        return preferClaudeResetInventory(
            anytime: parseClaudeResetInventory(
                cedarField: anytimeCedar.value,
                cedarReached: anytimeCedar.reached,
                juniperField: nil,
                juniperReached: false
            ),
            atWall: parseClaudeResetInventory(
                cedarField: wallCedar.value,
                cedarReached: wallCedar.reached,
                juniperField: wallJuniper.value,
                juniperReached: wallJuniper.reached
            )
        )
    }

    private struct ClaudeUsageProbe {
        var reached: Bool
        var json: [String: Any]?

        func field(_ name: String) -> (reached: Bool, value: [String: Any]?) {
            guard reached, let json else { return (false, nil) }
            guard let raw = json[name] else {
                if json["five_hour"] != nil || json["seven_day"] != nil { return (true, nil) }
                return (false, nil)
            }
            if raw is NSNull { return (true, nil) }
            guard let object = raw as? [String: Any] else { return (false, nil) }
            return (true, object)
        }
    }

    private static func probeClaudeUsage(
        accessToken: String,
        query: String
    ) async -> ClaudeUsageProbe {
        guard let url = URL(string: "\(claudeOAuthBase)/usage?\(query)") else {
            return ClaudeUsageProbe(reached: false, json: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyClaudeResetHeaders(to: &request, accessToken: accessToken, jsonBody: false)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return ClaudeUsageProbe(reached: false, json: nil) }
            return ClaudeUsageProbe(reached: true, json: json)
        } catch {
            return ClaudeUsageProbe(reached: false, json: nil)
        }
    }

    private static func redeemClaude(account: AuthAccount) async -> ResetResult {
        guard let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
              let accessToken = stringValue(payload, keys: ["access_token"])
        else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName)")
        }
        let email = stringValue(payload, keys: ["email"])
        guard let listing = await listClaudeResets(accessToken: accessToken) else {
            return .failure(message: "Could not reach Claude resets — check connection and retry (nothing was consumed).")
        }
        if listing.surfaceBlind && listing.offer == nil {
            return .failure(
                message: "This Claude reset is only available in the browser or Claude Desktop (Settings → Usage → Reset for free). Nothing was consumed."
            )
        }
        guard let offer = listing.offer else {
            if listing.bank.availableCount > 0 {
                return .failure(message: "Claude has a reset saved, but it can only be used once you hit a usage limit. Nothing was consumed.")
            }
            return .failure(message: "No Claude rate-limit reset to apply.")
        }
        guard let orgID = await claudeOrganizationID(accessToken: accessToken, accountEmail: email) else {
            return .failure(message: "Could not find this Claude account's organization — nothing was consumed.")
        }
        return await submitClaudeRedeem(offer: offer, orgID: orgID, accessToken: accessToken)
    }

    private static func submitClaudeRedeem(
        offer: ClaudeResetOffer,
        orgID: String,
        accessToken: String
    ) async -> ResetResult {
        let encodedOrg = orgID.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? orgID
        guard let url = URL(string: "\(claudeAPIBase)/api/organizations/\(encodedOrg)/reset_rate_limits") else {
            return .failure(message: "Invalid reset URL")
        }
        var body: [String: Any] = ["program": offer.program.rawValue]
        if offer.program == .cedar {
            body["grant_id"] = offer.id
            body["request_id"] = UUID().uuidString.lowercased()
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        applyClaudeResetHeaders(to: &request, accessToken: accessToken, jsonBody: true)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid reset response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(
                    message: "Claude session expired while applying the reset — re-authenticate and retry (the reset is still banked)."
                )
            }
            guard (200...299).contains(http.statusCode) else {
                let snippet = String(data: data.prefix(200), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                return .failure(message: "Could not apply Claude reset (HTTP \(http.statusCode)). \(snippet)")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let result = (json["result"] as? String)?.lowercased() ?? ""
            let cleared = stringList(json["cleared"])
            return claudeRedeemResult(result, program: offer.program, cleared: cleared)
        } catch {
            return .failure(message: "Reset request failed: \(error.localizedDescription)")
        }
    }

    static func claudeRedeemResult(
        _ result: String,
        program: ClaudeResetOffer.Program,
        cleared: [String]
    ) -> ResetResult {
        switch result {
        case "reset":
            if program == .juniper {
                return .success(message: "Reset Claude's session limit. Your weekly limit still applies.")
            }
            var line = "Applied Claude rate-limit reset"
            if let summary = claudeClearedSummary(cleared) { line += " · \(summary) cleared" }
            return .success(message: line + ".")
        case "not_limited":
            return .failure(message: "Claude didn't use the reset — you're not at a usage limit right now. Nothing was consumed.")
        case "already_used":
            return .failure(message: "That Claude reset was already used. Nothing changed.")
        case "cooldown":
            return .failure(message: "Another Claude reset just started. Try again in a minute (nothing new was consumed).")
        case "ineligible":
            return .failure(message: "This Claude reset isn't available anymore. Nothing was consumed.")
        case "rate_limited":
            return .failure(message: "Claude rate-limited the reset request. Try again in a moment (nothing was consumed).")
        case "auth_error":
            return .failure(message: "Claude rejected the reset — re-authenticate and retry (the reset is still banked).")
        default:
            return .failure(message: "Claude did not apply the reset\(result.isEmpty ? "" : " (\(result))"). Try again shortly.")
        }
    }

    private static func claudeClearedSummary(_ cleared: [String]) -> String? {
        var names: [String] = []
        for id in cleared {
            let name: String?
            switch id {
            case "five_hour": name = "session"
            case "seven_day", "seven_day_overage_included": name = "weekly"
            case "seven_day_opus": name = "Opus weekly"
            case "seven_day_sonnet": name = "Sonnet weekly"
            default: name = nil
            }
            if let name, !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " and ") + (names.count == 1 ? " limit" : " limits")
    }

    private static func claudeOrganizationID(accessToken: String, accountEmail: String?) async -> String? {
        if let id = await fetchClaudeProfileOrganization(accessToken: accessToken) { return id }
        return claudeJSONOrganizationID(matchingEmail: accountEmail)
    }

    private static func fetchClaudeProfileOrganization(accessToken: String) async -> String? {
        guard let url = URL(string: "\(claudeOAuthBase)/profile") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyClaudeResetHeaders(to: &request, accessToken: accessToken, jsonBody: false)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let org = json["organization"] as? [String: Any],
               let id = stringValue(org, keys: ["uuid", "id", "organization_uuid"])
            {
                return id
            }
            if let id = stringValue(json, keys: ["organization_uuid", "organizationUuid"]) { return id }
            if let account = json["account"] as? [String: Any],
               let id = stringValue(account, keys: ["organization_uuid", "organizationUuid"])
            {
                return id
            }
            return nil
        } catch {
            return nil
        }
    }

    /// `~/.claude.json` oauthAccount, only when it is this login.
    private static func claudeJSONOrganizationID(matchingEmail: String?) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let org = stringValue(oauth, keys: ["organizationUuid", "organization_uuid"])
        else { return nil }
        if let matchingEmail, !matchingEmail.isEmpty,
           let fileEmail = stringValue(oauth, keys: ["emailAddress", "email"]),
           fileEmail.caseInsensitiveCompare(matchingEmail) != .orderedSame
        {
            return nil
        }
        return org
    }

    private static func applyClaudeResetHeaders(
        to request: inout URLRequest,
        accessToken: String,
        jsonBody: Bool
    ) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue(claudeResetUserAgent, forHTTPHeaderField: "User-Agent")
        if jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    /// `~/.local/bin/claude` is a symlink whose last component is the version.
    private static func installedClaudeCodeVersion() -> String? {
        let link = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude")
        var path = link.path
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            path = dest.hasPrefix("/")
                ? dest
                : link.deletingLastPathComponent().appendingPathComponent(dest).path
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
        return name
    }

    private static func boolValue(_ json: [String: Any], key: String) -> Bool? {
        if let value = json[key] as? Bool { return value }
        if let number = json[key] as? NSNumber { return number.boolValue }
        return nil
    }

    private static func intValue(_ json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let number = json[key] as? NSNumber { return number.intValue }
            if let value = json[key] as? Int { return value }
        }
        return nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let raw = value as? [String] { return raw }
        if let raw = value as? [Any] { return raw.compactMap { $0 as? String } }
        return []
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    // MARK: - Shared helpers

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func chatgptAccountIDFromJWT(_ token: String?) -> String? {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return (auth["chatgpt_account_id"] as? String) ?? (auth["account_id"] as? String)
    }
}

extension Data {
    mutating func appendProtoVarint(_ value: Int) {
        var v = UInt64(value)
        while true {
            if v < 0x80 {
                append(UInt8(v))
                return
            }
            append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
    }
}
