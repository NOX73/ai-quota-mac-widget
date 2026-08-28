import Foundation
import Combine

@MainActor
public final class OpenAIProvider: ObservableObject, QuotaProvider {
    public let id = "openai"
    public let displayName = "Codex"

    @Published public private(set) var status: ProviderStatus = .disconnected
    @Published public private(set) var periods: [QuotaPeriod] = []
    @Published public private(set) var isLoading: Bool = false

    public let authFlow = CodexAuthFlow()

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // All of this provider's credentials live under one Keychain item instead of one item per
    // field — each distinct item needs its own one-time "Always Allow" authorization from
    // macOS, so one item per provider means one prompt per provider instead of three.
    private let stateKey = "openai_oauth_state"

    private struct StoredState: Codable {
        var accessToken: String
        var refreshToken: String?
        var accountID: String?
    }

    public init() {
        checkInitialStatus()
    }

    public var isConfigured: Bool {
        getToken() != nil
    }

    public func getToken() -> String? {
        let token = loadState()?.accessToken
        return (token?.isEmpty ?? true) ? nil : token
    }

    private func getAccountID() -> String? {
        loadState()?.accountID
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

    private func saveTokenSet(_ tokenSet: CodexTokenSet) {
        var state = loadState() ?? StoredState(accessToken: "", refreshToken: nil, accountID: nil)
        state.accessToken = tokenSet.accessToken
        if let refreshToken = tokenSet.refreshToken {
            state.refreshToken = refreshToken
        }
        if let idToken = tokenSet.idToken, let accountID = Self.accountID(fromIDToken: idToken) {
            state.accountID = accountID
        }
        saveState(state)
        status = .connected
    }

    /// Exchanges the stored refresh token for a new access token and persists the result.
    /// Returns false if there's no refresh token or the refresh request itself fails.
    private func attemptTokenRefresh() async -> Bool {
        guard let refreshToken = loadState()?.refreshToken, !refreshToken.isEmpty else {
            return false
        }
        do {
            let tokenSet = try await CodexAuthFlow.refreshAccessToken(refreshToken: refreshToken)
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

        // Refresh proactively if the access token (a JWT) is at or near expiry.
        if let token = getToken(), Self.isTokenNearExpiry(token) {
            _ = await attemptTokenRefresh()
        }

        guard let token = getToken() else {
            status = .disconnected
            periods = []
            return
        }

        let httpStatus = await fetchUsage(token: token, accountID: getAccountID())

        if httpStatus == 401 {
            if await attemptTokenRefresh(), let refreshedToken = getToken() {
                let retryStatus = await fetchUsage(token: refreshedToken, accountID: getAccountID())
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
    private func fetchUsage(token: String, accountID: String?) async -> Int {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

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
            let usage = try decoder.decode(WhamUsageResponse.self, from: data)

            var newPeriods: [QuotaPeriod] = []

            if let primary = usage.rateLimit?.primaryWindow {
                newPeriods.append(QuotaPeriod(
                    id: "codex_session",
                    label: "Session (\(Self.windowLabel(seconds: primary.limitWindowSeconds, fallback: "5h")))",
                    utilization: primary.usedPercent,
                    resetsAt: primary.resetsAtDate
                ))
            }

            if let secondary = usage.rateLimit?.secondaryWindow {
                newPeriods.append(QuotaPeriod(
                    id: "codex_weekly",
                    label: Self.windowLabel(seconds: secondary.limitWindowSeconds, fallback: "Weekly"),
                    utilization: secondary.usedPercent,
                    resetsAt: secondary.resetsAtDate
                ))
            }

            if newPeriods.isEmpty {
                newPeriods.append(QuotaPeriod(
                    id: "codex_active",
                    label: "ChatGPT Subscription",
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

    private static func windowLabel(seconds: Double?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }
        let hours = seconds / 3600
        if hours <= 24 {
            return "\(Int(hours.rounded()))h"
        }
        let days = hours / 24
        if days <= 8 {
            return "Weekly"
        }
        return "Monthly"
    }

    /// Decodes the `exp` claim from a JWT access token and reports whether it's within 60s of
    /// expiring (or already unreadable, in which case we don't force a refresh).
    private static func isTokenNearExpiry(_ jwt: String) -> Bool {
        guard let payload = decodeJWTPayload(jwt),
              let exp = payload["exp"] as? Double else {
            return false
        }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 60
    }

    /// Extracts the ChatGPT account id from the `https://api.openai.com/auth` claim of an id_token,
    /// mirroring codex-rs's `parse_chatgpt_jwt_claims`.
    private static func accountID(fromIDToken idToken: String) -> String? {
        guard let payload = decodeJWTPayload(idToken),
              let authClaims = payload["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return authClaims["chatgpt_account_id"] as? String
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// Internal decodable models for OpenAI's ChatGPT/Codex "wham" usage API.
private struct WhamUsageResponse: Codable {
    let rateLimit: RateLimit?
    let planType: String?
}

private struct RateLimit: Codable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
}

private struct UsageWindow: Codable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAt: Double?

    var resetsAtDate: Date? {
        guard let resetAt else { return nil }
        return Date(timeIntervalSince1970: resetAt)
    }
}
