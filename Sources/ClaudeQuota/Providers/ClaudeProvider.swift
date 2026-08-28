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

    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {
        checkInitialStatus()
    }

    public var isConfigured: Bool {
        getToken() != nil
    }

    public func getToken() -> String? {
        if let token = KeychainService.shared.load(key: "claude_oauth_token"), !token.isEmpty {
            return token
        }
        return KeychainService.shared.loadLegacyClaudeCodeToken()
    }

    public func saveToken(_ token: String) {
        _ = KeychainService.shared.save(key: "claude_oauth_token", value: token)
        status = .connected
        Task {
            await refresh()
        }
    }

    public func logout() {
        KeychainService.shared.delete(key: "claude_oauth_token")
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
        guard let token = getToken() else {
            status = .disconnected
            periods = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid server response")
                return
            }

            if http.statusCode == 401 {
                status = .requiresReauth
                return
            }

            if http.statusCode == 429 {
                status = .error("Rate limited (HTTP 429)")
                return
            }

            guard http.statusCode == 200 else {
                status = .error("HTTP \(http.statusCode)")
                return
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
        } catch {
            self.status = .error(error.localizedDescription)
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

