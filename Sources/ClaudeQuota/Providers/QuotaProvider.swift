import Foundation
import Combine

@MainActor
public protocol QuotaProvider: AnyObject, ObservableObject {
    var id: String { get }
    var displayName: String { get }
    var iconName: String { get }
    var status: ProviderStatus { get }
    var periods: [QuotaPeriod] { get }
    var isLoading: Bool { get }
    var isConfigured: Bool { get }

    func refresh() async
    func logout()
}

