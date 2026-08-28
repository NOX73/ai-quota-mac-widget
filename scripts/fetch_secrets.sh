#!/bin/bash
# Best-effort refresh of .env from the public sources these OAuth client credentials were
# originally found in. Antigravity and Codex are fetchable this way — Claude's client id was
# found by inspecting a shipped binary that doesn't live at a stable URL, so it's left
# untouched here. Full provenance and manual instructions for all three:
# doc/features/oauth-credentials.md.
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

ENV_FILE=".env"
[ -f "$ENV_FILE" ] || cp .env.example "$ENV_FILE"

set_env() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$ENV_FILE"
    echo "${key}=${value}" >> "$ENV_FILE"
}

echo "Fetching Antigravity (Google) OAuth client id/secret from the public community source..."
SOURCE_URL="https://raw.githubusercontent.com/insign/opencode-antigravity-auth-updated/main/src/constants.ts"
CONSTANTS="$(curl -fsSL "$SOURCE_URL" || true)"

if [ -z "$CONSTANTS" ]; then
    echo "  Could not fetch $SOURCE_URL — leaving .env untouched. See" >&2
    echo "  doc/features/oauth-credentials.md for the manual fallback." >&2
    exit 1
fi

AG_ID=$(echo "$CONSTANTS" | grep 'ANTIGRAVITY_CLIENT_ID =' | sed -E 's/.*"([^"]+)".*/\1/')
AG_SECRET=$(echo "$CONSTANTS" | grep 'ANTIGRAVITY_CLIENT_SECRET =' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$AG_ID" ] || [ -z "$AG_SECRET" ]; then
    echo "  Fetched $SOURCE_URL but couldn't find the expected constants in it — the source" >&2
    echo "  file's format may have changed. See doc/features/oauth-credentials.md." >&2
    exit 1
fi

set_env "ANTIGRAVITY_CLIENT_ID" "$AG_ID"
set_env "ANTIGRAVITY_CLIENT_SECRET" "$AG_SECRET"
echo "  Updated ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET in $ENV_FILE"

echo ""
echo "Fetching Codex (OpenAI) OAuth client id from the openai/codex source repo..."
CODEX_SOURCE_URL="https://raw.githubusercontent.com/openai/codex/main/codex-rs/login/src/auth/manager.rs"
CODEX_SOURCE="$(curl -fsSL "$CODEX_SOURCE_URL" || true)"
CODEX_ID=$(echo "$CODEX_SOURCE" | grep -E '^\s*pub const CLIENT_ID: &str' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -n "$CODEX_ID" ]; then
    set_env "CODEX_CLIENT_ID" "$CODEX_ID"
    echo "  Updated CODEX_CLIENT_ID in $ENV_FILE"
else
    echo "  Could not fetch/parse $CODEX_SOURCE_URL — leaving CODEX_CLIENT_ID in .env" >&2
    echo "  untouched. See doc/features/oauth-credentials.md." >&2
fi

echo ""
echo "CLAUDE_CLIENT_ID can't be fetched automatically — see doc/features/oauth-credentials.md"
echo "for how to find/verify it by hand. Leaving whatever is already in .env untouched."
echo ""
echo "Run scripts/generate_credentials.sh next to turn .env into Swift source."
