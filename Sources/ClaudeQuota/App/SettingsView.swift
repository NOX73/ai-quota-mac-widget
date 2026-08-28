import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var service: AggregateQuotaService
    @Environment(\.dismiss) private var dismiss

    @State private var activeAuthSheet: AuthTarget?

    enum AuthTarget: Identifiable {
        case claude
        case openAI
        case google

        var id: String {
            switch self {
            case .claude: "claude"
            case .openAI: "openai"
            case .google: "google"
            }
        }

        var title: String {
            switch self {
            case .claude: "Claude"
            case .openAI: "Codex"
            case .google: "Gemini"
            }
        }

        var initialURL: URL {
            switch self {
            case .claude:
                URL(string: "https://claude.ai/login")!
            case .openAI:
                URL(string: "https://chatgpt.com")!
            case .google:
                URL(string: "https://accounts.google.com")!
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Provider Connections")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    providerRow(
                        title: "Claude",
                        subtitle: "Anthropic subscription",
                        provider: service.claudeProvider,
                        onConnect: { connectProvider(.claude) }
                    )

                    providerRow(
                        title: "Codex",
                        subtitle: "OpenAI subscription",
                        provider: service.openAIProvider,
                        onConnect: { connectProvider(.openAI) }
                    )

                    providerRow(
                        title: "Gemini",
                        subtitle: "Google AI subscription",
                        provider: service.googleAIProvider,
                        onConnect: { connectProvider(.google) }
                    )
                }
            }

            Divider()

            thresholdSettings

            Divider()

            menuBarSettings
        }
        .padding(20)
        .frame(width: 440, height: 580)
        .sheet(item: $activeAuthSheet) { target in
            BrowserAuthSheetView(
                target: target,
                claudeProvider: service.claudeProvider,
                openAIProvider: service.openAIProvider,
                onDismiss: {
                    switch target {
                    case .claude:
                        service.claudeProvider.authFlow.stopAuthorization()
                    case .openAI:
                        service.openAIProvider.authFlow.stopAuthorization()
                    case .google:
                        break
                    }
                    activeAuthSheet = nil
                }
            )
        }
    }

    private func connectProvider(_ target: AuthTarget) {
        switch target {
        case .claude:
            service.claudeProvider.startOAuthLogin()
        case .openAI:
            service.openAIProvider.startOAuthLogin()
        case .google:
            NSWorkspace.shared.open(target.initialURL)
        }
        activeAuthSheet = target
    }

    @ViewBuilder
    private func providerRow<P: QuotaProvider>(
        title: String,
        subtitle: String,
        provider: P,
        onConnect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: ProviderIcons.icon(forProviderID: provider.id))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if provider.status.isConnected {
                Button("Disconnect") {
                    provider.logout()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button("Connect") {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var thresholdSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Colors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Yellow from")
                    Spacer()
                    Text("\(Int(service.warningThreshold))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { service.warningThreshold },
                        set: { service.setWarningThreshold($0) }
                    ),
                    in: 1...99,
                    step: 1
                )
                .tint(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Red from")
                    Spacer()
                    Text("\(Int(service.criticalThreshold))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { service.criticalThreshold },
                        set: { service.setCriticalThreshold($0) }
                    ),
                    in: 1...99,
                    step: 1
                )
                .tint(.red)
            }
        }
    }

    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu Bar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Show provider icon", isOn: Binding(
                get: { service.showTrayIcon },
                set: { service.setShowTrayIcon($0) }
            ))

            Toggle("Colored percentage", isOn: Binding(
                get: { service.trayColorEnabled },
                set: { service.setTrayColorEnabled($0) }
            ))

            Toggle("Neutral color when OK", isOn: Binding(
                get: { service.neutralWhenNormal },
                set: { service.setNeutralWhenNormal($0) }
            ))
            .disabled(!service.trayColorEnabled)
        }
    }
}

struct BrowserAuthSheetView: View {
    let target: SettingsView.AuthTarget
    @ObservedObject var claudeProvider: ClaudeProvider
    @ObservedObject var openAIProvider: OpenAIProvider
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sign in to \(target.title)")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    onDismiss()
                }
            }

            Divider()

            switch target {
            case .claude:
                claudeAuthView
            case .openAI:
                codexAuthView
            case .google:
                defaultBrowserAuthView
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 440, height: 280)
        .onChange(of: claudeProvider.status) { _, newStatus in
            if target == .claude && newStatus.isConnected {
                onDismiss()
            }
        }
        .onChange(of: openAIProvider.status) { _, newStatus in
            if target == .openAI && newStatus.isConnected {
                onDismiss()
            }
        }
    }

    private var claudeAuthView: some View {
        localCallbackAuthView(
            listeningURLString: claudeProvider.authFlow.listeningURLString,
            errorMessage: claudeProvider.authFlow.errorMessage,
            reopen: { claudeProvider.startOAuthLogin() }
        )
    }

    private var codexAuthView: some View {
        localCallbackAuthView(
            listeningURLString: openAIProvider.authFlow.listeningURLString,
            errorMessage: openAIProvider.authFlow.errorMessage,
            reopen: { openAIProvider.startOAuthLogin() }
        )
    }

    private func localCallbackAuthView(
        listeningURLString: String?,
        errorMessage: String?,
        reopen: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Listening for localhost redirect...")
                    .font(.subheadline.weight(.semibold))
            }

            if let urlStr = listeningURLString {
                Text("Local callback server: \(urlStr)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The authorization page was opened in your browser. Once signed in, you will be automatically redirected to localhost and logged in.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMsg = errorMessage {
                ScrollView {
                    Text("Error Log:\n\(errorMsg)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            Button(action: reopen) {
                Label("Re-open Authorization Page", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var defaultBrowserAuthView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "safari")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Opened login page in your default browser.")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Automatic sign-in for this provider isn't available yet — support is coming soon.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: {
                NSWorkspace.shared.open(target.initialURL)
            }) {
                Label("Re-open in Browser", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}


