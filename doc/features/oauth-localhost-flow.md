# Localhost OAuth Redirect Authorization Flow

## Overview
This feature implements an automatic CLI-style loopback OAuth authorization flow for **Claude (Anthropic)**.
Instead of requiring users to copy and paste authorization codes or tokens manually, `ClaudeQuota` starts a temporary local HTTP server listening on `localhost:54321`, launches the default browser with a `redirect_uri=http://localhost:54321/callback`, and automatically captures the authorization token upon redirection.

## Architecture

### Key Components

1. **`LocalOAuthServer` (`Sources/ClaudeQuota/Auth/LocalOAuthServer.swift`)**:
   - Built on native macOS `Network.framework` (`NWListener`).
   - Listens on `127.0.0.1` at port `54321` with dynamic fallback to `54322..54330` if port 54321 is bound.
   - Intercepts incoming `GET /callback?code=...` (or `token=...`) requests.
   - Responds to the browser with a clean HTML confirmation page ("✓ Authorization Successful").
   - Transmits parameters to the application completion handler and closes the loopback socket.

2. **`ClaudeAuthFlow` (`Sources/ClaudeQuota/Auth/ClaudeAuthFlow.swift`)**:
   - Generates cryptographically secure PKCE verifier (`code_verifier`), challenge (`code_challenge`), and state token (`state`).
   - Constructs the Claude authorization URL: `https://claude.com/cai/oauth/authorize` (the "login with claude.ai" / Pro-Max personal-subscription endpoint — distinct from `platform.claude.com/oauth/authorize`, which is the Console/API-key endpoint) with `code=true`, `client_id=xxxxxxx`, `response_type=code`, `redirect_uri=http://localhost:<port>/callback`, PKCE parameters, `scope=user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`, and `state`.
   - Launches the default browser using `NSWorkspace.shared.open(...)`.
   - Validates the `state` value echoed back on the callback matches what was sent, to guard against CSRF.
   - On callback, exchanges the authorization code for an access token via a JSON POST to `https://platform.claude.com/v1/oauth/token` — or uses the value directly if it's already an `sk-` API key.
   - The token exchange body sends `grant_type`, `code`, `redirect_uri` (the **same** loopback URL used for the browser callback — not a fixed console URL), `client_id`, `code_verifier`, and `state`.
   - These exact values (hosts, param names, `code=true`, scopes) were confirmed by inspecting the official Claude Code CLI binary (`resources/native-binary/claude` inside the VS Code extension), not guessed — earlier attempts using `claude.ai/oauth/authorize`, `api.anthropic.com`, and `console.anthropic.com` were all wrong/stale endpoints.
   - Persists the access token into macOS Keychain (`claude_oauth_token`).

3. **`ClaudeProvider` & `SettingsView` (`Sources/ClaudeQuota/Providers/ClaudeProvider.swift` & `App/SettingsView.swift`)**:
   - `ClaudeProvider` exposes `startOAuthLogin()` and observes `authFlow` state.
   - `BrowserAuthSheetView` displays live status ("Listening on http://localhost:54321/callback...").
   - Automatically closes the modal once connection succeeds.
   - Keeps manual token input available as a fallback option.

## Verification
- Built and compiled using `swift build` and `./scripts/build_app.sh`.

