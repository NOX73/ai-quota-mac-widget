import Foundation
import Combine

@MainActor
public final class AntigravityProvider: ObservableObject, QuotaProvider {
    public let id = "antigravity"
    public let displayName = "Antigravity"

    @Published public private(set) var status: ProviderStatus = .disconnected
    @Published public private(set) var periods: [QuotaPeriod] = []
    @Published public private(set) var isLoading: Bool = false

    public let authFlow = AntigravityAuthFlow()

    // Google's Cloud Code Assist backend — the same host the Antigravity CLI/IDE talk to.
    private let cloudCodeBase = "https://cloudcode-pa.googleapis.com"

    /// Without an explicit `platform` in the request body, the backend infers it from the
    /// `User-Agent` header — and rejects whatever it infers from URLSession's default macOS
    /// UA with a 400 ("Invalid value at 'metadata.platform' ... \"MACOS\""). Claiming Windows
    /// sidesteps that (same workaround the reference community tooling for this API uses).
    private static let cloudCodeUserAgent = "antigravity/windows/amd64"

    // All of this provider's credentials live under one Keychain item instead of one item per
    // field — each distinct item needs its own one-time "Always Allow" authorization from
    // macOS, so one item per provider means one prompt per provider instead of four.
    private let stateKey = "antigravity_oauth_state"
    private static let legacyTokenKey = "antigravity_oauth_token"
    private static let legacyRefreshTokenKey = "antigravity_oauth_refresh_token"
    private static let legacyExpiresAtKey = "antigravity_oauth_expires_at"
    private static let legacyProjectIDKey = "antigravity_project_id"

    private struct StoredState: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Double?
        var projectID: String?
    }

    public init() {
        migrateLegacyKeysIfNeeded()
        checkInitialStatus()
    }

    public var isConfigured: Bool {
        getToken() != nil
    }

    public func getToken() -> String? {
        let token = loadState()?.accessToken
        return (token?.isEmpty ?? true) ? nil : token
    }

    private func getProjectID() -> String? {
        loadState()?.projectID
    }

    private func getExpiresAt() -> Date? {
        guard let interval = loadState()?.expiresAt else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func loadState() -> StoredState? {
        guard let raw = KeychainService.shared.load(key: stateKey), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredState.self, from: data)
    }

    private func saveState(_ state: StoredState) {
        guard let data = try? JSONEncoder().encode(state), let raw = String(data: data, encoding: .utf8) else {
            return
        }
        _ = KeychainService.shared.save(key: stateKey, value: raw)
    }

    /// One-time migration from the old one-item-per-field scheme to the consolidated one above.
    private func migrateLegacyKeysIfNeeded() {
        guard loadState() == nil,
              let legacyToken = KeychainService.shared.load(key: Self.legacyTokenKey), !legacyToken.isEmpty else {
            return
        }
        let legacyExpiresAt = KeychainService.shared.load(key: Self.legacyExpiresAtKey).flatMap(Double.init)
        saveState(StoredState(
            accessToken: legacyToken,
            refreshToken: KeychainService.shared.load(key: Self.legacyRefreshTokenKey),
            expiresAt: legacyExpiresAt,
            projectID: KeychainService.shared.load(key: Self.legacyProjectIDKey)
        ))
        KeychainService.shared.delete(key: Self.legacyTokenKey)
        KeychainService.shared.delete(key: Self.legacyRefreshTokenKey)
        KeychainService.shared.delete(key: Self.legacyExpiresAtKey)
        KeychainService.shared.delete(key: Self.legacyProjectIDKey)
    }

    public func startOAuthLogin() {
        authFlow.startAuthorization { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let tokenSet):
                    self?.saveTokenSet(tokenSet)
                    await self?.refresh()
                case .failure(let error):
                    self?.status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func saveTokenSet(_ tokenSet: AntigravityTokenSet) {
        var state = loadState() ?? StoredState(accessToken: "", refreshToken: nil, expiresAt: nil, projectID: nil)
        state.accessToken = tokenSet.accessToken
        if let refreshToken = tokenSet.refreshToken {
            state.refreshToken = refreshToken
        }
        if let expiresIn = tokenSet.expiresIn {
            state.expiresAt = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
        }
        saveState(state)
        status = .connected
    }

    /// Exchanges the stored refresh token for a new access token and persists the result.
    /// Google's refresh grant normally omits `refresh_token` (no rotation), so the existing
    /// one is kept when that happens. Returns false if there's no refresh token or the refresh
    /// request itself fails.
    private func attemptTokenRefresh() async -> Bool {
        guard let refreshToken = loadState()?.refreshToken, !refreshToken.isEmpty else {
            return false
        }
        do {
            let tokenSet = try await AntigravityAuthFlow.refreshAccessToken(refreshToken: refreshToken)
            saveTokenSet(AntigravityTokenSet(
                accessToken: tokenSet.accessToken,
                refreshToken: tokenSet.refreshToken ?? refreshToken,
                expiresIn: tokenSet.expiresIn
            ))
            return true
        } catch {
            return false
        }
    }

    public func logout() {
        authFlow.stopAuthorization()
        KeychainService.shared.delete(key: stateKey)
        periods = []
        status = .disconnected
    }

    private func checkInitialStatus() {
        status = isConfigured ? .connected : .disconnected
    }

    public func refresh() async {
        guard getToken() != nil else {
            status = .disconnected
            periods = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Refresh proactively if the access token is at or near expiry.
        if let expiresAt = getExpiresAt(), expiresAt.timeIntervalSinceNow < 60 {
            _ = await attemptTokenRefresh()
        }

        guard let token = getToken() else {
            status = .disconnected
            periods = []
            return
        }

        // The Cloud Code project id is resolved once per account and cached — quota lookups
        // work without it too, but a resolved id makes the backend's response more reliable.
        if getProjectID() == nil, let projectID = await fetchProjectID(token: token), var state = loadState() {
            state.projectID = projectID
            saveState(state)
        }

        let httpStatus = await fetchQuota(token: token, projectID: getProjectID())

        if httpStatus == 401 {
            if await attemptTokenRefresh(), let refreshedToken = getToken() {
                let retryStatus = await fetchQuota(token: refreshedToken, projectID: getProjectID())
                if retryStatus == 401 {
                    status = .requiresReauth
                }
            } else {
                status = .requiresReauth
            }
        }
    }

    private func fetchProjectID(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "\(cloudCodeBase)/v1internal:loadCodeAssist")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.cloudCodeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "ANTIGRAVITY"]
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let projectID = json["cloudaicompanionProject"] as? String, !projectID.isEmpty {
            return projectID
        }
        if let project = json["cloudaicompanionProject"] as? [String: Any], let id = project["id"] as? String {
            return id
        }
        return nil
    }

    /// Fetches quota with the given token and updates `status`/`periods` accordingly. Returns
    /// the HTTP status code (or -1 on a transport-level failure) so callers can decide whether a
    /// 401 is worth retrying after a token refresh.
    private func fetchQuota(token: String, projectID: String?) async -> Int {
        var request = URLRequest(url: URL(string: "\(cloudCodeBase)/v1internal:fetchAvailableModels")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.cloudCodeUserAgent, forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [:]
        if let projectID {
            body["project"] = projectID
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid server response")
                return -1
            }

            if http.statusCode == 401 {
                return 401
            }

            if http.statusCode == 429 {
                status = .error("Rate limited (HTTP 429)")
                return http.statusCode
            }

            guard http.statusCode == 200 else {
                status = .error("HTTP \(http.statusCode)")
                return http.statusCode
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [String: Any] else {
                status = .error("Failed to parse quota response")
                return http.statusCode
            }

            var groups: [String: (remaining: Double, resetsAt: Date?)] = [:]
            for (modelName, value) in models {
                guard let info = value as? [String: Any],
                      let quotaInfo = info["quotaInfo"] as? [String: Any],
                      let group = Self.classifyGroup(modelName) else { continue }
                let remainingFraction = quotaInfo["remainingFraction"] as? Double ?? 0
                let resetsAt = (quotaInfo["resetTime"] as? String).flatMap(Self.parseDate)

                if let existing = groups[group] {
                    groups[group] = (
                        min(existing.remaining, remainingFraction),
                        [existing.resetsAt, resetsAt].compactMap { $0 }.min()
                    )
                } else {
                    groups[group] = (remainingFraction, resetsAt)
                }
            }

            var newPeriods: [QuotaPeriod] = []
            for (groupID, label) in [("claude", "Claude"), ("gemini-pro", "Gemini 3 Pro"), ("gemini-flash", "Gemini 3 Flash")] {
                guard let entry = groups[groupID] else { continue }
                newPeriods.append(QuotaPeriod(
                    id: "antigravity_\(groupID)",
                    label: label,
                    utilization: (1 - entry.remaining) * 100,
                    resetsAt: entry.resetsAt
                ))
            }

            if newPeriods.isEmpty {
                newPeriods.append(QuotaPeriod(
                    id: "antigravity_active",
                    label: "Antigravity Subscription",
                    utilization: 0.0,
                    details: "Active"
                ))
            }

            self.periods = newPeriods
            self.status = .connected
            return 200
        } catch {
            self.status = .error(error.localizedDescription)
            return -1
        }
    }

    /// Groups a raw model name (e.g. "claude-opus-4-5-thinking", "gemini-3-pro") into the
    /// coarse buckets Antigravity actually meters quota by.
    private static func classifyGroup(_ modelName: String) -> String? {
        let lower = modelName.lowercased()
        if lower.contains("claude") { return "claude" }
        guard lower.contains("gemini-3") else { return nil }
        return lower.contains("flash") ? "gemini-flash" : "gemini-pro"
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
