import SwiftUI

public struct SettingsView: View {
    @ObservedObject var service: AggregateQuotaService
    @Environment(\.dismiss) private var dismiss

    @State private var activeAuthSheet: AuthTarget?
    @State private var customTokenInput: String = ""
    @State private var selectedProviderForToken: String?

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
                        onConnect: { activeAuthSheet = .claude }
                    )

                    // OpenAI Row
                    providerRow(
                        icon: "cpu",
                        title: "ChatGPT Plus / Pro",
                        subtitle: "OpenAI ChatGPT subscription",
                        provider: service.openAIProvider,
                        onConnect: { activeAuthSheet = .openAI }
                    )

                    // Google AI Row
                    providerRow(
                        icon: "wand.and.stars",
                        title: "Google AI Plus",
                        subtitle: "Antigravity multi-model plan",
                        provider: service.googleAIProvider,
                        onConnect: { activeAuthSheet = .google }
                    )
                }
            }

            Divider()

            // Manual Token Paste option
            VStack(alignment: .leading, spacing: 8) {
                Text("Manual Token Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Paste OAuth / Session token...", text: $customTokenInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save Claude Token") {
                        if !customTokenInput.isEmpty {
                            service.claudeProvider.saveToken(customTokenInput.trimmingCharacters(in: .whitespacesAndNewlines))
                            customTokenInput = ""
                        }
                    }
                    .disabled(customTokenInput.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
        .sheet(item: $activeAuthSheet) { target in
            VStack {
                HStack {
                    Text("Sign in to \(target.title)")
                        .font(.headline)
                    Spacer()
                    Button("Close") {
                        activeAuthSheet = nil
                    }
                }
                .padding()

                OAuthWebView(
                    initialURL: target.initialURL,
                    onRedirect: { url in
                        // Detect successful auth redirects or custom schemes
                        if url.absoluteString.contains("code=") || url.absoluteString.contains("session") {
                            // Extract query token if present
                            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                               let code = components.queryItems?.first(where: { $0.name == "code" || $0.name == "token" })?.value {
                                handleAuthToken(code, for: target)
                                activeAuthSheet = nil
                                return true
                            }
                        }
                        return false
                    },
                    onCookieExtracted: { cookies in
                        // Extract session cookies for OpenAI or Google if present
                        if target == .openAI, let sessionCookie = cookies.first(where: { $0.name.contains("session-token") }) {
                            service.openAIProvider.saveToken(sessionCookie.value)
                        }
                    }
                )
            }
            .frame(width: 600, height: 500)
        }
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
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
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

