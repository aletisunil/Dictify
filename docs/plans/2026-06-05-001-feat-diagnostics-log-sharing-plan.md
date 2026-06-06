---
title: "feat: Diagnostics log collection + share-with-developer"
type: feat
status: active
date: 2026-06-05
depth: standard
---

# feat: Diagnostics log collection + share-with-developer

## Summary

Give users a one-tap way to collect Dictify's recent logs into a privacy-safe text bundle and hand it to the developer (copy to clipboard, save to disk, or pre-filled email), so that when "something went wrong" the developer can see what actually happened. Logs are read back from the unified logging system via `OSLogStore`, filtered to the app's subsystem — the existing 49 `os.Logger` call sites stay as-is. A redaction pass guarantees transcripts and API keys never appear in a shared bundle. A logging-coverage audit fills the gaps (app lifecycle, API request outcomes, permission state) so the bundle is actually diagnostic.

This is local-only: no remote upload, no telemetry, no crash reporter.

---

## Problem Frame

Today Dictify logs through `os.Logger` (subsystem `com.dictify.app`, 7 categories — see [Log.swift](Dictify/Utilities/Log.swift)). Those logs are only visible to a developer who attaches Console.app or runs `log stream` on the user's machine — impossible for a shipped app used by remote users. When a user hits an error (the pipeline surfaces `.error(msg)` in the floating indicator and main window), there is no way for them to send the developer anything beyond a prose email to `iam@sunilaleti.dev` via the About tab's feedback link ([AboutSettingsView.swift:70](Dictify/UI/Settings/AboutSettingsView.swift)).

Two gaps:
1. **No collection/share path** — logs are trapped on-device with no UI to extract them.
2. **Thin coverage in places** — some failure-relevant areas (app launch/version, API call outcomes, permission transitions) under-log, so even a collected bundle may not explain a failure.

## Goals

- A user can produce a shareable log bundle from the app in one or two clicks.
- The bundle covers a recent, useful window of activity and includes basic environment context (app version, OS version, device model).
- The bundle is **safe to share**: no API keys, no transcript/refined text content, no PII beyond what's diagnostically necessary.
- The developer receives enough signal to diagnose common failures without a back-and-forth.
- Logging coverage is good enough that the common failure modes show up in the bundle.

## Non-Goals

- Remote/automatic log upload or telemetry.
- Crash reporting / symbolicated crash logs (separate concern; OSLogStore does not carry crashes).
- Analytics or usage metrics.
- A full in-app log viewer/console (a short preview is enough).

---

## Key Technical Decisions

### KTD1. Capture via `OSLogStore.local()`, not a file-sink rewrite

The app is **not sandboxed** (`com.apple.security.app-sandbox = false` in [Dictify.entitlements](Dictify/Dictify.entitlements)), so `OSLogStore.local(scope:)` can read the process's own unified-log entries at share time. We filter to `subsystem == com.dictify.app` and a recent time window. This keeps all 49 existing `Log.<category>.<level>(...)` call sites untouched and preserves the native `privacy:` specifiers already in use.

Rejected: a file-sink tee (custom logger writing a rotating plaintext file + mirroring to `os.Logger`). It would force rewriting all 49 sites to drop the `OSLogMessage` privacy interpolation and re-implement redaction by hand. More code, more risk, no benefit given sandbox is off.

### KTD2. Treat OSLogStore output as untrusted and run an explicit redaction pass

When a process reads its **own** subsystem logs via `OSLogStore`, `.private` interpolations may be returned **unredacted** (the system trusts same-process reads). We therefore do **not** rely on `os.Logger`'s privacy redaction for the shared bundle. Every collected line passes through a redaction scrubber (KTD covered by U3) before it can be copied/saved/emailed. This is a hard security gate — the bundle must be scrubbed even if a future log site forgets a `privacy:` specifier.

Whether same-process reads are redacted or not is verified empirically during U2 implementation; the redaction pass (U3) is mandatory regardless of that outcome, so correctness does not depend on the answer.

### KTD3. Bundle is plaintext with a header block

Format: a header (app version, build, macOS version, device model, capture window, line count, a "redacted — safe to share" banner) followed by chronological `timestamp [category] level  message` lines. Plaintext is trivially copy/paste-able, email-body-friendly, and human-readable for the developer. No JSON/zip — there are no attachments (mailto cannot attach) and no binary payloads.

### KTD4. Three export actions, no attachment dependency

- **Copy Logs** → redacted bundle to `NSPasteboard`.
- **Save Bundle…** → `NSSavePanel` writes `dictify-logs-<timestamp>.txt`.
- **Email developer** → opens `mailto:iam@sunilaleti.dev` with a pre-filled subject and a short body; because `mailto:` cannot attach files, this action first saves the bundle and reveals it in Finder, then opens the mail draft instructing the user to attach it. (Reuses the existing feedback address from [AboutSettingsView.swift](Dictify/UI/Settings/AboutSettingsView.swift).)

### KTD5. Bounded collection window and size

Default to the last ~30 minutes or last N entries (whichever is smaller), capped at a max line count / byte budget, to keep `OSLogStore` reads fast and bundles email-sized. The window/cap are constants (mirror the `Constants` pattern in [Constants.swift](Dictify/Utilities/Constants.swift)).

---

## Output Structure

New files (under existing `Dictify/` layout):

```
Dictify/
  Diagnostics/
    LogCollector.swift        # U2 — OSLogStore read + filter + window
    LogRedactor.swift         # U3 — scrubbing rules
    DiagnosticsBundle.swift   # U4 — header + formatting + export helpers
DictifyTests/
  LogRedactorTests.swift      # U3 tests
  DiagnosticsBundleTests.swift# U4 tests
```

(If no test target exists yet, U3/U4 introduce one — see Risks.)

---

## Implementation Units

### U1. Logging coverage audit + enrichment

**Goal:** Make sure the common failure modes actually appear in collected logs.

**Requirements:** Goals — "covers a recent, useful window"; "common failure modes show up".

**Dependencies:** none (can land first; independent of collection).

**Files:**
- [Dictify/App/AppDelegate.swift](Dictify/App/AppDelegate.swift) — log app launch with version/build, App Support dir readiness.
- [Dictify/App/AppState.swift](Dictify/App/AppState.swift) — log pipeline state transitions into `.error`.
- [Dictify/Core/API/GroqClient.swift](Dictify/Core/API/GroqClient.swift), [WhisperService.swift](Dictify/Core/API/WhisperService.swift), [LlamaService.swift](Dictify/Core/API/LlamaService.swift) — log request start, HTTP status, latency, and error category on failure. **Never** log API key, audio bytes, transcript, or refined text (use `privacy: .private` or omit entirely).
- [Dictify/Core/Permissions/PermissionManager.swift](Dictify/Core/Permissions/PermissionManager.swift) — log permission grant/deny transitions (mic, accessibility).
- [Dictify/Core/HotKey/KeyMonitor.swift](Dictify/Core/HotKey/KeyMonitor.swift) — log trigger registration failures.

**Approach:** Reuse the existing `Log.<category>` instances. Add `notice`/`error` lines at decision and failure points only — not per-buffer or per-keystroke (avoid log spam that blows the window in KTD5). Keep content non-sensitive: status codes, durations, error descriptions, boolean states. Audit each new site against the redaction rules (U3) so nothing sensitive relies solely on scrubbing.

**Patterns to follow:** existing privacy-aware style, e.g. `Log.pipeline.error("Pipeline error: \(message, privacy: .public)")` ([TranscriptionPipeline.swift:458](Dictify/Core/Pipeline/TranscriptionPipeline.swift)).

**Test scenarios:** `Test expectation: none — logging-only changes, no behavioral output to assert.` Manual verification via `log stream --predicate 'subsystem == "com.dictify.app"'` while exercising launch, a failed API call (bad key), and a denied permission.

**Verification:** Running each failure path produces a clearly labeled log line under the right category, and no line contains a key/transcript.

---

### U2. `LogCollector` — read recent entries from OSLogStore

**Goal:** Pull recent `com.dictify.app` entries into structured records.

**Requirements:** Goals — "produce a shareable log bundle"; "recent, useful window"; KTD1, KTD5.

**Dependencies:** none (consumed by U4).

**Files:**
- `Dictify/Diagnostics/LogCollector.swift` (new)
- `Dictify/Utilities/Constants.swift` (add `Diagnostics` window/cap constants)

**Approach:**
- `OSLogStore.local()` (or `OSLogStore(scope: .currentProcessIdentifier)` if `.local()` proves too slow/broad — decide during impl).
- Build a position from `Date().addingTimeInterval(-window)`; enumerate entries; keep only `OSLogEntryLog` where `subsystem == Constants.bundleIdentifier`.
- Map each to a lightweight `LogRecord { date, category, level, message }`.
- Apply the entry cap (KTD5) and run on a background queue (read can be slow); collection is `async` / completion-based so the UI doesn't block.
- Handle the throwing API: if `OSLogStore` is unavailable or throws, return a single synthetic record explaining collection failed (so the bundle is never silently empty).

**Patterns to follow:** `Constants` enum nesting; `Log.subsystem`/`Constants.bundleIdentifier` already equal `com.dictify.app`.

**Technical design (directional, not spec):**
```
func collect(window: TimeInterval, cap: Int) async -> [LogRecord]
  store = try OSLogStore.local()
  pos   = store.position(date: now - window)
  for entry in store.getEntries(at: pos) where entry is OSLogEntryLog && entry.subsystem == bundleID:
      append LogRecord(...); stop at cap
  on throw -> [LogRecord(synthetic "collection failed: <err>")]
```

**Test scenarios:**
- Returns only records whose subsystem matches `com.dictify.app` (filtering correctness) — drive by emitting a known marker log, then collecting, asserting the marker is present and an unrelated subsystem is absent.
- Respects `cap`: never returns more than `cap` records.
- Respects `window`: an entry older than the window is excluded (boundary).
- OSLogStore throw path returns exactly one synthetic failure record, not an empty array (error path).

*Note:* OSLogStore tests are integration-flavored and timing-sensitive; gate them so they don't run in environments without unified-log access (see Risks).

**Verification:** Collecting after exercising the app returns recent app lines in chronological order; unrelated system logs are excluded.

---

### U3. `LogRedactor` — scrub sensitive content (security gate)

**Goal:** Guarantee no API key, transcript/refined text, or obvious PII survives into a shared bundle.

**Requirements:** Goals — "safe to share"; KTD2.

**Dependencies:** none (consumed by U4); must exist before any export ships.

**Files:**
- `Dictify/Diagnostics/LogRedactor.swift` (new)
- `DictifyTests/LogRedactorTests.swift` (new)

**Approach:** Pure, deterministic, well-tested string transform over each `LogRecord.message`:
- Redact Groq-style API keys (`gsk_…` and generic long bearer-token shapes) → `<redacted-key>`.
- Redact `Authorization: Bearer …` headers if any leak.
- Redact anything tagged by a convention marker the audit (U1) can use for known-sensitive values.
- Collapse/replace email addresses and absolute user home paths (`/Users/<name>/…` → `/Users/<redacted>/…`) to reduce PII.
- Length-cap individual lines to avoid a stray transcript dump.

This is defense-in-depth on top of `privacy:` specifiers, per KTD2. Redaction must be conservative: over-redact rather than risk a leak.

**Execution note:** Implement test-first — write the failing redaction assertions, then the rules. This is a security boundary; tests are the spec.

**Test scenarios:**
- `gsk_` key embedded mid-line → replaced, surrounding text preserved.
- `Authorization: Bearer abc.def.ghi` → token replaced.
- Absolute home path `/Users/sunilaleti/Documents/...` → username redacted, rest of path intact.
- Email address in a message → masked.
- A line with no sensitive content → returned unchanged (no false positives breaking readability).
- Over-long line (> cap) → truncated with an explicit `…[truncated]` marker.
- Idempotency: redacting already-redacted text changes nothing.

**Verification:** Test suite green; a crafted record containing a fake key + transcript yields a bundle with neither value present.

---

### U4. `DiagnosticsBundle` — assemble header + formatted, redacted text + export helpers

**Goal:** Turn collected+redacted records into the final shareable string and provide copy/save/email helpers.

**Requirements:** Goals — "one or two clicks"; "basic environment context"; KTD3, KTD4.

**Dependencies:** U2 (collection), U3 (redaction).

**Files:**
- `Dictify/Diagnostics/DiagnosticsBundle.swift` (new)
- `DictifyTests/DiagnosticsBundleTests.swift` (new)

**Approach:**
- `build() async -> String`: collect (U2) → redact each (U3) → format.
- Header: `Dictify <version> (<build>)`, `macOS <ProcessInfo.operatingSystemVersionString>`, device model (`sysctl hw.model` or `ProcessInfo`), capture window, record count, and a banner: `# Logs redacted for sharing — no API keys or transcript text included.`
- Body: `HH:mm:ss.SSS [category] LEVEL  message` per line, chronological.
- Export helpers (pure where possible, side-effecting wrappers thin):
  - `copyToPasteboard(_:)`
  - `saveBundle(_:) -> URL?` via `NSSavePanel`, default name `dictify-logs-<ISO timestamp>.txt`.
  - `revealInFinder(_:)` + `composeEmail(bundleURL:)` building the `mailto:` URL (reuse subject pattern from [AboutSettingsView.swift:73](Dictify/UI/Settings/AboutSettingsView.swift)).

**Patterns to follow:** version read via `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` and the `mailto:` subject-encoding pattern already in `AboutSettingsView`.

**Test scenarios:**
- Header contains app version, OS version, and the redaction banner.
- Records render in chronological order with category + level visible.
- Empty collection → bundle still has a valid header and a "no recent log entries" note (edge case).
- Every body line has passed through redaction (integration: feed a record with a fake key, assert absent in final string). Covers the U3↔U4 seam that mocks alone wouldn't prove.
- Save filename matches `dictify-logs-*.txt` shape.

**Verification:** `build()` on a populated store yields a readable, redacted, header-prefixed string; save/copy/email helpers operate on that string.

---

### U5. About-tab UI — Diagnostics section with the three actions

**Goal:** Expose log sharing where users already look for support.

**Requirements:** Goals — "in one or two clicks"; KTD4; placement decision (About tab).

**Dependencies:** U4.

**Files:**
- [Dictify/UI/Settings/AboutSettingsView.swift](Dictify/UI/Settings/AboutSettingsView.swift)

**Approach:** Add a "Diagnostics" group under the existing "Feedback & Support" block:
- A short explainer line: "Something went wrong? Share your recent logs so the developer can investigate. Logs are redacted — no API keys or dictated text are included."
- Buttons: **Copy Logs**, **Save Bundle…**, **Email Logs to Developer** (the last reuses the existing feedback address and does save-then-reveal-then-mailto per KTD4).
- Async build with a brief in-progress state (button disabled + spinner) since collection is off-main.
- Optional: a small scrollable, read-only preview of the last ~20 redacted lines so the user sees what they're sending (transparency builds trust). Keep it compact to fit the existing About layout.

**Patterns to follow:** existing `VStack`/`Label`/`Link` styling and `.help(...)` tooltips in `AboutSettingsView`; `@EnvironmentObject var appState` wiring used by sibling settings views.

**Test scenarios:** `Test expectation: none — SwiftUI view wiring; covered indirectly by U4 helpers.` Manual verification: click each button, confirm clipboard contents / saved file / mail draft, and confirm the preview shows redacted lines.

**Verification:** From a fresh launch, a user can open Settings → About, click Copy Logs, and paste a redacted, header-prefixed bundle; Save and Email actions produce the same content via their channels.

---

## Risks & Dependencies

- **OSLogStore same-process redaction behavior is unverified.** Mitigation: U3 redaction is mandatory and independent of this behavior (KTD2). Verify empirically in U2 but do not depend on it.
- **OSLogStore performance / availability.** `.local()` reads can be slow and may throw. Mitigation: background collection, bounded window/cap (KTD5), synthetic failure record on throw (U2).
- **No test target may exist yet.** `DictifyTests` is referenced but unconfirmed. Mitigation: U3 (first to need tests) creates the unit-test target if absent; treat target creation as part of U3. Verify with `xcodebuild -list` / project inspection before writing tests.
- **Log spam shrinking the useful window.** Over-logging in U1 could push real errors out of the KTD5 window. Mitigation: log at decision/failure points only, not per-buffer/keystroke.
- **Redaction false-negatives = leak.** A new sensitive log site could slip a value past the scrubber. Mitigation: conservative over-redaction, U1 audit cross-checks each new site, idempotent redactor, line-length cap as backstop.

## Deferred to Follow-Up Work

- Remote/automatic log upload or an opt-in telemetry channel.
- Crash report capture/symbolication.
- Bundling `history.json`/settings snapshots into the diagnostics (privacy-heavy; needs its own redaction design).
- A full in-app log viewer with category filtering.

## Sources & Research

- Existing logging facade: [Log.swift](Dictify/Utilities/Log.swift) (subsystem `com.dictify.app`, 7 categories + signposts).
- Sandbox status: [Dictify.entitlements](Dictify/Dictify.entitlements) (`app-sandbox = false`) — enables `OSLogStore.local()`.
- Feedback channel + version/mailto patterns to reuse: [AboutSettingsView.swift](Dictify/UI/Settings/AboutSettingsView.swift).
- Storage/paths + constants convention: [Constants.swift](Dictify/Utilities/Constants.swift).
- Settings tab structure: [SettingsView.swift](Dictify/UI/Settings/SettingsView.swift).
