import SwiftUI

public struct PopoverView: View {
    @ObservedObject var service: AggregateQuotaService
    @State private var showingSettings = false
    var onSettingsDismissed: (() -> Void)?

    public init(service: AggregateQuotaService, onSettingsDismissed: (() -> Void)? = nil) {
        self.service = service
        self.onSettingsDismissed = onSettingsDismissed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text("AI Subscription Quotas")
                    .font(.headline)
                Spacer()

                if service.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }

                Button(action: { service.manualRefresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Include providers that need re-auth too, so users see *why* their
                    // usage stopped loading instead of the card silently disappearing.
                    let connectedProviders = service.providers.filter { $0.status.isConnected || $0.status == .requiresReauth }

                    if connectedProviders.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No subscriptions connected")
                                .font(.subheadline.weight(.medium))
                            Text("Click ⚙ settings to connect Claude, Codex, or Gemini.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Open Settings") {
                                showingSettings = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 20)
                    } else {
                        ForEach(connectedProviders, id: \.id) { provider in
                            ProviderCardView(
                                provider: provider,
                                warningThreshold: service.warningThreshold,
                                criticalThreshold: service.criticalThreshold
                            )
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                if let lastUpdated = service.lastUpdated {
                    let mins = Int(service.currentInterval) / 60
                    Text("Updated \(lastUpdated, style: .relative) ago · \(mins)m poll")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, height: 380)
        .sheet(isPresented: $showingSettings, onDismiss: { onSettingsDismissed?() }) {
            SettingsView(service: service)
        }
    }
}

struct ProviderCardView: View {
    let provider: any QuotaProvider
    let warningThreshold: Double
    let criticalThreshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: ProviderIcons.icon(forProviderID: provider.id))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.primary)
                Text(provider.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()

                if case .error(let msg) = provider.status {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if provider.status == .requiresReauth {
                    Text("Re-auth required")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if provider.periods.isEmpty {
                Text("No active usage periods")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(provider.periods) { period in
                        UsageRowView(period: period, warningThreshold: warningThreshold, criticalThreshold: criticalThreshold)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct UsageRowView: View {
    let period: QuotaPeriod
    let warningThreshold: Double
    let criticalThreshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(period.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()

                if let util = period.utilization {
                    Text("\(Int(util))%")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(colorForUtilization(util))
                } else if let details = period.details {
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let util = period.utilization {
                ProgressView(value: min(util / 100.0, 1.0))
                    .tint(colorForUtilization(util))
            }

            if let resetDate = period.resetsAt {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func colorForUtilization(_ value: Double) -> Color {
        switch UtilizationLevel(utilization: value, warningThreshold: warningThreshold, criticalThreshold: criticalThreshold) {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
