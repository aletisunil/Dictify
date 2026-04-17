# Fix: first-launch "login keychain" password prompt

## Problem

On first launch after install, Dictify triggers the macOS Keychain ACL dialog
("Dictify wants to use your confidential information stored in … in your
keychain"), which demands the user's login password. This looks alarming for a
tool that hasn't even been configured yet, and is a real friction point for new
users.

## Root cause

Two compounding issues in `Dictify/Storage/KeychainManager.swift`:

1. The manager writes to the **legacy file-based login keychain** (no
   `kSecUseDataProtectionKeychain` flag). Items in that keychain carry an ACL
   tied to the code signature that created them. When a build with a different
   signature tries to read the item, macOS prompts for the login password to
   authorize the "new" app — regardless of our `LAContext.interactionNotAllowed`
   flag, which only suppresses biometric prompts.
2. `AppDelegate.applicationDidFinishLaunching` calls `refreshAPIKeyStatus()`
   synchronously at launch (via `AppState.keychainManager` didSet →
   `hasAPIKey` → `getAPIKey()`). So the read happens before the user has done
   anything, turning any stale-ACL condition into a "cold open" prompt.

Stale items appear any time a user had an earlier build installed (ad-hoc
signed dev build, an older Developer ID identity, or a pre-release with a
different Team ID).

## Goal

New users: **zero keychain prompts** on first launch, ever.
Upgraders: silent migration — no visible dialog; existing API key is preserved
when possible, otherwise the user is asked to re-enter it in Settings (no OS
password prompt).

## Plan

### 1. Move to the Data Protection Keychain

- Add `kSecUseDataProtectionKeychain: true` to every `SecItem*` query in
  `KeychainManager.swift` (`saveAPIKey`, `getAPIKey(service:)`,
  `getLegacyAPIKey`, `delete`, and the shared `keychainQuery` /
  `noPromptKeychainQuery` builders).
- The Data Protection Keychain governs access via code signature + Team ID +
  `keychain-access-groups` entitlement, not ACL prompts. No login-password
  dialog is possible.
- Drop the `LAContext` plumbing (`noPromptKeychainQuery`) once the DP keychain
  is in use — it's no longer needed and the name becomes misleading.

### 2. Entitlement

- Add to `Dictify/Dictify.entitlements`:
  ```xml
  <key>keychain-access-groups</key>
  <array>
    <string>$(AppIdentifierPrefix)com.sunilaleti.Dictify</string>
  </array>
  ```
  (Confirm the bundle identifier matches `PRODUCT_BUNDLE_IDENTIFIER` in
  `project.pbxproj`; adjust if different.)
- Verify the `$(AppIdentifierPrefix)` expands correctly during
  `scripts/sign-and-notarize.sh` signing. If not, hardcode the Team ID prefix
  (`TEAMID.com.sunilaleti.Dictify`).

### 3. One-shot legacy cleanup

On first launch of the DP-keychain build, evict any stale legacy item so
nothing can trigger a prompt later:

- Gate with `UserDefaults.standard.bool(forKey: "dictify.keychain.migratedToDP_v1")`.
- If not yet migrated:
  1. Attempt a legacy read (no `kSecUseDataProtectionKeychain`) using
     `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` so the read either
     returns the item or fails silently — never prompts.
  2. If a value came back, write it into the DP keychain via the new
     `saveAPIKey` path.
  3. Issue `SecItemDelete` against the legacy query regardless of read success
     (also with `kSecUseAuthenticationUIFail`) to clear stale ACL items.
  4. Set the `UserDefaults` flag.
- All of this happens off the main thread and must be failure-tolerant: any
  error is logged via `Log.storage` and silently ignored. The worst case is
  the user re-enters their API key in Settings — which is far better than a
  scary password dialog.

### 4. Lazy first read (belt-and-suspenders)

- Track API-key presence in `UserDefaults` (`dictify.hasAPIKey`) updated
  whenever `saveAPIKey` / `delete` is called. Initialize
  `AppState.hasAPIKeyConfigured` from this flag at launch.
- Keep the real keychain read lazy — triggered only when:
  - The user opens Settings → API, or
  - The transcription pipeline is about to call Groq.
- This guarantees launch never touches the keychain even if step 1 is
  somehow bypassed.

### 5. Signing / build hygiene

- Document in `BUILDING.md` that release builds **must** use a stable Team ID;
  changing it will orphan DP-keychain items on upgrade (same class of problem
  we just fixed). Note the `keychain-access-groups` entitlement.
- Verify `codesign -d --entitlements - /path/to/Dictify.app` after
  `package-dmg.sh` shows `keychain-access-groups` in the signed bundle.

### 6. Manual verification

Reproducible checklist before declaring the issue fixed:

1. Clean install on a second Mac that has never run Dictify.
2. Launch. Expect: no dialogs besides the normal onboarding.
3. Enter API key in Settings. Quit. Relaunch. Expect: no prompts, key still
   present.
4. Install an older pre-fix build of Dictify, enter a key, quit. Install the
   new build on top. Launch. Expect: no password prompt; either the key is
   silently migrated or the user is asked to re-enter it in-app (not via an OS
   dialog).
5. `security dump-keychain ~/Library/Keychains/login.keychain-db | grep Dictify`
   after step 4 should return nothing — the legacy item is gone.

## Out of scope

- Biometric/Touch ID gating of the API key (possible future enhancement; would
  be a separate toggle in Settings, not a fix for this bug).
- Syncing the API key across devices via iCloud Keychain — intentionally
  disabled (`kSecAttrSynchronizable = false`) and should stay that way.

## Files to touch

- `Dictify/Storage/KeychainManager.swift` — core rewrite.
- `Dictify/Dictify.entitlements` — add `keychain-access-groups`.
- `Dictify/App/AppState.swift` — add lazy `hasAPIKeyConfigured` backing via
  `UserDefaults`.
- `Dictify/App/AppDelegate.swift` — trigger one-shot migration off main thread
  after manager is constructed.
- `BUILDING.md` — note the Team ID / entitlement requirement.
- (Possibly) `Dictify/Utilities/Constants.swift` — add the access-group and
  migration-flag constants.

## Rollback

If the entitlement breaks signing in any environment, revert the
`keychain-access-groups` array; the DP keychain still works for a single-app
group when the Team ID is present, but the explicit entitlement is the
supported path. Keep the legacy-cleanup step regardless — it has no downside.
