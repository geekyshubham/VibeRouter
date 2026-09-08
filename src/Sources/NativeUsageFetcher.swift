import Foundation

enum NativeUsageFetcher {
    static func fetchUsage(
        for serviceType: ServiceType,
        authFile: URL,
        authAccountID: String
    ) async -> ProviderUsageSnapshot {
        let providerID = serviceType.usageProviderID ?? serviceType.rawValue

        guard var payload = readAuthPayload(at: authFile) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not read auth credentials")
        }

        payload = enrichPayload(payload, for: serviceType)

        switch serviceType {
        case .codex:
            return await fetchCodexUsage(
                authAccountID: authAccountID,
                providerID: providerID,
                payload: payload,
                authFile: authFile
            )
        case .claude:
            return await fetchClaudeUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .copilot:
            return await fetchCopilotUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .gemini:
            return await fetchGeminiUsage(
                authAccountID: authAccountID,
                providerID: providerID,
                payload: payload,
                authFile: authFile
            )
        case .antigravity:
            return await fetchAntigravityUsage(
                authAccountID: authAccountID,
                providerID: providerID,
                payload: payload,
                authFile: authFile
            )
        case .grok:
            return await fetchGrokUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .kiro:
            return await fetchKiroUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .opencodeGo:
            return await fetchOpenCodeGoUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .zai:
            return await fetchZaiUsage(authAccountID: authAccountID, providerID: providerID, payload: payload)
        case .kimi:
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                error: "Live usage limits are not available for Kimi yet"
            )
        case .cursor:
            return await fetchCursorUsage(
                authAccountID: authAccountID,
                providerID: providerID,
                payload: payload,
                authFile: authFile
            )
        case .qwen, .codebuddy, .gitlab, .kilo:
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: stringValue(payload, keys: ["email", "username", "login"]),
                error: nil
            )
        }
    }

    static func fetchCost(for serviceType: ServiceType) async -> ProviderCostSnapshot? {
        await Task.detached(priority: .utility) {
            LocalTokenCostScanner.snapshot(for: serviceType)
        }.value
    }

    /// Prefer refresh-aware messaging: short-lived access tokens are not a full logout.
    private static func sessionInvalidMessage(
        payload: [String: Any],
        reauthHint: String = "re-authenticate in Settings"
    ) -> String {
        let hasRefresh = stringValue(payload, keys: ["refresh_token", "refreshToken", "refresh"]) != nil
        if hasRefresh {
            return "Access token is refreshing — try again in a moment (no re-login needed)"
        }
        return "Session expired — \(reauthHint)"
    }

    // MARK: - Codex

    private static func fetchCodexUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any],
        authFile: URL
    ) async -> ProviderUsageSnapshot {
        var payload = loadCodexPayload(seed: payload, authFile: authFile)

        if TokenRefreshService.shouldRefresh(payload: payload) {
            _ = await TokenRefreshService.refreshAccountFile(authFile)
            payload = loadCodexPayload(seed: payload, authFile: authFile)
        }

        let snapshot = await fetchCodexUsageOnce(
            authAccountID: authAccountID,
            providerID: providerID,
            payload: payload
        )
        if codexSnapshotHasLimits(snapshot) { return snapshot }

        // CLI/desktop may have rotated while we used a stale cli-proxy copy.
        let before = stringValue(payload, keys: ["access_token"])
        payload = loadCodexPayload(seed: payload, authFile: authFile)
        if stringValue(payload, keys: ["access_token"]) != before {
            let retried = await fetchCodexUsageOnce(
                authAccountID: authAccountID,
                providerID: providerID,
                payload: payload
            )
            if codexSnapshotHasLimits(retried) { return retried }
        }

        let authRejected = (snapshot.errorMessage ?? "")
            .localizedCaseInsensitiveContains("expired")
            || (snapshot.errorMessage ?? "")
                .localizedCaseInsensitiveContains("refreshing")
        if TokenRefreshService.shouldRefresh(payload: payload)
            || isOAuthAccessExpired(payload)
            || authRejected
        {
            _ = await TokenRefreshService.refreshAccountFile(authFile, force: authRejected)
            payload = loadCodexPayload(seed: payload, authFile: authFile)
            return await fetchCodexUsageOnce(
                authAccountID: authAccountID,
                providerID: providerID,
                payload: payload
            )
        }

        if snapshot.errorMessage == nil || snapshot.errorMessage?.isEmpty == true {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: stringValue(payload, keys: ["email"]),
                error: sessionInvalidMessage(payload: payload)
            )
        }
        return snapshot
    }

    private static func loadCodexPayload(seed: [String: Any], authFile: URL) -> [String: Any] {
        _ = overlayCodexCLICredentialsIfFresher(onto: authFile)
        if let latest = readAuthPayload(at: authFile) {
            return TokenRefreshService.flattenedAuth(enrichPayload(latest, for: .codex))
        }
        return TokenRefreshService.flattenedAuth(enrichPayload(seed, for: .codex))
    }

    private static func codexSnapshotHasLimits(_ snapshot: ProviderUsageSnapshot) -> Bool {
        !snapshot.windows.isEmpty || snapshot.subAccounts.contains { !$0.windows.isEmpty }
    }

    private static func isOAuthAccessExpired(_ payload: [String: Any], now: Date = Date()) -> Bool {
        let flat = TokenRefreshService.flattenedAuth(payload)
        if let token = stringValue(flat, keys: ["access_token", "accessToken"]),
           let exp = CodexWorkspaceCredentials.accessTokenExpiry(token)
        {
            return exp <= now
        }
        return false
    }

    private static func fetchCodexUsageOnce(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let jwtAccountID = chatgptAccountIDFromJWT(accessToken)
            ?? chatgptAccountIDFromJWT(stringValue(payload, keys: ["id_token"]))
        let storedAccountID = stringValue(payload, keys: ["account_id"])
            ?? jwtAccountID
        let email = stringValue(payload, keys: ["email"])
            ?? JWTEmailExtractor.email(from: stringValue(payload, keys: ["id_token"]))
            ?? JWTEmailExtractor.email(from: accessToken)
        let jwtPlan = chatgptPlanTypeFromJWT(accessToken)
            ?? chatgptPlanTypeFromJWT(stringValue(payload, keys: ["id_token"]))
        var sawUnauthorized = false

        // Seat-scoped token lineages (Cockpit keeps one OAuth session per ChatGPT account_id).
        // A Go JWT + ChatGPT-Account-Id:team still returns Go limits — wrong token, not wrong header.
        let seatTokens = CodexWorkspaceCredentials.allSeats(seed: payload, email: email)
        let seatByID: [String: CodexWorkspaceCredentials.Payload] = Dictionary(
            seatTokens.map { ($0.accountID.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Memberships are only for labels / optional multi-sub discovery.
        let memberships = await fetchChatGPTAccountMemberships(accessToken: accessToken)

        // IMPORTANT: This auth *file* is one seat (JWT account_id). Do not paint every
        // membership as a sub-row on every duplicate file — that made two shubham rows both
        // show Go+Team and the wrong plan chip. Scope targets to this file's seat when known.
        let thisSeatID = (jwtAccountID ?? storedAccountID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targets: [CodexUsageTarget]
        if let thisSeatID, !thisSeatID.isEmpty {
            let membership = memberships.first {
                ($0.accountID ?? "").caseInsensitiveCompare(thisSeatID) == .orderedSame
            }
            targets = [
                CodexUsageTarget(
                    accountID: thisSeatID,
                    planType: membership?.planType ?? jwtPlan,
                    workspaceName: membership?.workspaceName,
                    structure: membership?.structure,
                    role: membership?.role
                )
            ]
        } else {
            targets = codexUsageTargets(
                memberships: memberships,
                storedAccountID: storedAccountID,
                jwtPlan: jwtPlan,
                knownSeatIDs: seatTokens.map(\.accountID)
            )
        }

        var subAccounts: [ProviderUsageSubAccount] = []
        for target in targets {
            let targetID = target.accountID
            let seat = targetID.flatMap { seatByID[$0.lowercased()] }
            // Only use a token whose JWT is for this seat (or seed when seat is unknown).
            let tokenForSeat: String? = {
                if let seat { return seat.accessToken }
                if let targetID, let jwtAccountID,
                   targetID.caseInsensitiveCompare(jwtAccountID) == .orderedSame
                {
                    return accessToken
                }
                if targetID == nil { return accessToken }
                return nil
            }()
            let seatJWTPlan = seat.flatMap { CodexWorkspaceCredentials.chatgptPlanType(from: $0.accessToken) }
                ?? (tokenForSeat == accessToken ? jwtPlan : nil)

            var usageResult: CodexUsageRequestResult = .failed
            if let tokenForSeat {
                usageResult = await requestCodexUsagePayload(
                    accessToken: tokenForSeat,
                    chatGPTAccountID: targetID ?? seat?.accountID
                )
            }
            if case .ok(let result) = usageResult {
                // Reject cross-seat bleed: if we asked for team but body still says go with go windows
                // and membership is team, keep membership plan label from accounts/check.
                let planType = ChatGPTPlanFormatter.preferredPlanType(
                    usagePlan: result.planType,
                    membershipPlan: target.planType ?? seat?.planType,
                    jwtPlan: seatJWTPlan,
                    structure: target.structure,
                    workspaceName: target.workspaceName
                )
                let title = ChatGPTPlanFormatter.subscriptionTitle(
                    planType: planType,
                    workspaceName: target.workspaceName,
                    structure: target.structure
                )
                // If usage plan clearly mismatches a higher membership (e.g. go body for team seat)
                // and we only had a wrong-token fallback, surface that rather than Go limits as Team.
                let usageLooksWrongSeat = usagePlanMismatchesMembership(
                    usagePlan: result.planType,
                    membershipPlan: target.planType,
                    structure: target.structure
                )
                if usageLooksWrongSeat, seat == nil {
                    subAccounts.append(
                        ProviderUsageSubAccount(
                            id: targetID ?? title,
                            title: title,
                            subtitle: codexMembershipSubtitle(structure: target.structure, role: target.role, planType: planType),
                            planType: planType,
                            windows: [],
                            errorMessage: "No OAuth session for this seat — re-login with this workspace selected (or import from Cockpit)"
                        )
                    )
                } else {
                    subAccounts.append(
                        ProviderUsageSubAccount(
                            id: targetID ?? title,
                            title: title,
                            subtitle: codexMembershipSubtitle(structure: target.structure, role: target.role, planType: planType),
                            planType: planType,
                            windows: result.windows.map(enrichResetDescription),
                            errorMessage: nil
                        )
                    )
                }
            } else {
                if case .unauthorized = usageResult { sawUnauthorized = true }
                let planType = ChatGPTPlanFormatter.preferredPlanType(
                    usagePlan: nil,
                    membershipPlan: target.planType ?? seat?.planType,
                    jwtPlan: seatJWTPlan,
                    structure: target.structure,
                    workspaceName: target.workspaceName
                )
                let title = ChatGPTPlanFormatter.subscriptionTitle(
                    planType: planType,
                    workspaceName: target.workspaceName,
                    structure: target.structure
                )
                let err: String
                if seat == nil,
                   let targetID,
                   jwtAccountID?.caseInsensitiveCompare(targetID) != .orderedSame
                {
                    err = "No OAuth session for this seat — re-login with this workspace selected (or import from Cockpit)"
                } else if sawUnauthorized {
                    err = sessionInvalidMessage(payload: payload)
                } else {
                    err = "Could not load limits for this subscription"
                }
                subAccounts.append(
                    ProviderUsageSubAccount(
                        id: targetID ?? title,
                        title: title,
                        subtitle: codexMembershipSubtitle(structure: target.structure, role: target.role, planType: planType),
                        planType: planType,
                        windows: [],
                        errorMessage: err
                    )
                )
            }
        }

        // Flexible rate-limit reset inventory (Cockpit/CodexBar: rate-limit-reset-credits).
        // Fetch for the primary account id so the card can show "N resets left".
        let primaryAccountID = subAccounts.first(where: { !$0.windows.isEmpty })?.id
            ?? storedAccountID
        let resetCredits = await fetchCodexRateLimitResetCredits(
            accessToken: accessToken,
            chatGPTAccountID: primaryAccountID == email ? storedAccountID : (primaryAccountID ?? storedAccountID)
        )

        // Prefer showing every discovered subscription when there are 2+ memberships.
        if subAccounts.count >= 2 {
            // Prefer highest plan rank with data as the collapsed "primary" strip.
            let primary = subAccounts
                .filter { !$0.windows.isEmpty }
                .max(by: { planRank($0.planType) < planRank($1.planType) })
                ?? subAccounts[0]
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "OpenAI OAuth",
                windows: primary.windows,
                subAccounts: subAccounts,
                accountEmail: email,
                planType: primary.planType,
                planLabel: primary.title,
                rateLimitResets: resetCredits,
                updatedAt: Date(),
                errorMessage: subAccounts.allSatisfy({ $0.windows.isEmpty })
                    ? (sawUnauthorized
                        ? sessionInvalidMessage(payload: payload)
                        : "Could not fetch Codex usage limits")
                    : nil,
                isRefreshing: false
            )
        }

        if let only = subAccounts.first, !only.windows.isEmpty {
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "OpenAI OAuth",
                windows: only.windows,
                subAccounts: [],
                accountEmail: email,
                planType: only.planType,
                planLabel: only.title,
                rateLimitResets: resetCredits,
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        }

        // Fallback: direct usage call without memberships list.
        let fallback = await requestCodexUsagePayload(
            accessToken: accessToken,
            chatGPTAccountID: storedAccountID
        )
        if case .ok(let result) = fallback, !result.windows.isEmpty {
            let planType = ChatGPTPlanFormatter.preferredPlanType(
                usagePlan: result.planType,
                membershipPlan: nil,
                jwtPlan: jwtPlan,
                structure: nil,
                workspaceName: nil
            )
            let resets: CodexRateLimitResetCredits?
            if let resetCredits {
                resets = resetCredits
            } else {
                resets = await fetchCodexRateLimitResetCredits(
                    accessToken: accessToken,
                    chatGPTAccountID: storedAccountID
                )
            }
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "OpenAI OAuth",
                windows: result.windows.map(enrichResetDescription),
                subAccounts: [],
                accountEmail: email,
                planType: planType,
                planLabel: ChatGPTPlanFormatter.displayName(for: planType),
                rateLimitResets: resets,
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        }

        if case .unauthorized = fallback {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: email,
                error: sessionInvalidMessage(payload: payload)
            )
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: email,
            error: "Could not fetch Codex usage limits"
        )
    }

    struct CodexResetCredit: Equatable {
        let id: String
        let expiresAt: Date?
        let title: String?
    }

    /// `GET …/wham/rate-limit-reset-credits` — available "Full reset" credits
    /// (with IDs so RateLimitResetService can redeem one).
    /// Returns `nil` when the endpoint is unreachable/rejects (vs `[]` for a
    /// genuine empty inventory) so callers never paint a false "no resets left".
    static func fetchCodexAvailableResets(
        accessToken: String,
        chatGPTAccountID: String?
    ) async -> [CodexResetCredit]? {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        if let chatGPTAccountID, !chatGPTAccountID.isEmpty {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return parseCodexCredits(json: json)
        } catch {
            return nil
        }
    }

    /// Pure credits parsing (unit-testable): status=available and not expired.
    static func parseCodexCredits(json: [String: Any], now: Date = Date()) -> [CodexResetCredit] {
        let rawCredits = json["credits"] as? [[String: Any]] ?? []
        var available: [CodexResetCredit] = []
        for credit in rawCredits {
            let status = (stringValue(credit, keys: ["status"]) ?? "").lowercased()
            guard status == "available" else { continue }
            let expires = parseISO8601(stringValue(credit, keys: ["expires_at", "expiresAt"]))
            if let expires, expires <= now { continue }
            available.append(
                CodexResetCredit(
                    id: stringValue(credit, keys: ["id", "credit_id", "creditId"]) ?? "",
                    expiresAt: expires,
                    title: stringValue(credit, keys: ["title"])
                )
            )
        }
        return available
    }

    private static func fetchCodexRateLimitResetCredits(
        accessToken: String,
        chatGPTAccountID: String?
    ) async -> CodexRateLimitResetCredits? {
        guard let credits = await fetchCodexAvailableResets(
            accessToken: accessToken,
            chatGPTAccountID: chatGPTAccountID
        ) else {
            return nil
        }
        // Prefer inventory we validated (status=available & not expired).
        let next = credits.compactMap(\.expiresAt).sorted().first
        let title = credits.first(where: { $0.expiresAt == next })?.title
            ?? credits.first?.title
        return RateLimitResetBank(
            availableCount: credits.count,
            nextExpiresAt: next,
            sampleTitle: title,
            canRedeem: true
        )
    }

    private struct CodexUsageTarget {
        let accountID: String?
        let planType: String?
        let workspaceName: String?
        let structure: String?
        let role: String?
    }

    private struct CodexUsagePayload {
        let windows: [RateWindow]
        let planType: String?
    }

    private static func codexUsageTargets(
        memberships: [CodexUsageTarget],
        storedAccountID: String?,
        jwtPlan: String?,
        knownSeatIDs: [String] = []
    ) -> [CodexUsageTarget] {
        if !memberships.isEmpty {
            let paid = memberships.filter { ($0.planType ?? "").lowercased() != "free" }
            // Show every paid/subscription membership; fall back to all if only free exists.
            let preferred = paid.isEmpty ? memberships : paid
            // Stable order: non-free first, then by title-ish fields.
            return preferred.sorted { lhs, rhs in
                let lFree = (lhs.planType ?? "").lowercased() == "free"
                let rFree = (rhs.planType ?? "").lowercased() == "free"
                if lFree != rFree { return !lFree && rFree }
                return (lhs.workspaceName ?? lhs.planType ?? "") < (rhs.workspaceName ?? rhs.planType ?? "")
            }
        }

        // Memberships list unavailable — still surface known seat token lineages (e.g. Cockpit).
        if !knownSeatIDs.isEmpty {
            return knownSeatIDs.map { id in
                CodexUsageTarget(
                    accountID: id,
                    planType: nil,
                    workspaceName: nil,
                    structure: nil,
                    role: nil
                )
            }
        }

        return [
            CodexUsageTarget(
                accountID: storedAccountID,
                planType: jwtPlan,
                workspaceName: nil,
                structure: nil,
                role: nil
            )
        ]
    }

    /// True when usage body plan is clearly the personal/default seat while membership says Team/Enterprise.
    private static func usagePlanMismatchesMembership(
        usagePlan: String?,
        membershipPlan: String?,
        structure: String?
    ) -> Bool {
        let usage = (usagePlan ?? "").lowercased()
        let membership = (membershipPlan ?? "").lowercased()
        let structLower = (structure ?? "").lowercased()
        let membershipIsWorkspace = membership == "team"
            || membership == "enterprise"
            || membership == "business"
            || structLower == "workspace"
        let usageIsPersonal = usage == "go" || usage == "free" || usage == "plus"
        return membershipIsWorkspace && usageIsPersonal
    }

    private static func codexMembershipSubtitle(structure: String?, role: String?, planType: String?) -> String? {
        var parts: [String] = []
        if let structure, !structure.isEmpty {
            parts.append(structure.capitalized)
        }
        if let role, !role.isEmpty {
            let cleaned = role.replacingOccurrences(of: "-", with: " ")
            parts.append(cleaned.capitalized)
        }
        // Clarify when JWT would have said Go but we resolved a higher tier.
        if let planType, planType.lowercased() != "go", planType.lowercased() != "free" {
            // title already has plan; keep subtitle structural
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func planRank(_ plan: String?) -> Int {
        guard let plan else { return 0 }
        switch plan.lowercased() {
        case "enterprise": return 100
        case "business": return 90
        case "team": return 80
        case "edu", "education": return 70
        case "pro": return 60
        case "prolite": return 55
        case "plus": return 50
        case "go": return 40
        case "free": return 10
        default: return 20
        }
    }

    private static func enrichResetDescription(_ window: RateWindow) -> RateWindow {
        guard let resetsAt = window.resetsAt else { return window }
        return RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: window.windowMinutes,
            resetsAt: resetsAt,
            resetDescription: ResetCountdownFormatter.resetLine(for: resetsAt),
            label: window.label,
            remainingValue: window.remainingValue,
            totalValue: window.totalValue,
            unitLabel: window.unitLabel,
            displayStyle: window.displayStyle
        )
    }

    private static func fetchChatGPTAccountMemberships(accessToken: String) async -> [CodexUsageTarget] {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/accounts/check") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return []
            }

            // accounts may be array or dict-of-accounts depending on backend version.
            let accounts: [[String: Any]]
            if let array = json["accounts"] as? [[String: Any]] {
                accounts = array
            } else if let dict = json["accounts"] as? [String: [String: Any]] {
                accounts = Array(dict.values)
            } else if let items = json["items"] as? [[String: Any]] {
                accounts = items
            } else {
                return []
            }

            return accounts.compactMap { entry -> CodexUsageTarget? in
                parseMembershipEntry(entry)
            }
        } catch {
            return []
        }
    }

    private static func parseMembershipEntry(_ entry: [String: Any]) -> CodexUsageTarget? {
        // Nested shapes: { account: { id, plan_type, … } } or flat.
        let nested = entry["account"] as? [String: Any]
        let org = entry["organization"] as? [String: Any]
            ?? nested?["organization"] as? [String: Any]

        let id = stringValue(entry, keys: ["id", "account_id", "chatgpt_account_id"])
            ?? stringValue(nested ?? [:], keys: ["id", "account_id", "chatgpt_account_id"])
        guard let id, !id.isEmpty else { return nil }

        let planType = stringValue(entry, keys: ["plan_type", "chatgpt_plan_type", "plan"])
            ?? stringValue(nested ?? [:], keys: ["plan_type", "chatgpt_plan_type", "plan"])
            ?? stringValue(org ?? [:], keys: ["plan_type", "chatgpt_plan_type", "plan"])

        let workspaceName = stringValue(entry, keys: ["name", "organization_name", "workspace_name", "display_name"])
            ?? stringValue(nested ?? [:], keys: ["name", "organization_name", "workspace_name", "display_name"])
            ?? stringValue(org ?? [:], keys: ["name", "title", "display_name"])

        let structure = stringValue(entry, keys: ["structure", "account_structure", "kind", "account_type"])
            ?? stringValue(nested ?? [:], keys: ["structure", "account_structure", "kind", "account_type"])

        let role = stringValue(entry, keys: ["account_user_role", "role", "user_role"])
            ?? stringValue(nested ?? [:], keys: ["account_user_role", "role"])

        return CodexUsageTarget(
            accountID: id,
            planType: ChatGPTPlanFormatter.normalizePlanType(
                planType,
                structure: structure,
                workspaceName: workspaceName
            ),
            workspaceName: workspaceName,
            structure: structure,
            role: role
        )
    }

    private enum CodexUsageRequestResult {
        case ok(CodexUsagePayload)
        case unauthorized
        case failed
    }

    private static func requestCodexUsagePayload(
        accessToken: String,
        chatGPTAccountID: String?
    ) async -> CodexUsageRequestResult {
        let endpoints = [
            "https://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/backend-api/api/codex/usage",
        ]

        var sawUnauthorized = false
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            switch await requestCodexUsagePayload(
                url: url,
                accessToken: accessToken,
                chatGPTAccountID: chatGPTAccountID
            ) {
            case .ok(let payload):
                return .ok(payload)
            case .unauthorized:
                sawUnauthorized = true
            case .failed:
                continue
            }
        }
        return sawUnauthorized ? .unauthorized : .failed
    }

    private static func requestCodexUsagePayload(
        url: URL,
        accessToken: String,
        chatGPTAccountID: String?
    ) async -> CodexUsageRequestResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let chatGPTAccountID, !chatGPTAccountID.isEmpty {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unauthorized
            }
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .failed
            }

            let rateLimit = json["rate_limit"] as? [String: Any]
            let codeReview = json["code_review_rate_limit"] as? [String: Any]
            var windows: [RateWindow] = []
            if let rateLimit {
                // Primary/secondary labels come from limit_window_seconds (Go plan primary can be monthly).
                if let primary = mapCodexWindow(rateLimit["primary_window"] as? [String: Any], role: .primary) {
                    windows.append(primary)
                }
                if let secondary = mapCodexWindow(rateLimit["secondary_window"] as? [String: Any], role: .secondary) {
                    windows.append(secondary)
                }
            }
            if let codeReview {
                if let primary = mapCodexWindow(codeReview["primary_window"] as? [String: Any], role: .codeReview) {
                    windows.append(primary)
                }
            }
            // Model-specific limits (CodexBar: additional_rate_limits).
            if let extras = json["additional_rate_limits"] as? [[String: Any]] {
                for extra in extras {
                    let name = stringValue(extra, keys: ["limit_name", "metered_feature"]) ?? "Extra limit"
                    let nested = extra["rate_limit"] as? [String: Any]
                    if let primary = mapCodexWindow(nested?["primary_window"] as? [String: Any], role: .named(name)) {
                        windows.append(primary)
                    }
                    if let secondary = mapCodexWindow(nested?["secondary_window"] as? [String: Any], role: .named("\(name) · weekly")) {
                        windows.append(secondary)
                    }
                }
            }

            guard !windows.isEmpty else { return .failed }
            return .ok(CodexUsagePayload(
                windows: windows,
                planType: stringValue(json, keys: ["plan_type"])
            ))
        } catch {
            return .failed
        }
    }

    private enum CodexWindowRole {
        case primary
        case secondary
        case codeReview
        case named(String)
    }

    /// Codex/ChatGPT `used_percent` is **used** (0–100), matching CodexBar + Cockpit.
    /// Labels must follow `limit_window_seconds` — ChatGPT Go's primary window is often **monthly**, not 5h.
    private static func mapCodexWindow(_ window: [String: Any]?, role: CodexWindowRole) -> RateWindow? {
        guard let window else { return nil }
        // Skip JSON null windows.
        if window.isEmpty { return nil }

        let usedPercent = clampPercent(doubleValue(window, keys: ["used_percent"]) ?? 0)
        let resetAt = intValue(window, keys: ["reset_at"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? intValue(window, keys: ["reset_after_seconds"]).map { Date().addingTimeInterval(TimeInterval($0)) }
        let windowSeconds = intValue(window, keys: ["limit_window_seconds"]) ?? 0
        let minutes = windowSeconds > 0 ? max(1, (windowSeconds + 59) / 60) : nil
        let label = codexWindowLabel(seconds: windowSeconds, role: role)
        let resetDescription = resetAt.map { ResetCountdownFormatter.resetLine(for: $0) }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: minutes,
            resetsAt: resetAt,
            resetDescription: resetDescription,
            label: label
        )
    }

    private static func codexWindowLabel(seconds: Int, role: CodexWindowRole) -> String {
        if case .codeReview = role { return "Code review" }
        if case .named(let name) = role, seconds <= 0 { return name }

        // Duration-first (source of truth).
        if seconds > 0 {
            let hours = Double(seconds) / 3600.0
            if hours <= 6 {
                let h = max(1, Int(hours.rounded()))
                let base = "Session (\(h)h)"
                if case .named(let name) = role { return "\(name) · \(base)" }
                return base
            }
            let days = hours / 24.0
            if days <= 8 {
                if case .named(let name) = role { return "\(name) · Weekly" }
                return "Weekly"
            }
            if days <= 40 {
                if case .named(let name) = role { return "\(name) · Monthly" }
                return "Monthly"
            }
        }

        // Role fallback when duration missing.
        switch role {
        case .primary: return "Session"
        case .secondary: return "Weekly"
        case .codeReview: return "Code review"
        case .named(let name): return name
        }
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func chatgptAccountIDFromJWT(_ token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_account_id", "account_id"])
    }

    private static func chatgptPlanTypeFromJWT(_ token: String?) -> String? {
        guard let auth = openAIAuthClaims(from: token) else { return nil }
        return stringValue(auth, keys: ["chatgpt_plan_type"])
    }

    private static func openAIAuthClaims(from token: String?) -> [String: Any]? {
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

    // MARK: - Z.AI GLM Coding Plan

    /// Fetches Coding Plan quota from the same monitor API used by ZCode / z.ai dashboard.
    /// Endpoint: `GET https://api.z.ai/api/monitor/usage/quota/limit`
    private static func fetchZaiUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let apiKey = stringValue(payload, keys: ["api_key", "apiKey", "key", "access_token"]) else {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: stringValue(payload, keys: ["email"]),
                error: "Missing Z.AI API key"
            )
        }

        let label = stringValue(payload, keys: ["email", "label"]) ?? maskAPIKey(apiKey)
        let endpoints = [
            "https://api.z.ai/api/monitor/usage/quota/limit",
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
        ]

        for endpoint in endpoints {
            if let snapshot = await requestZaiQuota(
                endpoint: endpoint,
                apiKey: apiKey,
                authAccountID: authAccountID,
                providerID: providerID,
                accountLabel: label
            ) {
                return snapshot
            }
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: label,
            error: "Could not fetch Z.AI Coding Plan limits"
        )
    }

    private static func requestZaiQuota(
        endpoint: String,
        apiKey: String,
        authAccountID: String,
        providerID: String,
        accountLabel: String
    ) async -> ProviderUsageSnapshot? {
        guard let url = URL(string: endpoint) else { return nil }

        // Z.AI accepts both `Bearer <key>` and raw key Authorization styles.
        for authorization in ["Bearer \(apiKey)", apiKey] {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
            request.setValue("VibeRouter/1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .empty(
                        authAccountID: authAccountID,
                        providerID: providerID,
                        accountEmail: accountLabel,
                        error: "Z.AI API key rejected — check the key in Settings"
                    )
                }
                guard (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // Success envelope: { success, code, data: { limits, level } }
                let success = (json["success"] as? Bool) ?? ((json["code"] as? Int) == 200)
                guard success else { continue }

                let dataObj = json["data"] as? [String: Any] ?? json
                let limits = dataObj["limits"] as? [[String: Any]] ?? []
                let level = stringValue(dataObj, keys: ["level", "plan", "planType", "plan_type"])
                let planLabel = zaiPlanDisplayName(level)

                let windows = mapZaiQuotaLimits(limits)
                guard !windows.isEmpty else {
                    return .empty(
                        authAccountID: authAccountID,
                        providerID: providerID,
                        accountEmail: accountLabel,
                        error: "No Z.AI quota windows reported for this key"
                    )
                }

                let sourceHost = url.host?.contains("bigmodel") == true ? "BigModel" : "Z.AI"
                return ProviderUsageSnapshot(
                    id: authAccountID,
                    providerID: providerID,
                    source: "\(sourceHost) Coding Plan",
                    windows: windows,
                    subAccounts: [],
                    accountEmail: accountLabel,
                    planType: level,
                    planLabel: planLabel,
                    updatedAt: Date(),
                    errorMessage: nil,
                    isRefreshing: false
                )
            } catch {
                continue
            }
        }
        return nil
    }

    /// Maps Z.AI monitor limit rows into labeled RateWindows.
    /// unit 3 + TOKENS_LIMIT → 5-hour prompt/token window
    /// unit 6 + TOKENS_LIMIT → weekly window
    /// TIME_LIMIT → MCP tools (monthly)
    static func mapZaiQuotaLimits(_ limits: [[String: Any]]) -> [RateWindow] {
        var fiveHour: RateWindow?
        var weekly: RateWindow?
        var mcp: RateWindow?
        var extras: [RateWindow] = []

        for limit in limits {
            let type = (stringValue(limit, keys: ["type"]) ?? "").uppercased()
            let unit = intValue(limit, keys: ["unit"]) ?? 0
            let number = intValue(limit, keys: ["number"]) ?? 0
            // Z.AI `percentage` is **used** 0–100 (paired with `remaining` on some rows).
            let usedPercent = clampPercent(doubleValue(limit, keys: ["percentage"]) ?? 0)
            let resetsAt = intValue(limit, keys: ["nextResetTime"]).map { millis -> Date in
                // Values can be ms or seconds; treat large numbers as ms.
                if millis > 10_000_000_000 {
                    return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
                }
                return Date(timeIntervalSince1970: TimeInterval(millis))
            }

            if type == "TOKENS_LIMIT" && unit == 3 && number == 5 {
                fiveHour = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 5 * 60,
                    resetsAt: resetsAt,
                    resetDescription: nil,
                    label: "5-hour"
                )
            } else if type == "TOKENS_LIMIT" && unit == 6 {
                weekly = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: resetsAt,
                    resetDescription: nil,
                    label: "Weekly"
                )
            } else if type == "TIME_LIMIT" {
                mcp = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 30 * 24 * 60,
                    resetsAt: resetsAt,
                    resetDescription: nil,
                    label: "MCP (monthly)"
                )
            } else {
                let label: String
                if type == "TOKENS_LIMIT" {
                    label = "Tokens (\(number)\(unitLabel(unit)))"
                } else if !type.isEmpty {
                    label = type.replacingOccurrences(of: "_", with: " ").capitalized
                } else {
                    label = "Quota"
                }
                extras.append(
                    RateWindow(
                        usedPercent: usedPercent,
                        windowMinutes: nil,
                        resetsAt: resetsAt,
                        resetDescription: nil,
                        label: label
                    )
                )
            }
        }

        return [fiveHour, weekly, mcp].compactMap { $0 } + extras
    }

    private static func unitLabel(_ unit: Int) -> String {
        switch unit {
        case 3: return "h"
        case 5: return "mo"
        case 6: return "w"
        default: return ""
        }
    }

    private static func zaiPlanDisplayName(_ level: String?) -> String? {
        guard let level, !level.isEmpty else { return nil }
        switch level.lowercased() {
        case "lite": return "Coding Plan Lite"
        case "pro": return "Coding Plan Pro"
        case "max": return "Coding Plan Max"
        default: return "Coding Plan \(level.capitalized)"
        }
    }

    private static func maskAPIKey(_ apiKey: String) -> String {
        guard apiKey.count > 12 else { return apiKey }
        return String(apiKey.prefix(8)) + "…" + String(apiKey.suffix(4))
    }

    // MARK: - Claude

    private static func fetchClaudeUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let email = stringValue(payload, keys: ["email"])
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(payload: payload)
                )
            }
            if http.statusCode == 429 {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Rate limited — try again shortly")
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Usage API returned HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse usage response")
            }

            let primary = mapClaudeWindow(json["five_hour"] as? [String: Any], defaultMinutes: 300, label: "5-hour")
            let secondary = mapClaudeWindow(json["seven_day"] as? [String: Any], defaultMinutes: 10_080, label: "Weekly")
            let sevenDaySonnet = mapClaudeWindow(
                json["seven_day_sonnet"] as? [String: Any],
                defaultMinutes: 10_080,
                label: "Weekly (Sonnet)"
            )
            let sevenDayOpus = mapClaudeWindow(
                json["seven_day_opus"] as? [String: Any],
                defaultMinutes: 10_080,
                label: "Weekly (Opus)"
            )
            let windows = [primary, secondary, sevenDayOpus, sevenDaySonnet].compactMap { $0 }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "Claude OAuth",
                windows: windows,
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota windows reported" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    private static func mapClaudeWindow(_ window: [String: Any]?, defaultMinutes: Int, label: String) -> RateWindow? {
        guard let window else { return nil }
        // Claude OAuth/web `utilization` is **used** percent 0–100 (CodexBar).
        let utilization = clampPercent(doubleValue(window, keys: ["utilization"]) ?? 0)
        let resetsAt = parseISO8601(stringValue(window, keys: ["resets_at"]))
        return RateWindow(
            usedPercent: utilization,
            windowMinutes: defaultMinutes,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
            label: label
        )
    }

    // MARK: - Cursor

    private static func fetchCursorUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any],
        authFile: URL
    ) async -> ProviderUsageSnapshot {
        var payload = payload
        if TokenRefreshService.shouldRefresh(payload: payload) {
            _ = await TokenRefreshService.refreshAccountFile(authFile)
            payload = readAuthPayload(at: authFile) ?? payload
        }

        guard let accessToken = stringValue(payload, keys: ["access_token", "accessToken"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let email = stringValue(payload, keys: ["email", "cachedEmail"])
            ?? JWTEmailExtractor.email(from: accessToken)
        let membership = await fetchCursorStripeMembership(accessToken: accessToken)
            ?? stringValue(payload, keys: ["membership_type", "plan_type", "plan"])
        let planLabel = cursorPlanLabel(membership)

        guard let cookie = cursorSessionCookie(accessToken: accessToken),
              let url = URL(string: "https://cursor.com/api/usage-summary")
        else {
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "Cursor OAuth",
                windows: [],
                accountEmail: email,
                planType: membership,
                planLabel: planLabel,
                updatedAt: Date(),
                errorMessage: "Could not build Cursor session cookie from this token",
                isRefreshing: false
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cursor-agent/2026.07.07", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accountEmail: email,
                    error: sessionInvalidMessage(payload: payload, reauthHint: "re-import the Cursor token in Settings")
                )
            }
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accountEmail: email,
                    error: "Cursor usage API returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
            }

            let membershipFromUsage = stringValue(json, keys: ["membershipType", "membership_type"]) ?? membership
            let windows = CursorQuotaParser.windows(from: json)
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "Cursor OAuth",
                windows: windows,
                accountEmail: email,
                planType: membershipFromUsage,
                planLabel: cursorPlanLabel(membershipFromUsage),
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No Cursor quota data for this plan" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: email,
                error: error.localizedDescription
            )
        }
    }

    private static func fetchCursorStripeMembership(accessToken: String) async -> String? {
        let urls = [
            "https://api2.cursor.sh/auth/full_stripe_profile",
            "https://api2.cursor.sh/auth/stripe_profile",
        ]
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let individual = stringValue(json, keys: ["individualMembershipType", "individual_membership_type"]),
                   !individual.isEmpty,
                   individual.lowercased() != "free"
                {
                    return individual
                }
                if let membership = stringValue(json, keys: ["membershipType", "membership_type"]),
                   !membership.isEmpty
                {
                    return membership
                }
            }
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               text != "null",
               !text.hasPrefix("{")
            {
                return text
            }
        }
        return nil
    }

    private static func cursorSessionCookie(accessToken: String) -> String? {
        guard let userID = cursorWorkosUserID(from: accessToken) else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    private static func cursorWorkosUserID(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String
        else { return nil }
        return sub.split(separator: "|").last.map(String.init) ?? sub
    }

    private static func cursorPlanLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "free": return "Cursor Free"
        case "pro", "individual": return "Cursor Pro"
        case "pro_plus", "pro-plus", "proplus": return "Cursor Pro+"
        case "business", "team": return "Cursor Business"
        case "enterprise": return "Cursor Enterprise"
        case "ultra": return "Cursor Ultra"
        default: return "Cursor \(raw.capitalized)"
        }
    }

    // MARK: - Copilot

    private static func fetchCopilotUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let login = stringValue(payload, keys: ["username", "login", "email"])
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeRouter/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(payload: payload)
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Usage API returned HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse usage response")
            }

            let snapshots = json["quota_snapshots"] as? [String: Any]
            let resetDate = parseCopilotResetDate(stringValue(json, keys: ["quota_reset_date"]))
            let premium = mapCopilotQuota(
                snapshots?["premium_interactions"] as? [String: Any],
                resetsAt: resetDate,
                label: "Premium"
            )
            let chat = mapCopilotQuota(
                snapshots?["chat"] as? [String: Any],
                resetsAt: resetDate,
                label: "Chat"
            )
            let completions = mapCopilotQuota(
                snapshots?["completions"] as? [String: Any],
                resetsAt: resetDate,
                label: "Completions"
            )
            let windows = [premium, chat, completions].compactMap { $0 }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "GitHub Copilot",
                windows: windows,
                accountEmail: login,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota data for this plan" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    private static func mapCopilotQuota(_ snapshot: [String: Any]?, resetsAt: Date?, label: String) -> RateWindow? {
        guard let snapshot else { return nil }
        let remaining = doubleValue(snapshot, keys: ["remaining"]) ?? 0
        let entitlement = doubleValue(snapshot, keys: ["entitlement"]) ?? 0
        guard entitlement > 0 else { return nil }
        let usedPercent = max(0, min(100, 100 - (remaining / entitlement * 100)))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: nil,
            label: label
        )
    }

    private static func parseCopilotResetDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    // MARK: - Gemini

    private static func fetchGeminiUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any],
        authFile: URL
    ) async -> ProviderUsageSnapshot {
        var payload = payload
        // Proactive refresh: Google access tokens are ~1h. Without this the quota
        // call 401s and the UI keeps showing the last cached value (e.g. stuck 5%).
        if TokenRefreshService.shouldRefresh(payload: payload) {
            _ = await TokenRefreshService.refreshAccountFile(authFile)
            if let latest = readAuthPayload(at: authFile) {
                payload = TokenRefreshService.flattenedAuth(latest)
            }
        }
        var snapshot = await fetchCloudCodeUsage(
            authAccountID: authAccountID,
            providerID: providerID,
            accessToken: extractGeminiAccessToken(from: payload),
            projectID: stringValue(payload, keys: ["project_id"]),
            email: stringValue(payload, keys: ["email"]),
            source: "Gemini OAuth",
            authPayload: payload
        )
        // One retry with a forced refresh when the token was rejected mid-flight.
        if (snapshot.errorMessage ?? "").localizedCaseInsensitiveContains("refreshing")
            || (snapshot.errorMessage ?? "").localizedCaseInsensitiveContains("expired")
        {
            if await TokenRefreshService.refreshAccountFile(authFile, force: true),
               let latest = readAuthPayload(at: authFile)
            {
                let flat = TokenRefreshService.flattenedAuth(latest)
                snapshot = await fetchCloudCodeUsage(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accessToken: extractGeminiAccessToken(from: flat),
                    projectID: stringValue(flat, keys: ["project_id"]),
                    email: stringValue(flat, keys: ["email"]) ?? stringValue(payload, keys: ["email"]),
                    source: "Gemini OAuth",
                    authPayload: flat
                )
            }
        }
        return snapshot
    }

    private static func extractGeminiAccessToken(from payload: [String: Any]) -> String? {
        if let token = stringValue(payload, keys: ["access_token"]) {
            return token
        }
        if let tokenObj = payload["token"] as? [String: Any] {
            return stringValue(tokenObj, keys: ["access_token", "accessToken"])
        }
        return nil
    }

    // MARK: - Antigravity

    private static func fetchAntigravityUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any],
        authFile: URL
    ) async -> ProviderUsageSnapshot {
        var payload = payload
        if TokenRefreshService.shouldRefresh(payload: payload) {
            _ = await TokenRefreshService.refreshAccountFile(authFile)
            if let latest = readAuthPayload(at: authFile) {
                payload = TokenRefreshService.flattenedAuth(latest)
            }
        }
        var snapshot = await fetchCloudCodeUsage(
            authAccountID: authAccountID,
            providerID: providerID,
            accessToken: stringValue(payload, keys: ["access_token"]),
            projectID: stringValue(payload, keys: ["project_id"]),
            email: stringValue(payload, keys: ["email"]),
            source: "Antigravity OAuth",
            authPayload: payload
        )
        if (snapshot.errorMessage ?? "").localizedCaseInsensitiveContains("refreshing")
            || (snapshot.errorMessage ?? "").localizedCaseInsensitiveContains("expired")
        {
            if await TokenRefreshService.refreshAccountFile(authFile, force: true),
               let latest = readAuthPayload(at: authFile)
            {
                let flat = TokenRefreshService.flattenedAuth(latest)
                snapshot = await fetchCloudCodeUsage(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accessToken: stringValue(flat, keys: ["access_token"]),
                    projectID: stringValue(flat, keys: ["project_id"]),
                    email: stringValue(flat, keys: ["email"]) ?? stringValue(payload, keys: ["email"]),
                    source: "Antigravity OAuth",
                    authPayload: flat
                )
            }
        }
        return snapshot
    }

    private static func fetchCloudCodeUsage(
        authAccountID: String,
        providerID: String,
        accessToken: String?,
        projectID: String?,
        email: String?,
        source: String,
        authPayload: [String: Any] = [:]
    ) async -> ProviderUsageSnapshot {
        guard let accessToken, !accessToken.isEmpty else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token")
        }

        let bodyData: Data
        if let projectID, !projectID.isEmpty {
            bodyData = Data("{\"project\": \"\(projectID)\"}".utf8)
        } else {
            bodyData = Data("{}".utf8)
        }

        // Cockpit-style: summary groups (Gemini vs Claude/Opus) are the accurate shared pools.
        // Per-model buckets are a fallback / detail layer.
        async let summaryJSON = postCloudCodeJSON(
            path: "v1internal:retrieveUserQuotaSummary",
            accessToken: accessToken,
            body: bodyData
        )
        async let detailJSON = postCloudCodeJSON(
            path: "v1internal:retrieveUserQuota",
            accessToken: accessToken,
            body: bodyData
        )

        let summary = await summaryJSON
        let detail = await detailJSON

        if summary.status == 401 || detail.status == 401 {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: email,
                error: sessionInvalidMessage(payload: authPayload)
            )
        }

        if let summaryBody = summary.json {
            let groups = cloudCodeQuotaGroups(from: summaryBody)
            if !groups.isEmpty {
                // Flatten primary windows for the top-level bars (most important first).
                var flatWindows: [RateWindow] = []
                for group in groups {
                    flatWindows.append(contentsOf: group.windows)
                }
                NSLog(
                    "[CloudCode] %@ (%@) → %d windows (%@)",
                    email ?? authAccountID,
                    providerID,
                    flatWindows.count,
                    flatWindows.map { "\($0.label ?? "?") \(Int($0.usedPercent))%" }.joined(separator: ", ")
                )
                return ProviderUsageSnapshot(
                    id: authAccountID,
                    providerID: providerID,
                    source: source,
                    windows: flatWindows,
                    subAccounts: groups,
                    accountEmail: email,
                    planType: nil,
                    planLabel: nil,
                    updatedAt: Date(),
                    errorMessage: nil,
                    isRefreshing: false
                )
            } else {
                NSLog(
                    "[CloudCode] %@ (%@) → summary returned no pool windows (groups=%@)",
                    email ?? authAccountID,
                    providerID,
                    String(describing: (summaryBody["groups"] as? [[String: Any]])?.count)
                )
            }
        }

        if let detailBody = detail.json {
            let windows = cloudCodeQuotaWindows(from: detailBody)
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: source,
                windows: windows,
                subAccounts: [],
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota data available" : nil,
                isRefreshing: false
            )
        }

        if let status = summary.status ?? detail.status, status != 200 {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: email,
                error: "Usage API returned HTTP \(status)"
            )
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: email,
            error: summary.error ?? detail.error ?? "Could not parse usage response"
        )
    }

    private struct CloudCodeHTTPResult {
        let status: Int?
        let json: [String: Any]?
        let error: String?
    }

    /// Antigravity IDE + Cockpit Tools hit **daily**-cloudcode by default.
    /// Prod `cloudcode-pa` often returns stale full remaining (e.g. 1.0) while
    /// daily shows the real 5h/weekly burn — that was the "limits never drop" bug.
    private static let cloudCodeBaseURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ]

    /// Match Cockpit / IDE UA shape: `antigravity/<ver> darwin/arm64`.
    private static var cloudCodeUserAgent: String {
        let ver = Bundle(path: "/Applications/Antigravity IDE.app")
            .flatMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            ?? Bundle(path: "/Applications/Antigravity.app")
            .flatMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            ?? "1.20.5"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/\(ver) darwin/\(arch)"
    }

    private static func postCloudCodeJSON(
        path: String,
        accessToken: String,
        body: Data
    ) async -> CloudCodeHTTPResult {
        let ua = cloudCodeUserAgent
        var last: CloudCodeHTTPResult = CloudCodeHTTPResult(status: nil, json: nil, error: "No Cloud Code host tried")
        for base in cloudCodeBaseURLs {
            guard let url = URL(string: "\(base)/\(path)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            request.setValue("gl-node/22.21.1", forHTTPHeaderField: "X-Goog-Api-Client")
            request.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    last = CloudCodeHTTPResult(status: nil, json: nil, error: "Invalid response")
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    last = CloudCodeHTTPResult(status: http.statusCode, json: nil, error: nil)
                    // 401/403 are auth problems — don't bother with the fallback host.
                    if http.statusCode == 401 || http.statusCode == 403 { return last }
                    continue
                }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                return CloudCodeHTTPResult(status: http.statusCode, json: json, error: nil)
            } catch {
                last = CloudCodeHTTPResult(status: nil, json: nil, error: error.localizedDescription)
            }
        }
        return last
    }

    /// Maps `retrieveUserQuotaSummary` groups into sub-accounts.
    /// Cloud Code `remainingFraction` is **remaining** 0…1 (Cockpit stores remaining%).
    /// We convert to **used%** = (1 − remaining) × 100 to align with Codex `used_percent`.
    /// Hardened: also accepts 0…100 percent, numeric strings, and missing `window`
    /// (weekly-only tiers omit the 5h bucket entirely — that is a valid tier shape,
    /// not an error).
    ///
    /// Expected shape (with project_id):
    /// Gemini Models → gemini-weekly / gemini-5h; Claude and GPT → 3p-weekly / 3p-5h.
    static func cloudCodeQuotaGroups(from json: [String: Any]) -> [ProviderUsageSubAccount] {
        guard let groups = json["groups"] as? [[String: Any]] else { return [] }

        return groups.compactMap { group -> ProviderUsageSubAccount? in
            let groupTitle = stringValue(group, keys: ["displayName", "name"])
                ?? "Model group"
            let description = stringValue(group, keys: ["description"])
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            let shortGroup = cloudCodeShortGroupName(groupTitle)

            let mapped = buckets.compactMap { mapCloudCodeSummaryBucket($0, shortGroup: shortGroup) }
            // Prefer pool windows (5h/weekly). Drop bare model rows when pools exist.
            let poolWindows = mapped.filter { $0.windowMinutes != nil }
            let windows = poolWindows.isEmpty ? mapped : poolWindows
            guard !windows.isEmpty else { return nil }

            let ordered = windows.sorted { lhs, rhs in
                let l = lhs.windowMinutes ?? Int.max
                let r = rhs.windowMinutes ?? Int.max
                if l != r { return l < r }
                return (lhs.label ?? "") < (rhs.label ?? "")
            }

            return ProviderUsageSubAccount(
                id: groupTitle,
                title: groupTitle,
                subtitle: description,
                planType: nil,
                windows: ordered,
                errorMessage: nil
            )
        }
    }

    /// Normalizes Cloud Code `remainingFraction` to **used%**.
    /// Accepts 0…1 fractions, 0…100 percents, and numeric strings.
    /// Missing value → 0% used (treat as full remaining), matching prior `?? 1` behavior.
    static func cloudCodeUsedPercent(remainingFraction raw: Double?) -> Double {
        guard let raw else { return 0 }
        // Heuristic: values > 1.5 cannot be a 0…1 fraction → treat as remaining %.
        if raw > 1.5 {
            return clampPercent(100 - raw)
        }
        return clampPercent((1 - raw) * 100)
    }

    /// API displayNames are "Weekly Limit Remaining" etc. We store used% (Codex-style),
    /// so strip trailing "Remaining" — otherwise "…Remaining 5%" reads as 5% left.
    static func cloudCodeBucketTitle(_ displayName: String) -> String {
        var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: " Remaining", options: [.caseInsensitive, .anchored, .backwards]) {
            name.removeSubrange(range)
        } else if name.lowercased() == "remaining" {
            name = "Limit"
        }
        return name.isEmpty ? "Limit" : name
    }

    private static func cloudCodeShortGroupName(_ groupTitle: String) -> String {
        let lower = groupTitle.lowercased()
        if lower.contains("claude") || lower.contains("gpt") || lower.contains("3p") {
            return "Claude/GPT"
        }
        if lower.contains("gemini") {
            return "Gemini"
        }
        return groupTitle
    }

    private static func mapCloudCodeSummaryBucket(_ bucket: [String: Any], shortGroup: String) -> RateWindow? {
        let resetTime = stringValue(bucket, keys: ["resetTime"])
        if let resetTime, resetTime.hasPrefix("1970-") { return nil }

        let remaining = doubleValue(bucket, keys: ["remainingFraction"])
        // Prefer explicit exhaustion flag when the API sends it (summary rarely does).
        let usedPercent: Double
        if bucket["isExhausted"] as? Bool == true {
            usedPercent = 100
        } else {
            usedPercent = cloudCodeUsedPercent(remainingFraction: remaining)
        }

        let displayName = cloudCodeBucketTitle(stringValue(bucket, keys: ["displayName"]) ?? "Limit")
        let bucketId = (stringValue(bucket, keys: ["bucketId", "id"]) ?? "").lowercased()
        let windowField = (stringValue(bucket, keys: ["window"]) ?? "").lowercased()
        let blob = "\(bucketId) \(windowField) \(displayName.lowercased())"

        let windowMinutes: Int?
        if blob.contains("5h") || blob.contains("five") || windowField == "5h" {
            windowMinutes = 300
        } else if blob.contains("week") || windowField == "weekly" {
            windowMinutes = 10_080
        } else if blob.contains("day") || windowField == "daily" {
            windowMinutes = 1_440
        } else {
            windowMinutes = nil
        }

        let resetsAt = parseISO8601(resetTime)
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: stringValue(bucket, keys: ["description"])
                ?? resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
            label: "\(shortGroup) · \(displayName)"
        )
    }

    // MARK: - Kiro

    // MARK: - OpenCode Go

    /// OpenCode Zen exposes the Go subscription's three quota windows at
    /// `GET /zen/go/v1/usage` (Bearer = the provider API key). Response shape:
    /// `{"usage":{"rolling":{...},"weekly":{...},"monthly":{...}}}` where each
    /// entry is `{status: "ok"|"rate-limited", percent: Int, resetsAt: ISO8601}`.
    private static func fetchOpenCodeGoUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        guard let apiKey = stringValue(payload, keys: ["api_key", "apiKey", "key"]) else {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                error: "Missing OpenCode Go API key"
            )
        }

        let label = stringValue(payload, keys: ["label", "email"]) ?? maskAPIKey(apiKey)
        guard let url = URL(string: "https://opencode.ai/zen/go/v1/usage") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, accountEmail: label, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // opencode.ai sits behind Cloudflare and 1010-blocks default client agents.
        request.setValue("VibeRouter/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, accountEmail: label, error: "No response from OpenCode Zen")
            }
            if http.statusCode == 401 {
                NSLog("[OpenCodeGo] %@ → 401 rejected", label)
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accountEmail: label,
                    error: "API key rejected — replace this OpenCode Go key in Settings"
                )
            }
            if http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accountEmail: label,
                    error: "This key has no active OpenCode Go subscription"
                )
            }
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = json["usage"] as? [String: Any]
            else {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accountEmail: label,
                    error: "Could not read OpenCode Go limits (HTTP \(http.statusCode))"
                )
            }

            let windows = openCodeGoWindows(from: usage)
            NSLog(
                "[OpenCodeGo] %@ → %d windows (%@)",
                label,
                windows.count,
                windows.map { "\($0.label ?? "?") \(Int($0.usedPercent))%" }.joined(separator: ", ")
            )
            guard !windows.isEmpty else {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    accountEmail: label,
                    error: "OpenCode Zen returned no quota windows"
                )
            }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "opencode.ai/zen",
                windows: windows,
                accountEmail: label,
                planType: "OpenCode Go",
                planLabel: "OpenCode Go",
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        } catch {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: label,
                error: openCodeGoNetworkError(error)
            )
        }
    }

    private static func openCodeGoNetworkError(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "Could not load OpenCode Go limits"
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "Network error loading OpenCode Go limits — check connectivity"
        case .timedOut:
            return "OpenCode Zen timed out — retry shortly"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Could not reach opencode.ai — check network/DNS"
        default:
            return "Could not load OpenCode Go limits"
        }
    }

    /// Order matters — the card shows the first window as the headline.
    static func openCodeGoWindows(from usage: [String: Any]) -> [RateWindow] {
        let buckets: [(key: String, label: String, minutes: Int)] = [
            ("rolling", "5-hour", 300),
            ("weekly", "Weekly", 10_080),
            ("monthly", "Monthly", 43_200),
        ]
        return buckets.compactMap { bucket in
            guard let entry = usage[bucket.key] as? [String: Any] else { return nil }
            let status = (stringValue(entry, keys: ["status"]) ?? "").lowercased()
            // A rate-limited bucket is exhausted even when `percent` lags behind.
            let reported = doubleValue(entry, keys: ["percent"]) ?? 0
            let usedPercent = status == "rate-limited" ? 100 : clampPercent(reported)
            let resetsAt = parseISO8601(stringValue(entry, keys: ["resetsAt", "resets_at"]))
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: bucket.minutes,
                resetsAt: resetsAt,
                resetDescription: resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
                label: bucket.label,
                displayStyle: .percent
            )
        }
    }

    private static func fetchKiroUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        let email = stringValue(payload, keys: ["email"])

        // CodexBar ground truth: `kiro-cli chat --no-interactive /usage`
        // e.g. Free "(0.00 of 50 covered…)", Pro 1000, Power 10000 — never invent a pool size.
        // AWS GetUsageLimits can report ~0 while CLI shows real plan credits.
        let cliProbe = await Task.detached(priority: .userInitiated, operation: {
            KiroCLIUsageProbe.fetch()
        }).value
        if cliProbe == nil {
            NSLog("[Kiro] kiro-cli /usage probe returned nothing — falling back to GetUsageLimits")
        }
        if let cli = cliProbe {
            NSLog(
                "[Kiro] %@ → %.2f of %.0f credits (%.1f%%)",
                cli.planName ?? "plan?", cli.creditsUsed, cli.creditsTotal, cli.creditsPercent
            )
            let usedPercent = clampPercent(cli.creditsPercent)
            let window: RateWindow
            if cli.hasAbsoluteCredits {
                let total = cli.creditsTotal
                let used = min(total, max(0, cli.creditsUsed))
                let remaining = max(0, total - used)
                window = RateWindow(
                    usedPercent: usedPercent > 0
                        ? usedPercent
                        : clampPercent(total > 0 ? used / total * 100 : 0),
                    windowMinutes: 43_200,
                    resetsAt: cli.resetsAt,
                    resetDescription: cli.resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
                    label: cli.planName.map { "\($0) credits" } ?? "Credits",
                    remainingValue: remaining,
                    totalValue: total,
                    unitLabel: "credits",
                    displayStyle: .creditsRemaining
                )
            } else {
                // Percent-only: show % used/left — do not invent remaining/total (50 vs 1000 vs 10000).
                window = RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 43_200,
                    resetsAt: cli.resetsAt,
                    resetDescription: cli.resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
                    label: cli.planName.map { "\($0) credits" } ?? "Credits",
                    remainingValue: nil,
                    totalValue: nil,
                    unitLabel: "credits",
                    displayStyle: .percent
                )
            }
            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: cli.source,
                windows: [window],
                accountEmail: email,
                planType: cli.planName,
                planLabel: cli.planName,
                updatedAt: Date(),
                errorMessage: nil,
                isRefreshing: false
            )
        }

        // Fallback: GetUsageLimits (often wrong for org/power) + light local metering blend.
        guard let accessToken = stringValue(payload, keys: ["access_token"]) else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Missing access token (and kiro-cli /usage unavailable)")
        }

        let region = stringValue(payload, keys: ["region"]) ?? "us-east-1"
        guard let url = URL(string: "https://codewhisperer.\(region).amazonaws.com/getUsageLimits") else {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("AmazonCodeWhispererService.GetUsageLimits", forHTTPHeaderField: "x-amz-target")
        request.httpBody = Data("{\"origin\":\"KIRO_CLI\"}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .empty(
                    authAccountID: authAccountID,
                    providerID: providerID,
                    error: sessionInvalidMessage(payload: payload)
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Usage API returned HTTP \(http.statusCode)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(authAccountID: authAccountID, providerID: providerID, error: "Could not parse usage response")
            }

            let breakdown = json["usageBreakdownList"] as? [[String: Any]] ?? []
            let credit = breakdown.first { stringValue($0, keys: ["resourceType"]) == "CREDIT" }
                ?? breakdown.first
            let primary = mapKiroUsageBreakdownAPI(
                credit,
                fallbackReset: json["nextDateReset"],
                label: "Credits"
            )
            let windows = [primary].compactMap { $0 }

            return ProviderUsageSnapshot(
                id: authAccountID,
                providerID: providerID,
                source: "Kiro GetUsageLimits",
                windows: windows,
                accountEmail: email,
                updatedAt: Date(),
                errorMessage: windows.isEmpty ? "No quota data available" : nil,
                isRefreshing: false
            )
        } catch {
            return .empty(authAccountID: authAccountID, providerID: providerID, error: error.localizedDescription)
        }
    }

    /// API-only fallback when kiro-cli is missing. Prefer overageCap pool (product UI / kiro-cli).
    private static func mapKiroUsageBreakdownAPI(
        _ breakdown: [String: Any]?,
        fallbackReset: Any?,
        label: String
    ) -> RateWindow? {
        guard let breakdown else { return nil }

        let freeUsed = doubleValue(breakdown, keys: ["currentUsageWithPrecision", "currentUsage"]) ?? 0
        let freeLimit = doubleValue(breakdown, keys: ["usageLimitWithPrecision", "usageLimit"]) ?? 0
        let overageCap = doubleValue(breakdown, keys: ["overageCapWithPrecision", "overageCap"]) ?? 0
        let overageUsed = doubleValue(breakdown, keys: ["currentOveragesWithPrecision", "currentOverages"]) ?? 0

        let total = max(freeLimit, overageCap)
        guard total > 0 else { return nil }

        let resetEpoch = doubleValue(breakdown, keys: ["nextDateReset"])
            ?? (fallbackReset as? Double)
            ?? (fallbackReset as? Int).map(Double.init)
            ?? (fallbackReset as? NSNumber).map { $0.doubleValue }
        let resetsAt = resetEpoch.map { epoch in
            Date(timeIntervalSince1970: TimeInterval(epoch > 1_000_000_000_000 ? epoch / 1000 : epoch))
        }

        let used = min(total, freeUsed + overageUsed)
        let remaining = max(0, total - used)
        let usedPercent = clampPercent(used / total * 100)

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 43_200,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
            label: label,
            remainingValue: remaining,
            totalValue: total,
            unitLabel: "credits",
            displayStyle: .creditsRemaining
        )
    }

    // MARK: - Grok

    struct GrokTokenCandidate: Equatable {
        let token: String
        let source: String
        let expired: Bool
    }

    private static func fetchGrokUsage(
        authAccountID: String,
        providerID: String,
        payload: [String: Any]
    ) async -> ProviderUsageSnapshot {
        var workingPayload = payload
        if let fileURL = resolveAuthFileURL(authAccountID: authAccountID, providerID: providerID),
           overlayGrokCLICredentialsIfFresher(onto: fileURL),
           let latest = readAuthPayload(at: fileURL)
        {
            workingPayload = enrichPayload(latest, for: .grok)
        }

        // Keep this account's own email so multi-account lists do not all show ~/.grok identity.
        let accountEmail = stringValue(workingPayload, keys: ["email"])
        let localGrok = readGrokAppPayload()
        let localEmail = stringValue(localGrok ?? [:], keys: ["email"])
        var tokenCandidates = grokBillingTokenCandidates(
            accountPayload: workingPayload,
            localGrok: localGrok
        )

        let displayEmail = accountEmail ?? localEmail

        // Proactively refresh stale auth-file tokens once (cli-proxy xAI files go stale fast).
        if isGrokCredentialExpired(workingPayload) || tokenCandidates.allSatisfy(\.expired) {
            if let fileURL = resolveAuthFileURL(authAccountID: authAccountID, providerID: providerID),
               await TokenRefreshService.refreshAccountFile(fileURL),
               let refreshed = readAuthPayload(at: fileURL)
            {
                workingPayload = enrichPayload(refreshed, for: .grok)
                if let t = stringValue(workingPayload, keys: ["access_token", "key"]) {
                    let candidate = GrokTokenCandidate(
                        token: t,
                        source: "refreshed",
                        expired: isGrokCredentialExpired(workingPayload)
                    )
                    if !tokenCandidates.contains(where: { $0.token == t }) {
                        if candidate.expired {
                            tokenCandidates.append(candidate)
                        } else if let idx = tokenCandidates.firstIndex(where: { $0.expired }) {
                            tokenCandidates.insert(candidate, at: idx)
                        } else {
                            tokenCandidates.append(candidate)
                        }
                    }
                }
            }
        }

        guard !tokenCandidates.isEmpty else {
            return .empty(
                authAccountID: authAccountID,
                providerID: providerID,
                accountEmail: displayEmail,
                error: "Missing Grok access token — run `grok login` or connect Grok in Settings"
            )
        }

        var lastError: String?
        for candidate in tokenCandidates {
            // Skip known-dead tokens unless nothing else remains (last resort).
            if candidate.expired,
               tokenCandidates.contains(where: { !$0.expired }),
               candidate.source != "refreshed"
            {
                continue
            }
            let outcome = await requestGrokBilling(
                accessToken: candidate.token,
                authAccountID: authAccountID,
                providerID: providerID,
                email: displayEmail,
                payload: workingPayload
            )
            switch outcome {
            case .success(let snapshot):
                return ProviderUsageSnapshot(
                    id: snapshot.id,
                    providerID: snapshot.providerID,
                    source: snapshot.source,
                    windows: snapshot.windows,
                    subAccounts: snapshot.subAccounts,
                    accountEmail: displayEmail,
                    planType: snapshot.planType,
                    planLabel: snapshot.planLabel,
                    rateLimitResets: snapshot.rateLimitResets,
                    updatedAt: snapshot.updatedAt,
                    errorMessage: snapshot.errorMessage,
                    isRefreshing: false
                )
            case .failure(let message):
                lastError = message
                // On auth failure of auth-file token, try one more refresh then retry once.
                if message.localizedCaseInsensitiveContains("rejected")
                    || message.localizedCaseInsensitiveContains("unauthenticated")
                    || message.localizedCaseInsensitiveContains("bad-credentials"),
                   candidate.source == "auth-file",
                   let fileURL = resolveAuthFileURL(authAccountID: authAccountID, providerID: providerID),
                   await TokenRefreshService.refreshAccountFile(fileURL),
                   let refreshed = readAuthPayload(at: fileURL),
                   let newToken = stringValue(refreshed, keys: ["access_token", "key"]),
                   newToken != candidate.token
                {
                    let retry = await requestGrokBilling(
                        accessToken: newToken,
                        authAccountID: authAccountID,
                        providerID: providerID,
                        email: displayEmail,
                        payload: refreshed
                    )
                    if case .success(let snapshot) = retry {
                        return ProviderUsageSnapshot(
                            id: snapshot.id,
                            providerID: snapshot.providerID,
                            source: snapshot.source,
                            windows: snapshot.windows,
                            subAccounts: snapshot.subAccounts,
                            accountEmail: displayEmail,
                            planType: snapshot.planType,
                            planLabel: snapshot.planLabel,
                            rateLimitResets: snapshot.rateLimitResets,
                            updatedAt: snapshot.updatedAt,
                            errorMessage: snapshot.errorMessage,
                            isRefreshing: false
                        )
                    }
                    if case .failure(let retryMsg) = retry {
                        lastError = retryMsg
                    }
                }
                continue
            }
        }

        return .empty(
            authAccountID: authAccountID,
            providerID: providerID,
            accountEmail: displayEmail,
            error: friendlyGrokError(lastError)
        )
    }

    /// Map low-level URLSession / grpc noise into a user-actionable line.
    private static func friendlyGrokError(_ raw: String?) -> String {
        let message = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if message.isEmpty {
            return "Could not load Grok usage — run `grok login` and retry"
        }
        if lower.contains("rejected")
            || lower.contains("unauthenticated")
            || lower.contains("bad-credentials")
            || lower.contains("could not be validated")
        {
            return "Grok token invalid for billing — run `grok login` (cli-proxy xAI tokens often cannot read SuperGrok usage)"
        }
        if lower.contains("not connected")
            || lower.contains("offline")
            || lower.contains("network")
            || lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("internet connection")
        {
            return "Network error loading Grok usage — check connectivity and retry"
        }
        // URLSession's "The data couldn’t be read because it isn’t in the correct format." etc.
        if lower.contains("couldn") || lower.contains("unexpected") || lower.contains("format") {
            return "Grok billing returned an unexpected response — retry shortly or run `grok login`"
        }
        return message
    }

    private static func resolveAuthFileURL(authAccountID: String, providerID: String) -> URL? {
        // authAccountID is AuthAccount.id (filename, with or without .json).
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        let candidates = [
            dir.appendingPathComponent(authAccountID),
            dir.appendingPathComponent(authAccountID.hasSuffix(".json") ? authAccountID : "\(authAccountID).json"),
        ]
        for direct in candidates where FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let needle = authAccountID.replacingOccurrences(of: ".json", with: "")
        for file in files where file.pathExtension == "json" {
            if file.deletingPathExtension().lastPathComponent == needle {
                return file
            }
        }
        return nil
    }

    private enum GrokBillingOutcome {
        case success(ProviderUsageSnapshot)
        case failure(String)
    }

    private static func requestGrokBilling(
        accessToken: String,
        authAccountID: String,
        providerID: String,
        email: String?,
        payload: [String: Any]
    ) async -> GrokBillingOutcome {
        guard let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig") else {
            return .failure("Invalid usage URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        // Match CodexBar UA — some edges are picky about unknown clients.
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(
                    sessionInvalidMessage(
                        payload: payload,
                        reauthHint: "run `grok login` or re-authenticate Grok in Settings"
                    )
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure("Grok billing returned HTTP \(http.statusCode)")
            }

            // grpc-status often lives on HTTP headers (empty body) for auth failures.
            if let grpcError = grokGRPCError(from: data, http: http, payload: payload) {
                return .failure(grpcError)
            }

            guard let parsed = parseGrokBillingResponse(data) else {
                if data.isEmpty {
                    return .failure(
                        "Grok billing returned empty usage — run `grok login` (cli-proxy tokens often cannot read SuperGrok billing)"
                    )
                }
                return .failure("Could not parse Grok billing usage")
            }

            let label = grokUsageWindowLabel(resetsAt: parsed.resetsAt)
            let primary = RateWindow(
                usedPercent: parsed.usedPercent,
                windowMinutes: grokWindowMinutes(resetsAt: parsed.resetsAt),
                resetsAt: parsed.resetsAt,
                resetDescription: parsed.resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
                label: label,
                displayStyle: .percent
            )

            // SuperGrok one-time usage resets (banked "clear the weekly pool" tokens).
            let resetBank = await RateLimitResetService.fetchGrokBank(accessToken: accessToken)

            return .success(
                ProviderUsageSnapshot(
                    id: authAccountID,
                    providerID: providerID,
                    source: "xAI OAuth",
                    windows: [primary],
                    accountEmail: email,
                    planLabel: "Grok",
                    rateLimitResets: resetBank,
                    updatedAt: Date(),
                    errorMessage: nil,
                    isRefreshing: false
                )
            )
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .failure("Network error loading Grok usage — check connectivity")
            case .timedOut:
                return .failure("Grok billing timed out — retry shortly")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failure("Could not reach grok.com — check network/DNS")
            default:
                return .failure(friendlyGrokError(urlError.localizedDescription))
            }
        } catch {
            return .failure(friendlyGrokError(error.localizedDescription))
        }
    }

    private static func grokUsageWindowLabel(resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt else { return "Credits" }
        let days = resetsAt.timeIntervalSince(now) / 86_400
        if days <= 8 { return "Weekly" }
        if days <= 40 { return "Monthly" }
        return "Credits"
    }

    private static func grokWindowMinutes(resetsAt: Date?, now: Date = Date()) -> Int? {
        guard let resetsAt else { return nil }
        let days = resetsAt.timeIntervalSince(now) / 86_400
        if days <= 8 { return 10_080 }
        if days <= 40 { return 43_200 }
        return nil
    }

    /// True when JWT `exp` or `expired` / `expires_at` is in the past.
    static func isGrokCredentialExpired(_ payload: [String: Any], now: Date = Date()) -> Bool {
        if let token = stringValue(payload, keys: ["access_token", "key"]),
           let exp = jwtExpiry(token)
        {
            return exp <= now
        }
        if let raw = stringValue(payload, keys: ["expired", "expires_at", "expiresAt"]),
           let date = parseISO8601(raw)
        {
            return date <= now
        }
        return false
    }

    /// Token order (per account — never stamp SuperGrok onto every row blindly):
    /// 1) fresh ~/.grok token when identity matches
    /// 2) this auth file's token if not expired
    /// 3) expired tokens last
    static func grokBillingTokenCandidates(
        accountPayload: [String: Any],
        localGrok: [String: Any]?,
        now: Date = Date()
    ) -> [GrokTokenCandidate] {
        var tokenCandidates: [GrokTokenCandidate] = []
        func appendCandidate(_ token: String, source: String, expired: Bool) {
            guard !token.isEmpty, !tokenCandidates.contains(where: { $0.token == token }) else { return }
            let candidate = GrokTokenCandidate(token: token, source: source, expired: expired)
            if expired {
                tokenCandidates.append(candidate)
            } else if let idx = tokenCandidates.firstIndex(where: { $0.expired }) {
                tokenCandidates.insert(candidate, at: idx)
            } else {
                tokenCandidates.append(candidate)
            }
        }

        let accountEmail = stringValue(accountPayload, keys: ["email"])
        let localEmail = stringValue(localGrok ?? [:], keys: ["email"])
        if let localGrok, let token = stringValue(localGrok, keys: ["access_token", "key"]) {
            let emailsMatch: Bool = {
                guard let accountEmail, let localEmail else { return accountEmail == nil }
                return accountEmail.caseInsensitiveCompare(localEmail) == .orderedSame
            }()
            // Live CLI session with no email still beats a dead imported copy.
            let localLive = !isGrokCredentialExpired(localGrok, now: now)
            if emailsMatch || (localEmail == nil && localLive) {
                appendCandidate(token, source: "grok-cli", expired: !localLive)
            }
        }
        if let token = stringValue(accountPayload, keys: ["access_token", "key"]) {
            appendCandidate(token, source: "auth-file", expired: isGrokCredentialExpired(accountPayload, now: now))
        }
        return tokenCandidates
    }

    /// Copy a fresher `~/.grok` access/refresh token onto the cli-proxy xAI file.
    /// One-shot import otherwise goes stale while Grok CLI keeps its own session alive.
    @discardableResult
    static func overlayGrokCLICredentialsIfFresher(
        onto authFile: URL,
        localGrok: [String: Any]? = nil,
        now: Date = Date()
    ) -> Bool {
        guard var payload = readAuthPayload(at: authFile) else { return false }
        let local = localGrok ?? readGrokAppPayload()
        guard let local,
              let localToken = stringValue(local, keys: ["access_token", "key"]),
              !localToken.isEmpty,
              !isGrokCredentialExpired(local, now: now)
        else { return false }

        let accountEmail = stringValue(payload, keys: ["email"])
        let localEmail = stringValue(local, keys: ["email"])
        if let accountEmail, let localEmail,
           accountEmail.caseInsensitiveCompare(localEmail) != .orderedSame
        {
            return false
        }

        let fileToken = stringValue(payload, keys: ["access_token", "key"])
        let sameAccess = fileToken == localToken
        let sameRefresh = stringValue(payload, keys: ["refresh_token"])
            == stringValue(local, keys: ["refresh_token"])
        if sameAccess && sameRefresh { return false }

        if let fileToken, !isGrokCredentialExpired(payload, now: now) {
            let localExp = jwtExpiry(localToken) ?? .distantPast
            let fileExp = jwtExpiry(fileToken) ?? .distantPast
            if fileExp >= localExp { return false }
        }

        payload["access_token"] = localToken
        payload["key"] = localToken
        if let refresh = stringValue(local, keys: ["refresh_token"]) {
            payload["refresh_token"] = refresh
        }
        if let exp = stringValue(local, keys: ["expired", "expires_at"]) {
            payload["expired"] = exp
            payload["expires_at"] = exp
        }
        if let clientID = stringValue(local, keys: ["oidc_client_id", "client_id"]) {
            payload["oidc_client_id"] = clientID
            payload["client_id"] = clientID
        }
        return writeAuthPayload(payload, to: authFile)
    }

    static func grokPreferredEntry(in root: [String: Any]) -> (String, [String: Any])? {
        let oidcPrefix = "https://auth.x.ai::"
        if let match = root.first(where: { $0.key.hasPrefix(oidcPrefix) }),
           let entry = match.value as? [String: Any]
        {
            return (match.key, entry)
        }
        if let legacy = root["https://accounts.x.ai/sign-in"] as? [String: Any] {
            return ("https://accounts.x.ai/sign-in", legacy)
        }
        return root.compactMap { key, value -> (String, [String: Any])? in
            guard let dict = value as? [String: Any], dict["key"] != nil else { return nil }
            return (key, dict)
        }.first
    }

    @discardableResult
    static func updateGrokAppPayload(
        at url: URL? = nil,
        oldRefresh: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: String?
    ) -> Bool {
        let authURL = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard var root = readAuthPayload(at: authURL),
              let (entryKey, entry) = grokPreferredEntry(in: root)
        else { return false }
        let stored = (entry["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored == oldRefresh else { return false }

        var updated = entry
        updated["key"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            updated["refresh_token"] = refreshToken
        }
        if let expiresAt, !expiresAt.isEmpty {
            updated["expires_at"] = expiresAt
        }
        root[entryKey] = updated
        return writeAuthPayload(root, to: authURL)
    }

    static func writeAuthPayload(_ payload: [String: Any], to url: URL) -> Bool {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    static func jwtExpiry(_ token: String) -> Date? {
        jwtClaimDate(token, key: "exp")
    }

    private static func jwtClaimDate(_ token: String, key: String) -> Date? {
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
        if let value = json[key] as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = json[key] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    // MARK: - Helpers

    private static func enrichPayload(_ payload: [String: Any], for serviceType: ServiceType) -> [String: Any] {
        var merged = payload

        switch serviceType {
        case .codex:
            if let local = readCodexAppPayload() {
                for (key, value) in local where merged[key] == nil {
                    merged[key] = value
                }
                if shouldAdoptCodexCLITokens(local: local, file: merged) {
                    for key in ["access_token", "refresh_token", "id_token", "account_id"] {
                        if let value = local[key] { merged[key] = value }
                    }
                }
            }
        case .claude:
            if merged["access_token"] == nil, let local = readClaudeAppPayload() {
                merged.merge(local) { _, new in new }
            }
        case .grok:
            // Only fill missing fields from ~/.grok — never replace this account's token/email
            // with a different SuperGrok identity (that caused every Grok row to look identical).
            if let local = readGrokAppPayload() {
                let accountEmail = stringValue(merged, keys: ["email"])
                let localEmail = stringValue(local, keys: ["email"])
                let sameIdentity = {
                    guard let accountEmail, let localEmail else { return accountEmail == nil }
                    return accountEmail.caseInsensitiveCompare(localEmail) == .orderedSame
                }()
                if sameIdentity {
                    for (key, value) in local where merged[key] == nil {
                        merged[key] = value
                    }
                    // If this file's token is expired and CLI matches identity, allow CLI token.
                    if isGrokCredentialExpired(merged),
                       !isGrokCredentialExpired(local),
                       let token = stringValue(local, keys: ["access_token", "key"])
                    {
                        merged["access_token"] = token
                        merged["key"] = token
                    }
                } else {
                    // Different identity: only copy non-identity fallbacks if fields are empty.
                    for key in ["refresh_token"] where merged[key] == nil {
                        if let value = local[key] { merged[key] = value }
                    }
                }
            }
        default:
            break
        }

        return merged
    }

    static func readCodexAppPayload(at url: URL? = nil) -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = url ?? home.appendingPathComponent(".codex/auth.json")
        let file = flattenCodexCLIRoot(readAuthPayload(at: authURL))
        // Tests pass an explicit file and must not hit the real keychain.
        let keychain: [String: Any]? = url == nil
            ? flattenCodexCLIRoot(
                CodexWorkspaceCredentials.readKeychain(codexHome: home.appendingPathComponent(".codex"))
            )
            : nil
        return pickFresherCodexCLIPayload(file, keychain)
    }

    /// Copy a fresher Codex CLI/desktop session onto the cli-proxy file.
    /// Imported `codex-*.json` copies go stale while `codex` rotates `~/.codex/auth.json`
    /// + keychain; posting that leftover refresh token returns `refresh_token_reused`
    /// and OpenAI revokes the whole family.
    @discardableResult
    static func overlayCodexCLICredentialsIfFresher(
        onto authFile: URL,
        localCodex: [String: Any]? = nil,
        now: Date = Date()
    ) -> Bool {
        guard var payload = readAuthPayload(at: authFile) else { return false }
        let local = localCodex ?? readCodexAppPayload()
        guard let local, shouldAdoptCodexCLITokens(local: local, file: payload, now: now) else {
            return false
        }

        payload = TokenRefreshService.flattenedAuth(payload)
        if let access = stringValue(local, keys: ["access_token"]) {
            payload["access_token"] = access
        }
        if let refresh = stringValue(local, keys: ["refresh_token"]) {
            payload["refresh_token"] = refresh
        }
        if let idToken = stringValue(local, keys: ["id_token"]) {
            payload["id_token"] = idToken
        }
        if let accountID = stringValue(local, keys: ["account_id"]) {
            payload["account_id"] = accountID
        }
        if let exp = CodexWorkspaceCredentials.accessTokenExpiry(
            stringValue(local, keys: ["access_token"])
        ) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            payload["expired"] = formatter.string(from: exp)
            payload["expires_at"] = formatter.string(from: exp)
        }
        payload["last_refresh"] = payload["last_refresh"] ?? payload["expired"]
        return writeAuthPayload(payload, to: authFile)
    }

    /// True when `local` is the same ChatGPT seat and has a newer access token than `file`.
    static func shouldAdoptCodexCLITokens(
        local: [String: Any],
        file: [String: Any],
        now: Date = Date()
    ) -> Bool {
        let localFlat = TokenRefreshService.flattenedAuth(local)
        let fileFlat = TokenRefreshService.flattenedAuth(file)
        guard let localToken = stringValue(localFlat, keys: ["access_token"]), !localToken.isEmpty else {
            return false
        }
        let fileToken = stringValue(fileFlat, keys: ["access_token"])
        if fileToken == localToken,
           stringValue(localFlat, keys: ["refresh_token"]) == stringValue(fileFlat, keys: ["refresh_token"])
        {
            return false
        }

        if let fileEmail = stringValue(fileFlat, keys: ["email"]),
           let localEmail = stringValue(localFlat, keys: ["email"]),
           fileEmail.caseInsensitiveCompare(localEmail) != .orderedSame
        {
            return false
        }

        let fileAID = CodexWorkspaceCredentials.chatgptAccountID(from: fileToken)
            ?? stringValue(fileFlat, keys: ["account_id"])
        let localAID = CodexWorkspaceCredentials.chatgptAccountID(from: localToken)
            ?? stringValue(localFlat, keys: ["account_id"])
        if let fileAID, let localAID,
           fileAID.caseInsensitiveCompare(localAID) != .orderedSame
        {
            return false
        }

        let localExp = CodexWorkspaceCredentials.accessTokenExpiry(localToken) ?? .distantPast
        let fileExp = fileToken.flatMap(CodexWorkspaceCredentials.accessTokenExpiry) ?? .distantPast
        if localExp <= fileExp { return false }
        // A live CLI token always beats an expired/missing file token.
        if localExp <= now, fileExp > now { return false }
        return true
    }

    private static func flattenCodexCLIRoot(_ root: [String: Any]?) -> [String: Any]? {
        guard let root else { return nil }
        let tokens = (root["tokens"] as? [String: Any]) ?? [:]
        var payload: [String: Any] = [:]
        let access = (tokens["access_token"] as? String) ?? (root["access_token"] as? String)
        let refresh = (tokens["refresh_token"] as? String) ?? (root["refresh_token"] as? String)
        let idToken = (tokens["id_token"] as? String) ?? (root["id_token"] as? String)
        let accountID = (tokens["account_id"] as? String) ?? (root["account_id"] as? String)
        if let access, !access.isEmpty { payload["access_token"] = access }
        if let refresh, !refresh.isEmpty { payload["refresh_token"] = refresh }
        if let idToken, !idToken.isEmpty { payload["id_token"] = idToken }
        if let accountID, !accountID.isEmpty { payload["account_id"] = accountID }
        if let email = root["email"] as? String, !email.isEmpty {
            payload["email"] = email
        } else if let email = JWTEmailExtractor.email(from: idToken) {
            payload["email"] = email
        }
        return payload.isEmpty ? nil : payload
    }

    private static func pickFresherCodexCLIPayload(
        _ lhs: [String: Any]?,
        _ rhs: [String: Any]?
    ) -> [String: Any]? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (let only?, nil):
            return only
        case (nil, let only?):
            return only
        case (let a?, let b?):
            let aExp = CodexWorkspaceCredentials.accessTokenExpiry(
                stringValue(a, keys: ["access_token"])
            ) ?? .distantPast
            let bExp = CodexWorkspaceCredentials.accessTokenExpiry(
                stringValue(b, keys: ["access_token"])
            ) ?? .distantPast
            return bExp > aExp ? b : a
        }
    }

    static func readGrokAppPayload() -> [String: Any]? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        return readGrokAppPayload(at: authURL)
    }

    static func readGrokAppPayload(at authURL: URL) -> [String: Any]? {
        guard let root = readAuthPayload(at: authURL),
              let (_, entry) = grokPreferredEntry(in: root)
        else { return nil }

        let accessToken = (entry["key"] as? String) ?? (entry["access_token"] as? String)
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var payload: [String: Any] = [
            "access_token": accessToken,
            "key": accessToken,
        ]
        if let email = entry["email"] as? String, !email.isEmpty {
            payload["email"] = email
        }
        if let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty {
            payload["refresh_token"] = refreshToken
        }
        if let expiresAt = (entry["expires_at"] as? String) ?? (entry["expired"] as? String),
           !expiresAt.isEmpty
        {
            payload["expired"] = expiresAt
            payload["expires_at"] = expiresAt
        }
        if let clientID = (entry["oidc_client_id"] as? String) ?? (entry["client_id"] as? String),
           !clientID.isEmpty
        {
            payload["oidc_client_id"] = clientID
            payload["client_id"] = clientID
        }
        return payload
    }

    private static func readClaudeAppPayload() -> [String: Any]? {
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")

        let data: Data?
        if let fileData = try? Data(contentsOf: credentialsURL) {
            data = fileData
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            data = output.isEmpty ? nil : output
        }

        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }

        var payload: [String: Any] = ["access_token": accessToken]
        if let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty {
            payload["refresh_token"] = refreshToken
        }
        if let email = oauth["email"] as? String, !email.isEmpty {
            payload["email"] = email
        }
        if let expiresAt = oauth["expiresAt"] as? Double {
            payload["expired"] = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: expiresAt / 1000)
            )
        }
        return payload
    }

    static func readAuthPayload(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
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

    private static func doubleValue(_ json: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            // JSONSerialization boxes numbers as NSNumber — cast via NSNumber first.
            if let number = json[key] as? NSNumber {
                return number.doubleValue
            }
            if let value = json[key] as? Double { return value }
            if let value = json[key] as? Int { return Double(value) }
            if let value = json[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func intValue(_ json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let number = json[key] as? NSNumber {
                return number.intValue
            }
            if let value = json[key] as? Int { return value }
            if let value = json[key] as? Double { return Int(value) }
            if let value = json[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatters: [ISO8601DateFormatter] = {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            return [withFractional, standard]
        }()
        for formatter in formatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    // MARK: - Cloud Code quota helpers

    /// Groups Cloud Code / Gemini / Antigravity quota buckets into human-readable
    /// model-family rows (Gemini Pro, Gemini Flash, Claude Opus, Claude Sonnet, …).
    static func cloudCodeQuotaWindows(from json: [String: Any]) -> [RateWindow] {
        var candidates: [(family: CloudCodeModelFamily, window: RateWindow)] = []

        if let buckets = json["buckets"] as? [[String: Any]] {
            for bucket in buckets {
                guard let modelID = stringValue(bucket, keys: ["modelId", "model_id", "name"]),
                      let window = mapCloudCodeBucket(bucket, label: "")
                else { continue }
                let family = CloudCodeModelFamily.classify(modelID: modelID)
                candidates.append((family, window.withLabel(family.displayName)))
            }
        }

        if candidates.isEmpty, let models = json["models"] as? [[String: Any]] {
            for model in models {
                let modelID = stringValue(model, keys: ["name", "modelId", "model", "displayName"]) ?? "model"
                guard let quotaInfo = model["quotaInfo"] as? [String: Any] ?? model["quota"] as? [String: Any],
                      let window = mapCloudCodeQuotaInfo(quotaInfo, label: "")
                else { continue }
                let family = CloudCodeModelFamily.classify(modelID: modelID)
                candidates.append((family, window.withLabel(family.displayName)))
            }
        }

        // Keep the most constrained window per family, ordered for readability.
        var bestByFamily: [CloudCodeModelFamily: RateWindow] = [:]
        for candidate in candidates {
            if let existing = bestByFamily[candidate.family] {
                if candidate.window.usedPercent > existing.usedPercent {
                    bestByFamily[candidate.family] = candidate.window
                }
            } else {
                bestByFamily[candidate.family] = candidate.window
            }
        }

        let ordered = CloudCodeModelFamily.displayOrder.compactMap { bestByFamily[$0] }
        let extras = bestByFamily
            .filter { !CloudCodeModelFamily.displayOrder.contains($0.key) }
            .map(\.value)
            .sorted { ($0.label ?? "") < ($1.label ?? "") }
        return ordered + extras
    }

    private static func mapCloudCodeBucket(_ bucket: [String: Any], label: String) -> RateWindow? {
        // Detail `retrieveUserQuota` rows are per-model remainingFraction (Cockpit).
        let resetTime = stringValue(bucket, keys: ["resetTime"])
        if let resetTime, resetTime.hasPrefix("1970-") { return nil }

        let usedPercent: Double
        if bucket["isExhausted"] as? Bool == true {
            usedPercent = 100
        } else {
            usedPercent = cloudCodeUsedPercent(
                remainingFraction: doubleValue(bucket, keys: ["remainingFraction"])
            )
        }
        let modelID = stringValue(bucket, keys: ["modelId", "model_id", "name", "bucketId"])
        let title = label.isEmpty ? (modelID ?? "Model") : label
        let resetsAt = parseISO8601(resetTime)
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil, // model pool residual — not a fixed 5h/weekly row
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
            label: title
        )
    }

    private static func mapCloudCodeQuotaInfo(_ quotaInfo: [String: Any], label: String) -> RateWindow? {
        if let resetTime = stringValue(quotaInfo, keys: ["resetTime"]), resetTime.hasPrefix("1970-") {
            return nil
        }
        let usedPercent: Double
        if quotaInfo["isExhausted"] as? Bool == true {
            usedPercent = 100
        } else {
            usedPercent = cloudCodeUsedPercent(
                remainingFraction: doubleValue(quotaInfo, keys: ["remainingFraction"])
            )
        }
        let resetsAt = parseISO8601(stringValue(quotaInfo, keys: ["resetTime"]))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { ResetCountdownFormatter.resetLine(for: $0) },
            label: label.isEmpty ? nil : label
        )
    }
}

// MARK: - Cloud Code model families

enum CloudCodeModelFamily: Hashable {
    case claudeOpus
    case claudeSonnet
    case claudeOther
    case gpt
    case geminiPro
    case geminiFlash
    case geminiOther
    case other(String)

    static let displayOrder: [CloudCodeModelFamily] = [
        .claudeOpus,
        .claudeSonnet,
        .claudeOther,
        .gpt,
        .geminiPro,
        .geminiFlash,
        .geminiOther,
    ]

    var displayName: String {
        switch self {
        case .claudeOpus: return "Claude Opus"
        case .claudeSonnet: return "Claude Sonnet"
        case .claudeOther: return "Claude"
        case .gpt: return "GPT-OSS"
        case .geminiPro: return "Gemini Pro"
        case .geminiFlash: return "Gemini Flash"
        case .geminiOther: return "Gemini"
        case .other(let name): return name
        }
    }

    static func classify(modelID: String) -> CloudCodeModelFamily {
        let id = modelID.lowercased()
        if id.contains("claude") || id.contains("anthropic") {
            if id.contains("opus") { return .claudeOpus }
            if id.contains("sonnet") { return .claudeSonnet }
            return .claudeOther
        }
        if id.contains("opus") {
            return .claudeOpus
        }
        if id.contains("sonnet") {
            return .claudeSonnet
        }
        if id.contains("gpt") || id.hasPrefix("chat_") {
            return .gpt
        }
        if id.contains("flash") || id.hasPrefix("tab_") {
            return .geminiFlash
        }
        if id.contains("pro") && (id.contains("gemini") || id.contains("agent")) {
            return .geminiPro
        }
        if id.contains("pro") {
            return .geminiPro
        }
        if id.contains("gemini") || id.contains("gemma") {
            return .geminiOther
        }
        return .other(prettyModelName(modelID))
    }

    private static func prettyModelName(_ modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "models/", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private extension RateWindow {
    func withLabel(_ label: String) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            label: label,
            remainingValue: remainingValue,
            totalValue: totalValue,
            unitLabel: unitLabel,
            displayStyle: displayStyle
        )
    }
}

// Keep helper methods that lived below the old closing brace reachable via extension on NativeUsageFetcher.
extension NativeUsageFetcher {
    // MARK: - Grok billing protobuf helpers (continued after Cloud Code section)

    // MARK: - Grok billing protobuf helpers

    struct GrokBillingParseResult {
        let usedPercent: Double
        let resetsAt: Date?
        /// Absolute remaining credits when the billing payload exposes them.
        let remainingCredits: Double?
        let totalCredits: Double?
    }

    private static func grokGRPCError(
        from data: Data,
        http: HTTPURLResponse? = nil,
        payload: [String: Any] = [:]
    ) -> String? {
        var fields = grokGRPCWebTrailerFields(from: data)
        // Empty-body failures put grpc-status on HTTP headers (CodexBar does the same).
        if let http {
            for (key, value) in http.allHeaderFields {
                let k = String(describing: key).lowercased()
                guard k.hasPrefix("grpc-") else { continue }
                if fields[k] == nil {
                    fields[k] = String(describing: value)
                        .removingPercentEncoding?
                        .replacingOccurrences(of: "+", with: " ")
                        ?? String(describing: value)
                }
            }
        }
        guard let rawStatus = fields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else { return nil }

        let message = (fields["grpc-message"] ?? "Billing request failed")
            .removingPercentEncoding?
            .replacingOccurrences(of: "+", with: " ")
            ?? "Billing request failed"
        let lower = message.lowercased()
        if status == 16
            || status == 7
            || lower.contains("unauthenticated")
            || lower.contains("bad-credentials")
            || lower.contains("could not be validated")
        {
            return "Grok billing rejected this token — run `grok login` (cli-proxy xAI tokens often cannot read SuperGrok usage)"
        }
        if status == 13 || status == 14 || status == 8 {
            return "Grok billing temporarily unavailable (grpc \(status)) — retry shortly"
        }
        if message.isEmpty || lower == "billing request failed" {
            return "Grok billing error (grpc \(status)) — retry or run `grok login`"
        }
        return message
    }

    static func parseGrokBillingResponse(_ data: Data, now: Date = Date()) -> GrokBillingParseResult? {
        var payloads = grokGRPCWebDataFrames(from: data)
        if payloads.isEmpty, grokLooksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { return nil }

        var scan = GrokProtobufScan()
        for payload in payloads {
            scan.merge(grokScanProtobuf(payload, depth: 0))
        }

        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path.last == 1 && field.value.isFinite && field.value >= 0 && field.value <= 100
            }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset = futureResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min() ?? futureResetFields
            .map(\.date)
            .min()

        let hasUsagePeriod = scan.varintFields.contains { field in
            field.path.starts(with: [1, 6]) ||
                (field.path == [1, 8, 1] && (field.value == 1 || field.value == 2))
        }
        let noUsageYet = parsedPercent == nil &&
            scan.fixed32Fields.isEmpty &&
            reset != nil &&
            hasUsagePeriod

        // Grok product default is percentage (not absolute credits).
        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else { return nil }
        return GrokBillingParseResult(
            usedPercent: percent,
            resetsAt: reset,
            remainingCredits: nil,
            totalCredits: nil
        )
    }

    private struct GrokProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }

        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: GrokProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func grokLooksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    static func grokGRPCWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    static func grokGRPCWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0,
               let text = String(data: Data(bytes[start..<end]), encoding: .utf8)
            {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    private static func grokScanProtobuf(_ data: Data, depth: Int) -> GrokProtobufScan {
        grokScanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func grokScanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: GrokProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = GrokProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = grokReadVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = grokReadVarint(bytes, index: &index) {
                    scan.varintFields.append(GrokProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = grokReadVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = grokScanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder
                    )
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(GrokProtobufScan.Fixed32Field(
                    path: fieldPath,
                    value: Float(bitPattern: bitPattern),
                    order: nextOrder
                ))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }

        return (scan, nextOrder)
    }

    private static func grokReadVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
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
