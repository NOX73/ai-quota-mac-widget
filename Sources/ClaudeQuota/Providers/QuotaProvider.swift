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
    /// the worst (highest) of its periods' utilization, e.g. max(5h session, 7d weekly) for
    /// Claude — whichever limit you'll hit first.
    var worstUtilization: Double? {
        periods.compactMap(\.utilization).max()
    }
}

