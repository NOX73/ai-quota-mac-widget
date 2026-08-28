# OAuth Client Credentials: Storage and Provenance

## Why this exists

All three providers' OAuth flows need a client id (Antigravity also needs a client secret).
These aren't secrets in the sense of "belongs to this project" — they're the public client
identifiers baked into each provider's own official CLI/IDE binary, discovered by inspecting
those binaries/repos. Only Antigravity's pair actually matches a pattern GitHub's push
protection scans for (`GOCSPX-...`), but none of the four are treated as literals anywhere in
this repo or its history — Claude's and Codex's got the same treatment purely for consistency
(and because an earlier version of this repo had had them as plain literals in git history for a
while; that history was rewritten with `git filter-repo` to scrub them too).

## How it's stored

- `.env` (gitignored) holds all four values as `KEY=value` lines.
- `scripts/generate_credentials.sh` reads `.env` and writes
  `Sources/ClaudeQuota/Auth/GeneratedCredentials.swift` (also gitignored) — a plain `enum` with
  four `static let`s. `ClaudeAuthFlow`, `CodexAuthFlow`, and `AntigravityAuthFlow` reference
  those instead of literals.
- `build_app.sh` calls the generator automatically. Plain `swift build` (day-to-day dev loop)
  does **not** — run `scripts/generate_credentials.sh` by hand first if `GeneratedCredentials.swift`
  doesn't exist yet or `.env` changed. SPM has no pre-build hook here without adding a build
  tool plugin, which felt like more machinery than this warrants.
- `.env.example` is the committed template — copy it to `.env` to get started. Every value in it
  is a `REPLACE_ME` placeholder; nothing real ever gets committed there.

## Setting up a fresh clone

```bash
cp .env.example .env
./scripts/fetch_secrets.sh          # fills in Antigravity + Codex automatically
# fill in CLAUDE_CLIENT_ID by hand — see below
./scripts/generate_credentials.sh   # writes GeneratedCredentials.swift
swift build
```

## Which of these are actually secret

Only `ANTIGRAVITY_CLIENT_ID` / `ANTIGRAVITY_CLIENT_SECRET` are secret-*shaped* enough for
GitHub's scanner to flag (`GOCSPX-...` matches Google's registered pattern). `CLAUDE_CLIENT_ID`
(a bare UUID) and `CODEX_CLIENT_ID` (`app_...`) don't match any pattern GitHub scans for by
default. All four are routed through the same `.env` / generated-file system and scrubbed from
history the same way regardless, purely for consistency — not because Claude/Codex's needed it
for GitHub's sake.

None of these four values are confidential in the "only this project should have them" sense —
they're each embedded in every copy of the respective official client (Claude Code CLI, Codex
CLI, Antigravity binary) and, in practice, already public. Treat `scripts/fetch_secrets.sh` and
the provenance below as "how to re-derive a public value if you ever need to," not as protecting
a real secret.

## Provenance and how to re-derive each one

### Claude — `CLAUDE_CLIENT_ID`

- A bare UUID, found by inspecting the official Claude Code CLI's shipped binary
  (`resources/native-binary/claude` inside the Claude Code VS Code extension) — see
  `oauth-localhost-flow.md` for the full discovery notes (exact endpoints, scopes, etc.).
- **Not fetchable from a stable public URL.** To re-derive: download the Claude Code VS Code
  extension (or the standalone `claude` CLI), locate its native binary, and run `strings` on it
  searching for a UUID adjacent to references to `claude.com/cai/oauth` or `oauth/authorize`.

### Codex — `CODEX_CLIENT_ID`

- An `app_`-prefixed id, found in the open-source `openai/codex` repo:
  `codex-rs/login/src/auth/manager.rs` — `pub const CLIENT_ID: &str = "app_...";`
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
