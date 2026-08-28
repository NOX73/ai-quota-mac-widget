import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var service: AggregateQuotaService
    @Environment(\.dismiss) private var dismiss

    @State private var activeAuthSheet: AuthTarget?
    @State private var customTokenInput: String = ""
    @State private var selectedProviderForToken: String = "claude"

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
            case .claude: "Claude (Anthropic)"
            case .openAI: "OpenAI (ChatGPT)"
            case .google: "Google AI Plus"
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
                    // Claude Row
                    providerRow(
                        icon: "sparkles",
                        title: "Claude Pro / Max",
                        subtitle: "Anthropic direct subscription",
                        provider: service.claudeProvider,
                        onConnect: { connectProvider(.claude) }
                    )

                    // OpenAI Row
                    providerRow(
                        icon: "cpu",
                        title: "ChatGPT Plus / Pro",
                        subtitle: "OpenAI ChatGPT subscription",
                        provider: service.openAIProvider,
                        onConnect: { connectProvider(.openAI) }
                    )

                    // Google AI Row
                    providerRow(
                        icon: "wand.and.stars",
                        title: "Google AI Plus",
                        subtitle: "Antigravity multi-model plan",
                        provider: service.googleAIProvider,
                        onConnect: { connectProvider(.google) }
                    )
                }
            }

            Divider()

            // Manual Token Paste option
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual Token Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Picker("Provider", selection: $selectedProviderForToken) {
                        Text("Claude").tag("claude")
                        Text("ChatGPT").tag("openai")
                        Text("Google AI").tag("google")
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    SecureField("Paste OAuth / Session token...", text: $customTokenInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        let token = customTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !token.isEmpty {
                            switch selectedProviderForToken {
                            case "claude":
                                service.claudeProvider.saveToken(token)
                            case "openai":
                                service.openAIProvider.saveToken(token)
                            case "google":
                                service.googleAIProvider.saveToken(token)
                            default:
                                break
                            }
                            customTokenInput = ""
                        }
                    }
                    .disabled(customTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 430)
        .sheet(item: $activeAuthSheet) { target in
            BrowserAuthSheetView(
                target: target,
                claudeProvider: service.claudeProvider,
                onSave: { token in
                    handleAuthToken(token, for: target)
                },
                onDismiss: {
                    if target == .claude {
                        service.claudeProvider.authFlow.stopAuthorization()
                    }
                    activeAuthSheet = nil
                }
            )
        }
    }

    private func connectProvider(_ target: AuthTarget) {
        if target == .claude {
            service.claudeProvider.startOAuthLogin()
        } else {
            NSWorkspace.shared.open(target.initialURL)
        }
        activeAuthSheet = target
    }

    @ViewBuilder
    private func providerRow<P: QuotaProvider>(
        icon: String,
        title: String,
        subtitle: String,
        provider: P,
        onConnect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
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
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.caption.weight(.semibold))

                    Button("Disconnect") {
                        provider.logout()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .padding(.leading, 6)
                }
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

    private func handleAuthToken(_ token: String, for target: AuthTarget) {
        switch target {
        case .claude:
            service.claudeProvider.saveToken(token)
        case .openAI:
            service.openAIProvider.saveToken(token)
        case .google:
            service.googleAIProvider.saveToken(token)
        }
    }
}

struct BrowserAuthSheetView: View {
    let target: SettingsView.AuthTarget
    @ObservedObject var claudeProvider: ClaudeProvider
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    @State private var tokenInput: String = ""

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

            if target == .claude {
                claudeAuthView
            } else {
                defaultBrowserAuthView
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(target == .claude ? "Manual Fallback Token / Code:" : "OAuth / Session Token / Code:")
                    .font(.caption.weight(.medium))

                SecureField("Paste OAuth token or session code...", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }

                Button("Save & Connect") {
                    let cleanToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanToken.isEmpty {
                        onSave(cleanToken)
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .onChange(of: claudeProvider.status) { _, newStatus in
            if target == .claude && newStatus.isConnected {
                onDismiss()
            }
        }
    }

    private var claudeAuthView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Listening for localhost redirect...")
                    .font(.subheadline.weight(.semibold))
            }

            if let urlStr = claudeProvider.authFlow.listeningURLString {
                Text("Local callback server: \(urlStr)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The authorization page was opened in your browser. Once signed in, you will be automatically redirected to localhost and logged in.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMsg = claudeProvider.authFlow.errorMessage {
                ScrollView {
                    Text("Error Log:\n\(errorMsg)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }

            Button(action: {
                claudeProvider.startOAuthLogin()
            }) {
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

            Text("Authorization page has been launched in your system default browser (supporting Google Sign-In, SSO, and Passkeys). Once signed in, paste your token or authorization code below:")
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


