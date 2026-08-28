import Foundation
import Combine

@MainActor
public final class GoogleAIProvider: ObservableObject, QuotaProvider {
    public let id = "google"
    public let displayName = "Gemini"

    @Published public private(set) var status: ProviderStatus = .disconnected
    @Published public private(set) var periods: [QuotaPeriod] = []
    @Published public private(set) var isLoading: Bool = false

    private let fetchConfigURL = URL(string: "https://cloudcode-pa.googleapis.com/v1beta/config:fetch")!

    public init() {
        checkInitialStatus()
    }

    public var isConfigured: Bool {
        getToken() != nil
    }

    public func getToken() -> String? {
        KeychainService.shared.load(key: "google_oauth_token")
    }

    public func logout() {
        KeychainService.shared.delete(key: "google_oauth_token")
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

        var request = URLRequest(url: fetchConfigURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid response")
                return
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                status = .requiresReauth
                return
            }

            guard http.statusCode == 200 else {
                status = .error("HTTP \(http.statusCode)")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var newPeriods: [QuotaPeriod] = []

                if let entitlement = json["entitlement"] as? [String: Any] {
                    if let geminiUtil = entitlement["geminiWeeklyUtilization"] as? Double {
                        newPeriods.append(QuotaPeriod(
                            id: "google_gemini",
                            label: "Weekly Gemini",
                            utilization: geminiUtil
                        ))
                    }

                    if let claudeUtil = entitlement["claudeWeeklyUtilization"] as? Double {
                        newPeriods.append(QuotaPeriod(
                            id: "google_claude",
                            label: "Weekly Claude",
                            utilization: claudeUtil
                        ))
                    }

                    if let gptUtil = entitlement["gptWeeklyUtilization"] as? Double {
                        newPeriods.append(QuotaPeriod(
                            id: "google_gpt",
                            label: "Weekly GPT",
                            utilization: gptUtil
                        ))
                    }
                }

                if newPeriods.isEmpty {
                    newPeriods.append(QuotaPeriod(
                        id: "google_subscription",
                        label: "Google AI Plus Plan",
                        utilization: 0.0,
                        details: "Active"
                    ))
                }

                self.periods = newPeriods
                self.status = .connected
            } else {
                status = .error("Failed to parse config")
            }
        } catch {
            self.status = .error(error.localizedDescription)
        }
    }
}

