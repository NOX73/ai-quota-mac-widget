import Foundation
import Combine

@MainActor
public final class AggregateQuotaService: ObservableObject {
    @Published public private(set) var providers: [any QuotaProvider] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var currentInterval: TimeInterval = 180

    /// Utilization % at/above which a period's color switches from green to yellow.
    @Published public private(set) var warningThreshold: Double
    /// Utilization % at/above which a period's color switches from yellow to red.
    @Published public private(set) var criticalThreshold: Double
    /// Whether the menu bar shows each connected provider's logomark next to its percentage.
    @Published public private(set) var showTrayIcon: Bool
    /// Whether the menu bar percentage is colored by utilization, or plain menu bar text color.
    @Published public private(set) var trayColorEnabled: Bool
    /// When true, utilization below the warning threshold is shown in neutral color instead of
    /// green — color only shows up once something actually needs attention.
    @Published public private(set) var neutralWhenNormal: Bool

    public let claudeProvider = ClaudeProvider()
    public let openAIProvider = OpenAIProvider()
    public let googleAIProvider = GoogleAIProvider()

    private var timer: Timer?
    private var providerSubscriptions: [AnyCancellable] = []
    private static let minInterval: TimeInterval = 180   // 3 min
    private static let maxInterval: TimeInterval = 1800  // 30 min

    private enum DefaultsKey {
        static let warningThreshold = "quota.warningThreshold"
        static let criticalThreshold = "quota.criticalThreshold"
        static let showTrayIcon = "quota.showTrayIcon"
        static let trayColorEnabled = "quota.trayColorEnabled"
        static let neutralWhenNormal = "quota.neutralWhenNormal"
    }

    public init() {
        let defaults = UserDefaults.standard
        self.warningThreshold = (defaults.object(forKey: DefaultsKey.warningThreshold) as? Double) ?? 50
        self.criticalThreshold = (defaults.object(forKey: DefaultsKey.criticalThreshold) as? Double) ?? 80
        self.showTrayIcon = (defaults.object(forKey: DefaultsKey.showTrayIcon) as? Bool) ?? true
        self.trayColorEnabled = (defaults.object(forKey: DefaultsKey.trayColorEnabled) as? Bool) ?? true
        self.neutralWhenNormal = (defaults.object(forKey: DefaultsKey.neutralWhenNormal) as? Bool) ?? false

        self.providers = [claudeProvider, openAIProvider, googleAIProvider]

        // Forward each provider's own @Published changes (status, periods, ...) so that
        // views observing only `AggregateQuotaService` re-render on connect/disconnect,
        // not just when the aggregate service's own properties change.
        claudeProvider.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &providerSubscriptions)
        openAIProvider.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &providerSubscriptions)
        googleAIProvider.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &providerSubscriptions)
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

    public func setWarningThreshold(_ value: Double) {
        warningThreshold = min(value, criticalThreshold - 1)
        UserDefaults.standard.set(warningThreshold, forKey: DefaultsKey.warningThreshold)
    }

    public func setCriticalThreshold(_ value: Double) {
        criticalThreshold = max(value, warningThreshold + 1)
        UserDefaults.standard.set(criticalThreshold, forKey: DefaultsKey.criticalThreshold)
    }

    public func setShowTrayIcon(_ value: Bool) {
        showTrayIcon = value
        UserDefaults.standard.set(value, forKey: DefaultsKey.showTrayIcon)
    }

    public func setTrayColorEnabled(_ value: Bool) {
        trayColorEnabled = value
        UserDefaults.standard.set(value, forKey: DefaultsKey.trayColorEnabled)
    }

    public func setNeutralWhenNormal(_ value: Bool) {
        neutralWhenNormal = value
        UserDefaults.standard.set(value, forKey: DefaultsKey.neutralWhenNormal)
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
}

