import Foundation

public struct QuotaPeriod: Identifiable, Sendable {
    public var id: String
    public var label: String
    public var utilization: Double? // 0.0 ... 100.0
    public var resetsAt: Date?
    public var details: String?

    public init(id: String, label: String, utilization: Double? = nil, resetsAt: Date? = nil, details: String? = nil) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.details = details
    }
}

public enum ProviderStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case requiresReauth
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

