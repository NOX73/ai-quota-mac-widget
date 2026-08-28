# Keychain Touch ID Instead of Password (idea, not implemented)

## Status

Draft idea only. Nothing in this doc is implemented — `KeychainService` and `build_app.sh`
are unchanged. No Apple Development certificate exists on the dev machine yet either
(`security find-identity` returns zero identities, and only Command Line Tools are installed,
no Xcode.app), so step 1 below hasn't been done.

## The problem

Every keychain access from this app currently prompts for the macOS **account password**,
not Touch ID, even though the Mac has Touch ID set up.

## Why it happens

`build_app.sh` ad-hoc signs the binary (`codesign --sign -`, see `build_app.sh` around the
`codesign` call) with no certificate chain and no Team ID — only a self-declared
`--identifier`. That pinning already solves the "re-prompt on every rebuild" problem, but it
doesn't change *what kind* of prompt macOS shows.

The keychain ACL prompt ("ClaudeQuota wants to access...") needs to verify who's asking before
it can offer a lightweight Touch ID confirmation instead of a full password. Verifying that
requires a code signature that chains to a trusted root. Ad-hoc signing has no such chain —
just a bare identifier the process can claim for itself — so macOS falls back to the strongest
proof available: the account password.

This is a general macOS behavior, not specific to this app or `KeychainService`'s
`kSecAttrAccessibleAfterFirstUnlock` setting (no `SecAccessControl`/biometry flags are set on
the stored items today).

## How to implement

1. **Get a code-signing identity with a real chain.** An **Apple Development** certificate is
   free (just needs an Apple ID, no paid Developer Program) and is created via Xcode
   (Settings → Accounts → Manage Certificates) or manually with a CSR through the Apple
   Developer site. Xcode.app isn't currently installed on this machine — only Command Line
   Tools — so this step requires installing Xcode first, or doing the CSR route by hand.
2. **Sign with that identity instead of ad-hoc** in `build_app.sh`: replace
   `codesign --force --sign - --identifier "$BUNDLE_ID" -r=...` with
   `codesign --force --sign "<identity name>" ...`. The designated requirement then comes from
   the certificate itself rather than a hand-pinned identifier string.
3. **Verify**: rebuild, run, and delete/re-add a keychain item to trigger the ACL prompt again.
   First run still needs one "Always Allow" (or Touch ID) confirmation; subsequent runs should
   not re-prompt as long as the signing identity doesn't change.
4. For actual distribution outside this dev machine later, the equivalent paid **Developer ID**
   certificate plus notarization would be needed — same effect on the keychain prompt, but also
   required for Gatekeeper on other people's Macs.

## Separate, unrelated option: per-item biometric lock

`SecAccessControl` with `.biometryAny` / `.biometryCurrentSet` (via
`SecAccessControlCreateWithFlags`) is a different mechanism: it protects a *specific* keychain
item behind Touch ID regardless of app signing, and would need to be added explicitly in
`KeychainService.save`/`load`. This makes access *more* restrictive (a Touch ID prompt on every
read), not less — it's the opposite of what's wanted here, which is to remove the friction on
the existing "app wants access" ACL prompt. Noting it here only so it isn't confused with the
fix above.
