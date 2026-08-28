# Antigravity Connect Flow (replaces Gemini)

## Overview

Google is deprecating `gemini-cli`/the Gemini API path in favor of **Antigravity** (its
agentic IDE/CLI successor — `@google/gemini-cli` stops serving API requests June 18, 2026). The
old `GoogleAIProvider` was a checkbox in Settings that opened `accounts.google.com` in the
browser and nothing else — there was never a way to actually complete that connection (no OAuth
client, no callback capture; manual token paste was removed earlier, see
[`ui-customization.md`](ui-customization.md)). It's been replaced outright with
`AntigravityProvider`, which gets the same automatic localhost-redirect OAuth flow as Claude and
Codex (see [`oauth-localhost-flow.md`](oauth-localhost-flow.md)).

## OAuth flow

`Sources/ClaudeQuota/Auth/AntigravityAuthFlow.swift`, structurally identical to
`ClaudeAuthFlow`/`CodexAuthFlow`:

- Authorization URL: `https://accounts.google.com/o/oauth2/v2/auth`
- `client_id` / `client_secret`: the public OAuth client Antigravity's own binary uses — these
  aren't secret in the sense of gating access (Google's "installed app" OAuth clients ship inside
  the binary), and are the same values several open-source Antigravity auth plugins for other
  tools (e.g. `opencode-antigravity-auth`) rely on. Discovered by inspecting Antigravity's network
  traffic, not guessed.
- `redirect_uri`: `http://localhost:51121/oauth-callback` — port `51121` is the only redirect port
  registered for this client, mirroring Antigravity's own local callback server (no fallback ports
  possible, unlike Claude's 54321–54330 range).
- Scopes: `cloud-platform`, `userinfo.email`, `userinfo.profile`, `cclog`,
  `experimentsandconfigs`.
- PKCE S256, `access_type=offline`, `prompt=consent` (forces a refresh token on every login).
- Token endpoint: `https://oauth2.googleapis.com/token` (form-encoded, standard Google OAuth2).
  Unlike Claude/Codex, the refresh grant sends `client_secret` too, and Google normally omits
  `refresh_token` from refresh responses (no rotation) — `AntigravityProvider` keeps the existing
  refresh token in that case.

## Quota fetch

`Sources/ClaudeQuota/Providers/AntigravityProvider.swift` talks to the same Cloud Code Assist
backend the IDE uses (`https://cloudcode-pa.googleapis.com`) — this is also the host the old,
never-functional `GoogleAIProvider` pointed at, just the wrong endpoint (`v1beta/config:fetch`).

1. **Project resolution** (`v1internal:loadCodeAssist`, cached in Keychain under
   `antigravity_project_id`): POSTs `{"metadata": {"ideType": "ANTIGRAVITY", ...}}` and reads
   `cloudaicompanionProject` back. Optional — quota fetch still works without it.
2. **Quota** (`v1internal:fetchAvailableModels`): POSTs `{"project": <id>}` and gets back a
   `models` map keyed by model name, each with `quotaInfo.remainingFraction` /
   `quotaInfo.resetTime`. Model names are bucketed into three groups by substring match
   (`claude`, `gemini-3` + `flash` → Gemini 3 Flash, `gemini-3` otherwise → Gemini 3 Pro); when a
   group has multiple models, the worst (lowest remaining fraction / earliest reset) wins, matching
   how Claude/Codex already report the single tightest-constraint number per period.

## Token storage

Keychain keys: `antigravity_oauth_token`, `antigravity_oauth_refresh_token`,
`antigravity_oauth_expires_at`, `antigravity_project_id` — same pattern as
`claude_oauth_*`/`openai_oauth_*`. Unlike Codex's access token (a JWT this app decodes for its
`exp` claim), Google's access token is opaque, so expiry is tracked from the token response's
`expires_in` the same way `ClaudeProvider` does.

## UI

`SettingsView`'s `AuthTarget.google` case (browser-only, `defaultBrowserAuthView`, "support is
coming soon") is gone. `.antigravity` now takes the same `localCallbackAuthView` path as Claude
and Codex. The icon is a placeholder (Bootstrap Icons "rocket-takeoff", MIT) since Google hasn't
published a standalone Antigravity brand SVG — see `ProviderIcons.swift`.

## Verification

- `swift build` — compiles clean.
- Not yet verified against a live Google account login (no test account available in this
  session) — the request/response shapes above come from Antigravity's Cloud Code Assist API as
  exercised by open-source community auth plugins, not from a live run of this app.
