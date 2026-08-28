# ClaudeQuota (AIQuota Widget)

macOS menu bar application for monitoring AI subscription usage quotas across multiple providers: **Claude (Anthropic)**, **OpenAI (ChatGPT)**, and **Google AI Plus**.

## Features

- **Menu Bar Status**: Displays real-time maximum quota utilization with color coding (Green / Orange / Red).
- **Multi-Provider Monitoring**:
  - **Claude Pro / Max**: 5-hour session quota and 7-day weekly usage limit tracking via Anthropic OAuth API.
  - **ChatGPT Plus / Pro**: 3-hour sliding message window utilization.
  - **Google AI Plus**: Entitlement limits across Gemini, Claude, and GPT models.
- **Default System Browser Auth**: Launch login directly in your default browser (Safari, Chrome, Arc), enabling full support for Google Sign-In, Passkeys, 2FA, and SAML SSO.
- **Secure Storage**: Credentials stored in macOS System Keychain via standard Security framework APIs (`com.claude.quota.widget`).

---

## 📌 Documentation Rule

> **IMPORTANT**: All project documentation, architectural decision records, feature plans, and implementation walkthroughs **MUST** be maintained inside the [`doc/`](doc/) directory (specifically under [`doc/features/`](doc/features/)). 
>
> Please consult [`doc/README.md`](doc/README.md) before making architectural modifications.

---

## Documentation Index

- **[Architecture & Initial Specs](doc/features/initial-architecture.md)**: Data sources, API endpoints, data models, and application layout.
- **[Default Browser Authorization Flow](doc/features/default-browser-auth.md)**: System browser OAuth flow specification, sheet implementation, and removal of legacy Keychain fallbacks.
- **[Localhost OAuth Redirect Flow](doc/features/oauth-localhost-flow.md)**: Automatic CLI-style loopback OAuth authorization using a local HTTP server on `localhost:54321`.

---

## Building and Running

### Prerequisites
- macOS 14.0 or later
- Swift 5.9+ / Xcode Command Line Tools

### Build via Swift Package Manager
```bash
swift build
```

### Build `.app` Bundle
To build a standalone executable application bundle in `build/ClaudeQuota.app`:
```bash
./scripts/build_app.sh
```

### Launch Application
```bash
open build/ClaudeQuota.app
```
