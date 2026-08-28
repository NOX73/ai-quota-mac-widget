# Popover/Settings Reactivity Fixes

## Overview
A cluster of related bugs made the popover and Settings feel unresponsive or stuck showing stale
data around connect/disconnect and the OAuth browser round-trip. None were data bugs — the
underlying `@Published` state was correct in every case — they were all failures to get SwiftUI
(or, in one case, the actual data-fetch retry path) to reflect it.

## Bugs and fixes

### 1. Disconnect/connect not reflected in the UI
`AggregateQuotaService` held `claudeProvider` / `openAIProvider` / `googleAIProvider` as plain
`let` properties. Each provider's own `@Published status`/`periods` changes fired that provider's
`objectWillChange`, but never propagated to `AggregateQuotaService.objectWillChange` — and
`SettingsView`/`PopoverView` only observe the aggregate service. So `logout()` and a successful
connect actually updated Keychain/state correctly, but the UI stayed frozen until something
unrelated (e.g. a poll tick touching `lastUpdated`) forced a redraw.

**Fix**: `AggregateQuotaService.init()` now subscribes to each provider's `objectWillChange` and
forwards it to its own (`Sources/ClaudeQuota/Services/AggregateQuotaService.swift`).

### 2. Popover unresponsive after the Claude OAuth browser round-trip
`NSPopover.behavior = .transient` auto-closes the popover the instant the app resigns active
status — which happens the moment the OAuth flow opens a browser window. That force-closed the
popover out from under the Settings/auth sheets stacked on top of it, leaving them as orphaned
windows: still visible, unresponsive to clicks, until the app was restarted.

**Fix**: switched to `.applicationDefined` and own dismissal via an explicit global
`NSEvent` click monitor (`MenuBarController.swift`), which also gives "click outside to dismiss
like a normal widget" for free. The monitor skips closing while a sheet is attached
(`closePopoverUnlessSheetPresented`), since that's exactly the scenario that used to break things.

### 3. Popover staying on a stale render after Settings closes
Even after fix #1/#2, the popover's `NSHostingController` — created once at launch and reused for
the app's lifetime — didn't reliably re-render while it had stayed open (behind Settings/auth
sheets) through the whole connect flow. The menu bar text (which reads `AggregateQuotaService`
directly, no SwiftUI involved) always showed the correct number, proving the data was fine; only
the popover's SwiftUI tree was stuck, and only a manual close+reopen forced a fresh layout pass.

**Fix, two layers**:
- The hosting controller's `rootView` is rebuilt fresh on every `show()` (was previously created
  once and reused).
- That alone doesn't cover it — the popover can stay open the *whole* time through
  Settings → browser OAuth → back to Settings without ever being closed. `PopoverView` now takes
  an `onSettingsDismissed` callback wired to its Settings `.sheet`'s `onDismiss`, and
  `MenuBarController` uses it to force the same rebuild the moment Settings closes, without
  waiting for the popover itself to be closed and reopened.

### 4. Claude usage periods stuck empty after connecting
Not a UI bug — `ClaudeProvider.refresh()`'s 401-retry path discarded the retried fetch's result:
```swift
if httpStatus == 401 {
    if await attemptTokenRefresh(), let refreshedToken = getToken() {
        _ = await fetchUsage(token: refreshedToken)   // result thrown away
    } else {
        status = .requiresReauth
    }
}
```
If the retry also came back 401 (e.g. a freshly-issued access token not yet valid API-side),
`status` stayed at `.connected` (set optimistically by `saveTokenSet` during the refresh) with
`periods` permanently empty — and every subsequent `refresh()` re-entered the same
retry-and-discard path, so manual refresh never recovered it either.

**Fix**: the retried fetch's result is now checked; a second 401 sets `.requiresReauth` instead of
silently leaving a stuck "connected but empty" state. `PopoverView`'s connected-providers filter
was widened to include `.requiresReauth` too, so the card shows "Re-auth required" instead of the
provider silently disappearing from the list.

## Files touched
- `Sources/ClaudeQuota/Services/AggregateQuotaService.swift`
- `Sources/ClaudeQuota/MenuBarController.swift`
- `Sources/ClaudeQuota/PopoverView.swift`
- `Sources/ClaudeQuota/Providers/ClaudeProvider.swift`
