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
   - Constructs the Claude authorization URL: `https://claude.ai/oauth/authorize` with `client_id=claude-code`, `response_type=code`, `redirect_uri=http://localhost:<port>/callback`, PKCE parameters, and scope.
   - Launches the default browser using `NSWorkspace.shared.open(...)`.
   - On callback, exchanges authorization codes for access tokens with `https://api.anthropic.com/v1/oauth/tokens` (or uses direct token if passed).
   - Persists the access token into macOS Keychain (`claude_oauth_token`).

3. **`ClaudeProvider` & `SettingsView` (`Sources/ClaudeQuota/Providers/ClaudeProvider.swift` & `App/SettingsView.swift`)**:
   - `ClaudeProvider` exposes `startOAuthLogin()` and observes `authFlow` state.
   - `BrowserAuthSheetView` displays live status ("Listening on http://localhost:54321/callback...").
   - Automatically closes the modal once connection succeeds.
   - Keeps manual token input available as a fallback option.

## Verification
- Built and compiled using `swift build` and `./scripts/build_app.sh`.

