import Foundation
import Combine
import SwiftUI

@MainActor
public final class AggregateQuotaService: ObservableObject {
    @Published public private(set) var providers: [any QuotaProvider] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var currentInterval: TimeInterval = 180

    public let claudeProvider = ClaudeProvider()
    public let openAIProvider = OpenAIProvider()
    public let googleAIProvider = GoogleAIProvider()

    private var timer: Timer?
    private static let minInterval: TimeInterval = 180   // 3 min
    private static let maxInterval: TimeInterval = 1800  // 30 min

    public init() {
        self.providers = [claudeProvider, openAIProvider, googleAIProvider]
    }

    public func startPolling() {
        Task {
            await refreshAll()
            scheduleNext()
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public func manualRefresh() {
        currentInterval = Self.minInterval
        Task {
            await refreshAll()
            scheduleNext()
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
                self?.scheduleNext()
            }
        }
    }

    public func refreshAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.claudeProvider.refresh() }
            group.addTask { await self.openAIProvider.refresh() }
            group.addTask { await self.googleAIProvider.refresh() }
        }

        self.lastUpdated = Date()
    }

    // Formatting for MenuBar title
    public var menuBarTitle: String {
        var parts: [String] = []

        if claudeProvider.status.isConnected, let maxClaude = claudeProvider.periods.compactMap(\.utilization).max() {
            parts.append("◆ \(Int(maxClaude))%")
        } else if claudeProvider.status.isConnected {
            parts.append("◆ –%")
        }

        if openAIProvider.status.isConnected, let maxOpenAI = openAIProvider.periods.compactMap(\.utilization).max() {
            parts.append("⬡ \(Int(maxOpenAI))%")
        } else if openAIProvider.status.isConnected {
            parts.append("⬡ –%")
        }

        if googleAIProvider.status.isConnected, let maxGoogle = googleAIProvider.periods.compactMap(\.utilization).max() {
            parts.append("✦ \(Int(maxGoogle))%")
        } else if googleAIProvider.status.isConnected {
            parts.append("✦ –%")
        }

        if parts.isEmpty {
            return "◆ AI Quota"
        }

        return parts.joined(separator: "  ")
    }

    public var maxUtilization: Double {
        let allUtils = providers.flatMap { $0.periods }.compactMap { $0.utilization }
        return allUtils.max() ?? 0
    }
}

