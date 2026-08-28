import Foundation
import Combine

@MainActor
public final class OpenAIProvider: ObservableObject, QuotaProvider {
    public let id = "openai"
    public let displayName = "Codex"

    @Published public private(set) var status: ProviderStatus = .disconnected
    @Published public private(set) var periods: [QuotaPeriod] = []
    @Published public private(set) var isLoading: Bool = false

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {
        checkInitialStatus()
    }

    public var isConfigured: Bool {
        getToken() != nil
    }

    public func getToken() -> String? {
        KeychainService.shared.load(key: "openai_session_token")
    }

    public func logout() {
        KeychainService.shared.delete(key: "openai_session_token")
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

        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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

                if let cap = json["cap"] as? Double, let used = json["used"] as? Double, cap > 0 {
                    let pct = (used / cap) * 100.0
                    newPeriods.append(QuotaPeriod(
                        id: "gpt_messages",
                        label: "ChatGPT Window",
                        utilization: pct,
                        details: "\(Int(used))/\(Int(cap)) msgs"
                    ))
                } else {
                    // Generic active indicator when usage cap details are in nested objects
                    newPeriods.append(QuotaPeriod(
                        id: "gpt_active",
                        label: "ChatGPT Subscription",
                        utilization: 0.0,
                        details: "Active"
                    ))
                }

                self.periods = newPeriods
                self.status = .connected
            } else {
                status = .error("Failed to parse response")
            }
        } catch {
            self.status = .error(error.localizedDescription)
        }
    }
}

