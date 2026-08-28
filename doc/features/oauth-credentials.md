# OAuth Client Credentials: Storage and Provenance

## Why this exists

All three providers' OAuth flows need a client id (Antigravity also needs a client secret).
These aren't secrets in the sense of "belongs to this project" — they're the public client
identifiers baked into each provider's own official CLI/IDE binary, discovered by inspecting
those binaries/repos. But Antigravity's pair matches Google's registered `GOCSPX-`
secret-scanning pattern, so GitHub's push protection blocks any push containing it as a literal
string (see the incident this setup replaced: an earlier commit had it inline in
`AntigravityAuthFlow.swift` and every push was rejected — see git history around the "Replace
Gemini with a real Antigravity connect flow" commit for the base64-obfuscation attempt that
preceded this).

## How it's stored now

- `.env` (gitignored) holds all four values as `KEY=value` lines.
- `scripts/generate_credentials.sh` reads `.env` and writes
  `Sources/ClaudeQuota/Auth/GeneratedCredentials.swift` (also gitignored) — a plain `enum` with
  four `static let`s. `ClaudeAuthFlow`, `CodexAuthFlow`, and `AntigravityAuthFlow` reference
  those instead of literals.
- `build_app.sh` calls the generator automatically. Plain `swift build` (day-to-day dev loop)
  does **not** — run `scripts/generate_credentials.sh` by hand first if `GeneratedCredentials.swift`
  doesn't exist yet or `.env` changed. SPM has no pre-build hook here without adding a build
  tool plugin, which felt like more machinery than this warrants.
- `.env.example` is the committed template — copy it to `.env` to get started. The Claude/Codex
  values are filled in directly there (see "which of these are actually secret" below); the two
  Antigravity fields are placeholders.

## Setting up a fresh clone

```bash
cp .env.example .env
./scripts/fetch_secrets.sh          # fills in Antigravity + Codex automatically
./scripts/generate_credentials.sh   # writes GeneratedCredentials.swift
swift build
```

## Which of these are actually secret

Only `ANTIGRAVITY_CLIENT_ID` / `ANTIGRAVITY_CLIENT_SECRET` are secret-*shaped* enough for
GitHub's scanner to flag (`GOCSPX-...` matches Google's registered pattern). `CLAUDE_CLIENT_ID`
(a bare UUID) and `CODEX_CLIENT_ID` (`app_...`) don't match any pattern GitHub scans for by
default and were already sitting as plain literals in this repo's git history for a while
before this refactor without ever being flagged. They're routed through the same `.env` /
generated-file system anyway, purely for consistency — not because they needed it.

None of these four values are confidential in the "only this project should have them" sense —
they're each embedded in every copy of the respective official client (Claude Code CLI, Codex
CLI, Antigravity binary) and, in practice, already public. Treat `scripts/fetch_secrets.sh` and
the provenance below as "how to re-derive a public value if you ever need to," not as protecting
a real secret.

## Provenance and how to re-derive each one

### Claude — `CLAUDE_CLIENT_ID`

- Current value: `xxxxxxx`
- Found by inspecting the official Claude Code CLI's shipped binary
  (`resources/native-binary/claude` inside the Claude Code VS Code extension) — see
  `oauth-localhost-flow.md` for the full discovery notes (exact endpoints, scopes, etc.).
- **Not fetchable from a stable public URL.** To re-derive if it ever changes: download the
  Claude Code VS Code extension (or the standalone `claude` CLI), locate its native binary, and
  run `strings` on it searching for a UUID adjacent to references to `claude.com/cai/oauth` or
  `oauth/authorize`.

### Codex — `CODEX_CLIENT_ID`

- Current value: `xxxxxxx`
- Found in the open-source `openai/codex` repo:
  `codex-rs/login/src/auth/manager.rs` — `pub const CLIENT_ID: &str = "xxxxxxx";`
  (there's also a `CODEX_APP_SERVER_LOGIN_CLIENT_ID` env var that overrides it, and
  `codex-rs/login/src/server.rs` has the exact `/oauth/authorize` query params — scope, PKCE,
  `id_token_add_organizations`, `codex_cli_simplified_flow`, `originator` — and both registered
  redirect ports, 1455 and 1457).
- **Fetchable**: `scripts/fetch_secrets.sh` pulls it straight from
  `https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/auth/manager.rs`.

### Antigravity — `ANTIGRAVITY_CLIENT_ID` / `ANTIGRAVITY_CLIENT_SECRET`

- Found via community reverse-engineering of the official Antigravity binary's network traffic,
  documented in several public `opencode` auth plugins.
- **Fetchable**: `scripts/fetch_secrets.sh` pulls both values straight from
  `https://raw.githubusercontent.com/insign/opencode-antigravity-auth-updated/main/src/constants.ts`
  (the `ANTIGRAVITY_CLIENT_ID` / `ANTIGRAVITY_CLIENT_SECRET` exported consts in that file).
  If that repo ever disappears or restructures, other known mirrors of the same values as of
  this writing: `GrigorTonikyan/antigravity-auth`, `NoeFabris/opencode-antigravity-auth`,
  `shekohex/opencode-google-antigravity-auth` (same `src/constants.ts` path/shape in each).
