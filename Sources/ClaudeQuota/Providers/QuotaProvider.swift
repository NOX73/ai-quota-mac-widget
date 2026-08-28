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
    /// The single percentage summarizing this provider for compact display (menu bar, etc):
    /// the smaller of its periods' utilization, e.g. min(5h session, 7d weekly) for Claude.
    var minUtilization: Double? {
        periods.compactMap(\.utilization).min()
    }
}

