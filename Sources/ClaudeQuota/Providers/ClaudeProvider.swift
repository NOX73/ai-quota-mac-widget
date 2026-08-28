import Foundation
import Combine

@MainActor
public final class ClaudeProvider: ObservableObject, QuotaProvider {
    public let id = "claude"
    public let displayName = "Claude"

    @Published public private(set) var status: ProviderStatus = .disconnected
    @Published public private(set) var periods: [QuotaPeriod] = []
    @Published public private(set) var isLoading: Bool = false

    public let authFlow = ClaudeAuthFlow()

    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // All of this provider's credentials live under one Keychain item instead of one item per
    // field — each distinct item needs its own one-time "Always Allow" authorization from
    // macOS, so one item per provider means one prompt per provider instead of three.
    private let stateKey = "claude_oauth_state"
    private static let legacyTokenKey = "claude_oauth_token"
    private static let legacyRefreshTokenKey = "claude_oauth_refresh_token"
    private static let legacyExpiresAtKey = "claude_oauth_expires_at"

    private struct StoredState: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Double?
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
            expiresAt: legacyExpiresAt
        ))
        KeychainService.shared.delete(key: Self.legacyTokenKey)
        KeychainService.shared.delete(key: Self.legacyRefreshTokenKey)
        KeychainService.shared.delete(key: Self.legacyExpiresAtKey)
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

    private func saveTokenSet(_ tokenSet: ClaudeTokenSet) {
        var state = loadState() ?? StoredState(accessToken: "", refreshToken: nil, expiresAt: nil)
        state.accessToken = tokenSet.accessToken
        if let refreshToken = tokenSet.refreshToken {
            state.refreshToken = refreshToken
        }
        state.expiresAt = tokenSet.expiresAt?.timeIntervalSince1970
        saveState(state)
        status = .connected
    }

    private func getExpiresAt() -> Date? {
        guard let interval = loadState()?.expiresAt else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// Exchanges the stored refresh token for a new access token and persists the result.
    /// Returns false if there's no refresh token or the refresh request itself fails.
    private func attemptTokenRefresh() async -> Bool {
        guard let refreshToken = loadState()?.refreshToken, !refreshToken.isEmpty else {
            return false
        }
        do {
            let tokenSet = try await ClaudeAuthFlow.refreshAccessToken(refreshToken: refreshToken)
            saveTokenSet(tokenSet)
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
        if isConfigured {
            status = .connected
        } else {
            status = .disconnected
        }
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

        let httpStatus = await fetchUsage(token: token)

        if httpStatus == 401 {
            if await attemptTokenRefresh(), let refreshedToken = getToken() {
                let retryStatus = await fetchUsage(token: refreshedToken)
                if retryStatus == 401 {
                    // The refreshed token is still rejected by the usage endpoint — don't leave
                    // the provider stuck showing "Connected" with permanently empty periods.
                    status = .requiresReauth
                }
            } else {
                status = .requiresReauth
            }
        }
    }

    /// Fetches quota usage with the given token and updates `status`/`periods` accordingly.
    /// Returns the HTTP status code (or -1 on a transport-level failure) so callers can decide
    /// whether a 401 is worth retrying after a token refresh.
    private func fetchUsage(token: String) async -> Int {
        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

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

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let usage = try decoder.decode(UsageResponse.self, from: data)

            var newPeriods: [QuotaPeriod] = []

            if let session = usage.fiveHour {
                newPeriods.append(QuotaPeriod(
                    id: "claude_session",
                    label: "Session (5h)",
                    utilization: session.utilization,
                    resetsAt: session.resetsAtDate
                ))
            }

            if let weekly = usage.sevenDay {
                newPeriods.append(QuotaPeriod(
                    id: "claude_weekly",
                    label: "Weekly (7d)",
                    utilization: weekly.utilization,
                    resetsAt: weekly.resetsAtDate
                ))
            }

            if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                newPeriods.append(QuotaPeriod(
                    id: "claude_opus",
                    label: "Weekly Opus",
                    utilization: opus.utilization,
                    resetsAt: opus.resetsAtDate
                ))
            }

            if let sonnet = usage.sevenDaySonnet, sonnet.utilization > 0 {
                newPeriods.append(QuotaPeriod(
                    id: "claude_sonnet",
                    label: "Weekly Sonnet",
                    utilization: sonnet.utilization,
                    resetsAt: sonnet.resetsAtDate
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
}

// Internal decodable models for Anthropic OAuth usage API
private struct UsageResponse: Codable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDayOpus: UsagePeriod?
    let sevenDaySonnet: UsagePeriod?
    let sevenDayCowork: UsagePeriod?
}

private struct UsagePeriod: Codable {
    let utilization: Double
    let resetsAt: String?

    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}
