import Foundation
import Combine

@MainActor
public final class ClaudeProvider: ObservableObject, QuotaProvider {
    public let id = "claude"
    public let displayName = "Claude (Anthropic)"
    public let iconName = "sparkles"

    @Published public private(set) var status: ProviderStatus = .disconnected
    @Published public private(set) var periods: [QuotaPeriod] = []
    @Published public private(set) var isLoading: Bool = false

    public let authFlow = ClaudeAuthFlow()

    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let tokenKey = "claude_oauth_token"
    private let refreshTokenKey = "claude_oauth_refresh_token"
    private let expiresAtKey = "claude_oauth_expires_at"

    public init() {
        checkInitialStatus()
    }

    public var isConfigured: Bool {
        getToken() != nil
    }

    public func getToken() -> String? {
        guard let token = KeychainService.shared.load(key: tokenKey), !token.isEmpty else {
            return nil
        }
        return token
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
        _ = KeychainService.shared.save(key: tokenKey, value: tokenSet.accessToken)
        if let refreshToken = tokenSet.refreshToken {
            _ = KeychainService.shared.save(key: refreshTokenKey, value: refreshToken)
        }
        if let expiresAt = tokenSet.expiresAt {
            _ = KeychainService.shared.save(key: expiresAtKey, value: String(expiresAt.timeIntervalSince1970))
        } else {
            KeychainService.shared.delete(key: expiresAtKey)
        }
        status = .connected
    }

    private func getExpiresAt() -> Date? {
        guard let raw = KeychainService.shared.load(key: expiresAtKey), let interval = Double(raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    /// Exchanges the stored refresh token for a new access token and persists the result.
    /// Returns false if there's no refresh token or the refresh request itself fails.
    private func attemptTokenRefresh() async -> Bool {
        guard let refreshToken = KeychainService.shared.load(key: refreshTokenKey), !refreshToken.isEmpty else {
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
        KeychainService.shared.delete(key: tokenKey)
        KeychainService.shared.delete(key: refreshTokenKey)
        KeychainService.shared.delete(key: expiresAtKey)
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
