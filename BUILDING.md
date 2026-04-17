# Building & Signing Dictify

This doc is the single source of truth for how to build, sign, notarize, and package Dictify after making code changes. Every command assumes you're in the repo root (`/Users/sunilaleti/Documents/Dictify`).

---

## One-time setup (only needed once per machine)

### 1. Apple Developer ID

You need a paid Apple Developer account. From <https://developer.apple.com/account/resources/certificates/list>, create (or download) a **Developer ID Application** certificate and install it into your login keychain.

Find its full identity string:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Copy the exact quoted name, e.g. `Developer ID Application: Sunil Aleti (ABCDE12345)`.

### 2. Notarization credentials

Create an app-specific password at <https://appleid.apple.com/account/manage> (Sign-In and Security → App-Specific Passwords), then store it in the keychain under a profile name Dictify's scripts reference as `NOTARY_PROFILE`:

```bash
xcrun notarytool store-credentials dictify-notary \
  --apple-id "your-apple-id@example.com" \
  --team-id "5432YAY2UX" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

`dictify-notary` is the profile name — reuse it in the env var below.

Verify the profile can talk to Apple's notary service:

```bash
xcrun notarytool history --keychain-profile dictify-notary
```

### 3. Shell env vars

Add these to `~/.zshrc` so every terminal has them:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Sunil Aleti (ABCDE12345)"
export NOTARY_PROFILE="dictify-notary"
```

Reload with `source ~/.zshrc`.

Or set them only for the current terminal session:

```bash
export DEVELOPER_ID_APPLICATION="$(security find-identity -v -p codesigning | sed -n 's/.*\"\(Developer ID Application:.*\)\".*/\1/p' | head -n 1)"
export NOTARY_PROFILE="dictify-notary"
```

Confirm the values before running a release:

```bash
printf 'DEVELOPER_ID_APPLICATION=%s\n' "$DEVELOPER_ID_APPLICATION"
printf 'NOTARY_PROFILE=%s\n' "$NOTARY_PROFILE"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
```

> Without these, scripts fall back to ad-hoc signing (works only on your own Mac — Gatekeeper rejects it everywhere else).

---

## Production signing quick reference

Use this flow when you want to share `Dictify.dmg` with someone else.

### Recommended: build, sign, notarize, and package everything

```bash
cd /Users/sunilaleti/Documents/Dictify
./scripts/package-dmg.sh
```

This is the production command. It builds `Dictify.app`, signs and notarizes the
app, creates `dist/Dictify.dmg`, then signs, notarizes, staples, and checksums
the DMG.

### Manual: notarize an existing app, then sign/notarize an existing DMG

Use these only when you already have the app or DMG and do not want to rebuild:

```bash
cd /Users/sunilaleti/Documents/Dictify
./scripts/sign-and-notarize.sh app /path/to/Dictify.app
./scripts/sign-and-notarize.sh dmg /path/to/Dictify.dmg
```

The first command signs `Dictify.app` with the Developer ID Application
certificate, submits a zipped copy to Apple notarization, staples the ticket to
the app, and validates Gatekeeper assessment.

The second command signs the DMG with the same Developer ID Application
certificate, submits the DMG to Apple notarization, staples the ticket to the
DMG, and runs a Gatekeeper assessment for opening the disk image.

Do not share the DMG if `codesign -dv --verbose=4 dist/Dictify.dmg` reports
`Signature=adhoc` or if `xcrun stapler validate dist/Dictify.dmg` fails.

---

## Everyday workflows

### Just compile / smoke-test after a code change

```bash
xcodebuild -project Dictify.xcodeproj -scheme Dictify -configuration Debug build
```

Runs through the full compile; surfaces errors. Use this as your "did I break anything" check.

### Run the app locally (Debug)

Open `Dictify.xcodeproj` in Xcode and press ⌘R — fastest feedback loop. No signing needed.

### Ship a signed, notarized DMG

This is the one command you run before publishing a release:

```bash
./scripts/package-dmg.sh
```

What it does, end-to-end:

1. Builds Release configuration unsigned to `/tmp/DictifyDerived`.
2. Stages `Dictify.app` into a temp dir.
3. Calls `sign-and-notarize.sh app` → deep-signs with hardened runtime + timestamp, submits to Apple notary, staples the ticket.
4. Builds a UDZO-compressed DMG with custom background + Applications symlink layout.
5. Signs, notarizes, and staples the DMG itself.
6. Writes `dist/Dictify.dmg` and `dist/Dictify.dmg.sha256`.

Notarization typically takes 2–5 minutes. The script waits for Apple's response.

---

## Partial flows (debugging)

### Sign an already-built .app without notarizing

```bash
SKIP_NOTARIZE=1 ./scripts/sign-and-notarize.sh app /path/to/Dictify.app
```

Useful to verify signing works before committing to a full notarize round-trip.

### Sign+notarize only (skip DMG rebuild)

```bash
./scripts/sign-and-notarize.sh app /path/to/Dictify.app
./scripts/sign-and-notarize.sh dmg /path/to/Dictify.dmg
```

### Ad-hoc sign for local testing (no Developer ID)

Unset the env var for one command:

```bash
DEVELOPER_ID_APPLICATION= ./scripts/package-dmg.sh
```

Runs the full pipeline but skips notarization. The resulting DMG will only open on your Mac.

---

## Verifying a signed build

After `package-dmg.sh` finishes:

```bash
# Verify the .app inside the DMG
hdiutil attach dist/Dictify.dmg
codesign --verify --deep --strict --verbose=2 /Volumes/Dictify/Dictify.app
spctl --assess --type execute --verbose=4 /Volumes/Dictify/Dictify.app
xcrun stapler validate /Volumes/Dictify/Dictify.app
hdiutil detach /Volumes/Dictify

# Verify the DMG ticket
xcrun stapler validate dist/Dictify.dmg
```

Everything should print `accepted` / `valid`. If any step fails, the build isn't safe to ship.

---

## Releasing a new version

1. Bump `MARKETING_VERSION` in `Dictify.xcodeproj/project.pbxproj` (both Debug and Release XCBuildConfiguration blocks).
2. Optionally bump `CURRENT_PROJECT_VERSION` (build number).
3. Commit the version bump.
4. Run `./scripts/package-dmg.sh`.
5. Attach `dist/Dictify.dmg` and `dist/Dictify.dmg.sha256` to the GitHub release.

---

## Common failures

| Symptom | Cause / Fix |
|---|---|
| `errSecInternalComponent` during codesign | Keychain locked or Developer ID cert not in login keychain. Unlock keychain or re-import cert. |
| `The timestamp service is not available` | Apple's timestamp server hiccup — just retry. |
| Notarization returns `Invalid` | Check the log: `xcrun notarytool log <submission-id> --keychain-profile dictify-notary`. Usually a nested binary missing hardened runtime. |
| `spctl: rejected` after stapling | Staple didn't apply — re-run `xcrun stapler staple`. Check that your Mac has internet (Gatekeeper phones home). |
| New Swift file doesn't compile (`cannot find 'X' in scope`) | File not registered in `Dictify.xcodeproj/project.pbxproj`. Add entries in PBXBuildFile, PBXFileReference, the relevant PBXGroup, and PBXSourcesBuildPhase. |

---

## Keychain signing requirement

Dictify stores the Groq API key in the macOS Keychain. Release builds must keep
the same bundle identifier (`com.dictify.app`) so saved API keys remain readable
after updates.

`Dictify/Dictify.entitlements` intentionally does not include
`keychain-access-groups`. Developer ID apps without an embedded provisioning
profile are blocked by AMFI when they carry that restricted entitlement, and
Dictify's keychain queries do not request a custom access group. If the bundle
identifier changes, expect users to re-enter the API key in Dictify Settings
rather than migrating the old keychain item.

---

## File-by-file reference

- `scripts/sign-and-notarize.sh` — signing + notarization primitives. Accepts `app` or `dmg`.
- `scripts/package-dmg.sh` — full release pipeline. This is the command you run.
- `scripts/assets/dmg-background.png` — background image baked into the DMG window.
- `Dictify/Dictify.entitlements` — entitlements applied during signing (microphone, no sandbox).
- `Dictify/Resources/PrivacyInfo.xcprivacy` — required privacy manifest (UserDefaults, FileTimestamp, SystemBootTime reasons).
- `dist/` — output directory for signed DMG + checksum. Gitignored.
