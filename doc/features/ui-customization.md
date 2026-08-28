# UI Customization: Names, Icons, Colors, Menu Bar Settings

## Overview
A round of visual polish plus persisted user-facing settings for how the menu bar renders.

## Manual token paste flow removed
Dropped entirely: the standalone "Manual Token Input" section in `SettingsView` and the
paste-a-token fallback field in `BrowserAuthSheetView`, along with the now-unused
`saveToken(_:)` on each provider.

**Consequence**: Claude keeps working via its automatic localhost OAuth redirect flow
(`oauth-localhost-flow.md`). OpenAI and Google AI Plus have no automatic flow of their own yet, so
their Connect button now just opens the provider's login page in the browser with no way to
complete the connection — until each gets its own OAuth flow, the same way Claude has one.

## Provider naming
Display names simplified everywhere (Settings rows, popover cards, auth sheet titles) to just
**Claude**, **Codex**, **Gemini** — dropped the subscription-plan wording ("Claude Pro / Max",
"ChatGPT Plus / Pro", "Google AI Plus").

## Real provider icons
Replaced the placeholder SF Symbols (`sparkles` / `cpu` / `wand.and.stars`) with the providers'
actual logomarks.

- Source: [simple-icons](https://github.com/simple-icons/simple-icons) (CC0), fetched as raw SVG
  and embedded as Swift string literals in `Sources/ClaudeQuota/App/ProviderIcons.swift`.
- Decoded via `NSImage(data:)` — AppKit has native SVG rendering support (macOS 12+,
  `_NSSVGImageRep`), so these stay crisp vector at any size rather than being baked PNGs.
- Looked up by provider `id` via `ProviderIcons.icon(forProviderID:)`. `QuotaProvider` no longer
  declares an `iconName` — that was a leftover SF Symbol name string, now unused.
- `image.isTemplate = true` so SwiftUI's `.renderingMode(.template)` tints them like SF Symbols
  in Settings/popover. The menu bar (plain AppKit, not SwiftUI) tints them manually — see below.

## Simplified connected state
Settings used to show a green checkmark + "Connected" text next to the Disconnect button. Removed
— the Connect button already turning into Disconnect communicates the state on its own.

## Configurable green/yellow/red thresholds
`AggregateQuotaService` owns `warningThreshold` / `criticalThreshold` (defaults 50 / 80),
persisted to `UserDefaults` (`quota.warningThreshold` / `quota.criticalThreshold`) and survive
restarts. Set through `setWarningThreshold(_:)` / `setCriticalThreshold(_:)`, which keep the two
at least 1% apart. Exposed as two sliders in a "Usage Colors" section in Settings.

The shared `UtilizationLevel` enum (`Models/QuotaModels.swift`) maps a utilization % + the two
thresholds to `.normal` / `.warning` / `.critical`; both the menu bar and the popover's per-period
colors go through it instead of hardcoded 50/80 cutoffs.

## Menu bar redesign
The tray used `◆`/`⬡`/`✦` marker characters to tell providers apart. `⬡` (white hexagon, U+2B21)
isn't in the system font's menu bar glyph set and rendered as a tofu box. Replaced with each
provider's real logomark, drawn inline via `NSTextAttachment` in the button's `attributedTitle`
(`MenuBarController.updateButton`). `NSTextAttachment` doesn't auto-tint template images the way
SF Symbol attachments do, so each icon is manually tinted to a solid color first
(`tintedTrayIcon`, draw-then-`.sourceAtop`-fill).

Per provider, the tray shows the **worst** (highest) utilization among that provider's periods —
e.g. `max(5h session, 7d weekly)` for Claude, via `QuotaProvider.worstUtilization` — since that's
the limit you'll hit first. Each connected provider gets its own icon+percentage segment, colored
independently (not one color for the whole button).

### Three persisted menu bar settings (Settings → "Menu Bar" section)
- **Show provider icon** (`showTrayIcon`, default on) — hide the icon and show just the
  percentage.
- **Colored percentage** (`trayColorEnabled`, default on) — off falls back to plain menu bar
  label color for everything.
- **Neutral color when OK** (`neutralWhenNormal`, default off) — when on, utilization below the
  warning threshold shows in plain label color instead of green; color only appears once
  something actually needs attention (orange/red). Tray-only by design — the popover's per-period
  colors are unaffected, since green there is considered useful at-a-glance detail rather than
  noise.

All three follow the same `UserDefaults`-backed pattern as the thresholds above.

## Files touched
- `Sources/ClaudeQuota/App/ProviderIcons.swift` (new)
- `Sources/ClaudeQuota/App/SettingsView.swift`
- `Sources/ClaudeQuota/MenuBarController.swift`
- `Sources/ClaudeQuota/PopoverView.swift`
- `Sources/ClaudeQuota/Models/QuotaModels.swift`
- `Sources/ClaudeQuota/Services/AggregateQuotaService.swift`
- `Sources/ClaudeQuota/Providers/QuotaProvider.swift`
- `Sources/ClaudeQuota/Providers/ClaudeProvider.swift`, `OpenAIProvider.swift`, `GoogleAIProvider.swift`
