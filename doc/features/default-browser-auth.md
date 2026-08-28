# Default Browser Authorization Flow

## Overview
Initially, authorization for providers was handled in an embedded `WKWebView` modal (`OAuthWebView`). Identity providers like Google block logins inside embedded webviews (`disallowed_useragent`), preventing users from authenticating via Google Sign-In, Passkeys, 2FA, or corporate SSO.

## Plan & Requirements
1. Launch provider authentication URLs (`https://claude.ai/login`, `https://chatgpt.com`, `https://accounts.google.com`) in the system default browser via `NSWorkspace.shared.open(...)`.
2. Present a sheet modal in `SettingsView` (`BrowserAuthSheetView`) containing instructions, a "Re-open in Browser" button, and a token input field.
3. Support direct token saving for Claude, ChatGPT (OpenAI), and Google AI Plus via both the sheet and an enhanced Manual Token Input picker.
4. Remove legacy Keychain fallback (`loadLegacyClaudeCodeToken`) to enforce unified authentication storage (`claude_oauth_token`).

## Implementation Details

### Files Modified
- **`Sources/ClaudeQuota/App/SettingsView.swift`**:
  - Replaced `OAuthWebView` sheet with `BrowserAuthSheetView`.
  - Added `connectProvider(_:)` method launching `NSWorkspace.shared.open(target.initialURL)`.
  - Updated `Manual Token Input` section with a provider `Picker` (`claude`, `openai`, `google`).
- **`Sources/ClaudeQuota/Providers/ClaudeProvider.swift`**:
  - Removed `loadLegacyClaudeCodeToken()` fallback from `getToken()`.
- **`Sources/ClaudeQuota/Keychain/KeychainService.swift`**:
  - Removed obsolete `loadLegacyClaudeCodeToken()` method and `Claude Code-credentials` Keychain search.

### Files Deleted
- **`Sources/ClaudeQuota/Auth/OAuthWebView.swift`**: Removed as embedded `WKWebView` is no longer used.

## Verification
- Built using `swift build` and `./scripts/build_app.sh`.
- Verified clean build and bundle generation at `build/ClaudeQuota.app`.
