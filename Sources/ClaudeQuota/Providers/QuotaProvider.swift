import Foundation
import Combine

@MainActor
public protocol QuotaProvider: AnyObject, ObservableObject {
    var id: String { get }
    var displayName: String { get }
    var status: ProviderStatus { get }
    var periods: [QuotaPeriod] { get }
    var isLoading: Bool { get }
    var isConfigured: Bool { get }

    func refresh() async
    func logout()
}

public extension QuotaProvider {
    /// The provider's shortest/most-immediate period (e.g. the 5h session for Claude), which
    /// every provider lists first — the number people actually watch minute to minute, since
    /// the longer windows (weekly, per-model) rarely bind first.
    var primaryUtilization: Double? {
        periods.first?.utilization
    }

    /// The worst of the *other* periods (weekly, per-model, …) — shown as a secondary signal
    /// rather than folded into the headline number, so a high weekly reading doesn't drown out
    /// the session percentage that's usually what's actually about to block.
    var secondaryUtilization: Double? {
        periods.dropFirst().compactMap(\.utilization).max()
    }
}

