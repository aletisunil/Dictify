# Product Requirements Document

## Dictify — Intelligent Voice-to-Text for macOS

**Version:** 1.0  
**Date:** April 14, 2026  
**Status:** Draft  
**Author:** Product Team

---

## 1. Executive Summary

Dictify is a native macOS application that transforms spoken words into clean, polished text in any application. Users hold the `fn` key to speak, and Dictify transcribes their voice in real-time using Groq's Whisper API, then refines the output with Llama to remove fillers, correct backtracks, auto-punctuate, and format lists — all before pasting the result directly into the active text field via macOS Accessibility APIs. The goal is to make voice dictation feel as natural and precise as typing, but three to five times faster.

---

## 2. Problem Statement

Built-in macOS dictation and most third-party tools produce raw transcriptions full of filler words ("um," "uh," "like"), accidental backtracks ("let's meet at 2… actually 3"), and no formatting. Users must manually clean up every dictated paragraph — defeating the purpose of speaking instead of typing. There is no system-wide tool on macOS that combines fast transcription with LLM-powered text refinement, personal dictionaries, and snippet expansion in a single, always-available utility.

---

## 3. Target Users

**Primary:** Knowledge workers, developers, writers, and professionals who spend significant time composing text across multiple applications (email, Slack, docs, code comments, CRMs).

**Secondary:** Users with repetitive strain injuries or motor disabilities who rely on voice input as their primary text entry method.

**Tertiary:** Non-native English speakers who think faster than they type and benefit from auto-correction and formatting.

---

## 4. Core User Flow

```
1. User focuses a text field in any macOS application
2. User presses and holds the `fn` key
3. Dictify begins capturing microphone audio
4. A floating transcription indicator appears at bottom-center of screen
5. User speaks naturally (including fillers, backtracks, formatting cues)
6. User releases the `fn` key
7. Audio is sent to Groq Whisper API for transcription
8. Raw transcript is sent to Groq Llama for refinement
9. Refined text is inserted into the active text field via Accessibility API
10. Floating indicator dismisses with a completion animation
```

---

## 5. Feature Requirements

### 5.1 Voice Capture & Activation

| ID | Requirement | Priority |
|----|------------|----------|
| VC-01 | Hold `fn` key to begin recording; release to stop and process | P0 |
| VC-02 | Support configurable activation key (fn, Ctrl, Option, or custom shortcut) | P1 |
| VC-03 | Use macOS `AVAudioEngine` for low-latency microphone capture | P0 |
| VC-04 | Record audio in 16kHz mono WAV/PCM format (Whisper-optimal) | P0 |
| VC-05 | Apply Voice Activity Detection (VAD) locally to trim silence at start/end | P1 |
| VC-06 | Show microphone permission prompt on first launch with clear explanation | P0 |
| VC-07 | Support recording durations from 0.5s to 120s per activation | P0 |
| VC-08 | Cancel recording if fn is released within 200ms (tap vs hold detection) | P1 |

### 5.2 Transcription (Groq Whisper)

| ID | Requirement | Priority |
|----|------------|----------|
| TR-01 | Send audio to Groq API using `whisper-large-v3-turbo` model | P0 |
| TR-02 | Use `verbose_json` response format to receive word-level timestamps | P1 |
| TR-03 | Include user's personal dictionary terms in the Whisper `prompt` parameter (max 224 tokens) to bias spelling | P0 |
| TR-04 | Support chunked upload for recordings over 25MB (Groq file size limit) | P1 |
| TR-05 | Handle API errors gracefully with retry (max 2 retries, exponential backoff) | P0 |
| TR-06 | Target end-to-end transcription latency under 500ms for a 10-second clip | P0 |
| TR-07 | Support language detection or explicit language selection in settings | P2 |

### 5.3 AI Text Refinement (Groq Llama)

| ID | Requirement | Priority |
|----|------------|----------|
| RF-01 | Send raw transcript to Groq `llama-3.3-70b-versatile` for post-processing | P0 |
| RF-02 | Remove filler words: "um," "uh," "like," "you know," "I mean," "sort of" | P0 |
| RF-03 | Resolve backtracks: "let's meet at 2… actually 3" → "let's meet at 3" | P0 |
| RF-04 | Auto-punctuate based on pauses and tonal cues from Whisper timestamps | P0 |
| RF-05 | Honor explicit dictation commands: "comma" → `,` / "period" → `.` / "question mark" → `?` / "exclamation point" → `!` / "new line" → `\n` / "new paragraph" → `\n\n` | P0 |
| RF-06 | Format numbered lists when user speaks sequential numbers: "1. Apples 2. Bananas 3. Oranges" → formatted list | P0 |
| RF-07 | Preserve the user's original meaning, tone, and vocabulary — do not paraphrase or "improve" content beyond cleanup | P0 |
| RF-08 | Expand snippet cues inline during refinement (see §5.6) | P1 |
| RF-09 | Target refinement latency under 300ms | P0 |
| RF-10 | Allow user to toggle refinement off (raw transcription mode) | P1 |

**Llama System Prompt (baseline):**

```
You are a voice-to-text post-processor. Your job is to clean up a raw voice
transcription while preserving the speaker's exact meaning and tone.

Rules:
1. Remove filler words (um, uh, like, you know, I mean, sort of, kind of)
2. When the speaker backtracks or corrects themselves, keep ONLY the corrected
   version. Example: "let's meet at 2... actually 3" → "let's meet at 3"
3. Add proper punctuation based on sentence boundaries and context
4. Convert dictation commands to punctuation: "comma" → , / "period" → . /
   "question mark" → ? / "exclamation point" → ! / "new line" → line break /
   "new paragraph" → double line break
5. When the speaker says sequential numbers followed by items, format as a
   numbered list
6. Do NOT change the speaker's word choices, add new content, summarize,
   or paraphrase. Only clean up.
7. Expand any snippet cues: [SNIPPETS_CONTEXT]

Return ONLY the cleaned text with no explanation or preamble.
```

### 5.4 Text Insertion (Accessibility)

| ID | Requirement | Priority |
|----|------------|----------|
| TI-01 | Detect the currently focused text element using macOS Accessibility API (`AXUIElement`) | P0 |
| TI-02 | Insert text at cursor position using `AXValueAttribute` / `AXSelectedTextRangeAttribute` | P0 |
| TI-03 | Fall back to clipboard paste (`Cmd+V` via `CGEvent`) if Accessibility insertion fails | P0 |
| TI-04 | Restore original clipboard contents after fallback paste | P0 |
| TI-05 | Request Accessibility permission on first launch with guided instructions | P0 |
| TI-06 | Detect and handle non-standard text fields (Electron apps, web browsers, terminal emulators) | P1 |
| TI-07 | Support inserting into rich text fields preserving the field's active formatting | P2 |
| TI-08 | Show a "permission denied" notification if Accessibility is not granted, with a button to open System Settings | P0 |

**Accessibility Permission Flow:**

```
App Launch → Check AXIsProcessTrusted()
  ├─ true  → Ready
  └─ false → Show onboarding sheet:
             "Dictify needs Accessibility access to type text into
              other applications."
             [Open System Settings] → Deep-link to:
             Privacy & Security → Accessibility
             Poll AXIsProcessTrusted() every 2s until granted
             → Show confirmation → Ready
```

### 5.5 Personal Dictionary

| ID | Requirement | Priority |
|----|------------|----------|
| PD-01 | Maintain a local JSON dictionary of custom terms, names, and spellings | P0 |
| PD-02 | Auto-add terms when user corrects a transcription within 30 seconds (detect via clipboard monitoring or manual correction UI) | P1 |
| PD-03 | Provide a settings UI to manually add, edit, and delete dictionary entries | P0 |
| PD-04 | Support import/export of dictionary as CSV or JSON | P2 |
| PD-05 | Inject up to 200 tokens of dictionary terms into the Whisper `prompt` parameter to bias recognition | P0 |
| PD-06 | Support phonetic hints: `"Kubernetes" → spoken as "koo-ber-net-eez"` | P2 |
| PD-07 | Group terms by category (names, technical terms, brand names) for organization | P2 |

**Dictionary Storage Format:**

```json
{
  "version": 1,
  "terms": [
    {
      "id": "uuid",
      "term": "Kubernetes",
      "category": "technical",
      "phonetic_hint": "koo-ber-net-eez",
      "added_at": "2026-04-14T10:00:00Z",
      "source": "manual"
    }
  ]
}
```

### 5.6 Snippets

| ID | Requirement | Priority |
|----|------------|----------|
| SN-01 | Allow users to create text snippets with a trigger cue (spoken keyword or phrase) | P0 |
| SN-02 | Store snippets locally with a cue, body, and optional category | P0 |
| SN-03 | When a cue is detected in transcription, replace it with the full snippet body during the Llama refinement step | P0 |
| SN-04 | Support dynamic variables in snippet body: `{{date}}`, `{{time}}`, `{{clipboard}}` | P1 |
| SN-05 | Provide a settings UI to create, edit, delete, and search snippets | P0 |
| SN-06 | Support multi-line snippet bodies (e.g., email templates, FAQs) | P0 |
| SN-07 | Import/export snippets as JSON | P2 |
| SN-08 | Show a confirmation toast when a snippet is expanded | P1 |

**Snippet Storage Format:**

```json
{
  "version": 1,
  "snippets": [
    {
      "id": "uuid",
      "cue": "calendar link",
      "body": "Here's my calendar link: https://cal.com/yourname/30min",
      "category": "meetings",
      "variables": [],
      "created_at": "2026-04-14T10:00:00Z"
    }
  ]
}
```

**Example Usage:**

> User speaks: *"Hey, let's find a time. Insert calendar link."*  
> Output: *"Hey, let's find a time. Here's my calendar link: https://cal.com/yourname/30min"*

### 5.7 Floating Transcription Indicator (UI)

| ID | Requirement | Priority |
|----|------------|----------|
| UI-01 | Display a floating panel at bottom-center of the active screen when recording | P0 |
| UI-02 | Panel should be a minimal pill-shaped overlay (approx. 300×60pt) | P0 |
| UI-03 | Show an animated audio waveform visualization during recording | P0 |
| UI-04 | Display state labels: "Listening…" → "Transcribing…" → "Done ✓" | P0 |
| UI-05 | Animate entrance (slide up + fade in) and exit (scale down + fade out) | P0 |
| UI-06 | Panel floats above all windows (`NSPanel` with `.floating` level) | P0 |
| UI-07 | Panel is non-interactive and does not steal focus from the active application | P0 |
| UI-08 | Respect macOS appearance mode (light/dark) automatically | P0 |
| UI-09 | Show elapsed recording time | P1 |
| UI-10 | Display a subtle error state with retry hint if transcription fails | P0 |

**Visual States:**

```
┌─────────────────────────────────────┐
│  ◉ ∿∿∿∿∿∿∿∿ Listening…      0:03  │   ← Recording (waveform animates)
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  ◉ ●●●○○○   Transcribing…         │   ← Processing (dots pulse)
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  ✓  Done                           │   ← Success (fades out after 0.8s)
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  ⚠  Failed — tap to retry          │   ← Error (persists until dismissed)
└─────────────────────────────────────┘
```

### 5.8 Menu Bar & Settings

| ID | Requirement | Priority |
|----|------------|----------|
| MB-01 | Run as a menu bar application (no Dock icon by default) | P0 |
| MB-02 | Menu bar icon indicates status: idle, recording, processing | P0 |
| MB-03 | Menu bar dropdown shows: recent transcriptions (last 10), settings, quit | P0 |
| MB-04 | Settings window with tabs: General, Dictionary, Snippets, API, About | P0 |
| MB-05 | General settings: activation key, refinement on/off, auto-launch at login, sound effects on/off | P0 |
| MB-06 | API settings: Groq API key input (stored in macOS Keychain), model selection | P0 |
| MB-07 | Transcription history: view, copy, and re-insert past transcriptions | P1 |
| MB-08 | Usage stats: total dictations, words transcribed, time saved estimate | P2 |

---

## 6. Technical Architecture

### 6.1 System Overview

```
┌──────────────────────────────────────────────────────┐
│                   Dictify.app                      │
│                                                      │
│  ┌──────────┐   ┌──────────┐   ┌────────────────┐   │
│  │  Input    │   │  Audio   │   │  Floating UI   │   │
│  │  Monitor  │──▶│  Engine  │──▶│  (NSPanel)     │   │
│  │ (fn key)  │   │(AVAudio) │   │                │   │
│  └──────────┘   └────┬─────┘   └────────────────┘   │
│                      │                               │
│                      ▼                               │
│              ┌───────────────┐                       │
│              │  Groq Client  │                       │
│              │               │                       │
│              │  ┌─────────┐  │                       │
│              │  │ Whisper  │──┼──▶ Raw Transcript    │
│              │  │ API      │  │                      │
│              │  └─────────┘  │                       │
│              │  ┌─────────┐  │                       │
│              │  │ Llama    │──┼──▶ Refined Text      │
│              │  │ API      │  │                      │
│              │  └─────────┘  │                       │
│              └───────────────┘                       │
│                      │                               │
│                      ▼                               │
│  ┌──────────────────────────────────────────────┐   │
│  │            Text Insertion Layer               │   │
│  │                                               │   │
│  │  AXUIElement (primary) → CGEvent paste (fb)   │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐   │
│  │ Dictionary │  │  Snippets  │  │  Keychain    │   │
│  │ (JSON)     │  │  (JSON)    │  │  (API keys)  │   │
│  └────────────┘  └────────────┘  └──────────────┘   │
└──────────────────────────────────────────────────────┘
```

### 6.2 Technology Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Language | Swift 5.9+ | Native macOS performance, full Accessibility API access |
| UI Framework | SwiftUI + AppKit (NSPanel) | SwiftUI for settings, AppKit for floating overlay and menu bar |
| Audio Capture | AVAudioEngine | Low-latency, real-time audio capture with format control |
| Key Monitoring | NSEvent global/local monitors | System-wide modifier key detection using existing Accessibility permission |
| Networking | URLSession / Swift Concurrency | Async/await for API calls |
| Local Storage | FileManager (JSON) + Keychain | Dictionary and snippets in Application Support; API key in Keychain |
| Text Insertion | Accessibility API (AXUIElement) | System-wide text field manipulation |
| Fallback Paste | CGEvent (Cmd+V simulation) | Handles apps with non-standard text fields |

### 6.3 Groq API Integration

**Transcription Request:**

```swift
// POST https://api.groq.com/openai/v1/audio/transcriptions
let formData = MultipartFormData()
formData.append(audioData, name: "file", fileName: "recording.wav", mimeType: "audio/wav")
formData.append("whisper-large-v3-turbo", name: "model")
formData.append("verbose_json", name: "response_format")
formData.append(dictionaryPrompt, name: "prompt")  // Inject dictionary terms
formData.append("0.0", name: "temperature")
```

**Refinement Request:**

```swift
// POST https://api.groq.com/openai/v1/chat/completions
let body: [String: Any] = [
    "model": "llama-3.3-70b-versatile",
    "messages": [
        ["role": "system", "content": systemPrompt],  // See §5.3
        ["role": "user", "content": rawTranscript]
    ],
    "temperature": 0.1,
    "max_tokens": 2048
]
```

### 6.4 Key Monitoring Implementation

```swift
// System-wide fn key detection using Accessibility-backed NSEvent monitoring
let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let fnPressed = flags.contains(.function)
    // Notify AudioEngine to start/stop recording
}

let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let fnPressed = flags.contains(.function)
    // Notify AudioEngine to start/stop recording
    return event
}
```

### 6.5 Text Insertion Implementation

```swift
// Primary: Accessibility API direct insertion
func insertText(_ text: String) {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedElement: AnyObject?
    AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    guard let element = focusedElement else {
        fallbackPaste(text)
        return
    }
    
    let axElement = element as! AXUIElement
    let result = AXUIElementSetAttributeValue(
        axElement,
        kAXValueAttribute as CFString,
        text as CFTypeRef
    )
    
    if result != .success {
        fallbackPaste(text)
    }
}

// Fallback: Clipboard paste with restore
func fallbackPaste(_ text: String) {
    let pasteboard = NSPasteboard.general
    let previousContents = pasteboard.string(forType: .string)
    
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    
    // Simulate Cmd+V
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V key
    keyDown?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
    keyUp?.flags = .maskCommand
    keyUp?.post(tap: .cghidEventTap)
    
    // Restore clipboard after delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        pasteboard.clearContents()
        if let previous = previousContents {
            pasteboard.setString(previous, forType: .string)
        }
    }
}
```

---

## 7. Accessibility Requirements

| ID | Requirement | Priority |
|----|------------|----------|
| AC-01 | Request and verify `Accessibility` permission (AXIsProcessTrusted) | P0 |
| AC-02 | Request and verify `Microphone` permission (AVCaptureDevice) | P0 |
| AC-04 | All settings UI elements must be fully VoiceOver-accessible | P0 |
| AC-05 | Floating indicator must announce state changes to VoiceOver ("Recording started," "Transcription complete") | P0 |
| AC-06 | Support keyboard-only navigation in all settings screens | P1 |
| AC-07 | Provide haptic feedback (trackpad) on recording start/stop if available | P2 |
| AC-08 | Sound effects for recording start (subtle click), stop, success, and error — with toggle to disable | P0 |
| AC-09 | High-contrast mode support for floating indicator | P1 |

**Required macOS Permissions (Info.plist):**

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Dictify needs microphone access to transcribe your voice.</string>

<key>NSAccessibilityUsageDescription</key>
<string>Dictify needs Accessibility access to insert transcribed text into other applications.</string>
```

**Required Entitlements:**

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

---

## 8. Data & Privacy

| Concern | Approach |
|---------|----------|
| Audio data | Sent to Groq API over HTTPS; never stored locally beyond the recording session buffer. Buffer cleared immediately after API response. |
| API key | Stored in macOS Keychain (encrypted at rest by the OS). Never logged or transmitted anywhere except Groq API headers. |
| Dictionary & Snippets | Stored as JSON in `~/Library/Application Support/Dictify/`. User-owned, local-only. |
| Transcription history | Stored locally in Application Support. User can clear or disable history in settings. |
| Analytics | No telemetry or analytics in v1. Opt-in crash reporting may be added in future versions. |

---

## 9. Error Handling

| Scenario | Behavior |
|----------|----------|
| No internet connection | Show floating indicator error: "No connection." Queue audio for retry when connection returns. |
| Groq API rate limit (429) | Retry after `Retry-After` header value. Show "Busy, retrying…" in indicator. |
| Groq API error (500/503) | Retry up to 2 times with exponential backoff (1s, 3s). Show error after exhaustion. |
| Invalid API key | Show persistent notification with link to API settings. |
| Microphone permission denied | Show alert on activation attempt with button to open System Settings. |
| Accessibility permission denied | Show alert with step-by-step instructions to enable in System Settings → Privacy & Security. |
| Recording too short (<0.5s) | Discard silently (tap detection). |
| Recording too long (>120s) | Auto-stop recording, process what was captured, show "Max recording length reached." |
| Empty transcription result | Show "Couldn't detect speech. Try again." in indicator. |
| Focused element is not a text field | Fall back to clipboard paste. If paste also fails, copy to clipboard and show "Text copied to clipboard." |

---

## 10. Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Recording start latency | < 50ms from fn key press to audio capture start | Instrument with os_signpost |
| Transcription latency | < 500ms for 10s audio clip | API round-trip time |
| Refinement latency | < 300ms for typical transcript (50–200 words) | API round-trip time |
| Total end-to-end latency | < 1.2s from fn release to text insertion | Full pipeline timing |
| Memory usage (idle) | < 30MB | Activity Monitor |
| Memory usage (recording) | < 80MB | Activity Monitor |
| CPU usage (idle) | < 0.5% | Activity Monitor |
| App bundle size | < 15MB | Finder |
| Cold launch time | < 1.5s to menu bar ready | XCTest measure |

---

## 11. Release Plan

### Phase 1 — MVP (Weeks 1–6)

Core voice-to-text pipeline: fn key activation, Groq Whisper transcription, Llama refinement, Accessibility text insertion, floating indicator with waveform animation, menu bar app shell, basic settings (API key, activation key), and error handling.

### Phase 2 — Personalization (Weeks 7–10)

Personal dictionary with auto-learn, snippet creation and expansion, transcription history, configurable refinement modes (raw, clean, format), sound effects and haptic feedback.

### Phase 3 — Polish (Weeks 11–14)

VoiceOver accessibility audit and fixes, high-contrast / reduced motion support, onboarding flow with permission walkthrough, import/export for dictionary and snippets, usage statistics dashboard, performance optimization and edge-case hardening.

### Phase 4 — Future Considerations

Multi-language support, local Whisper fallback (offline mode via whisper.cpp), custom Llama fine-tuning for user writing style, team snippet sharing (via iCloud or shared JSON), iOS companion app, streaming transcription (display words as they're recognized).

---

## 12. Open Questions

1. **Streaming vs. batch transcription:** Groq currently processes complete audio files. Should we implement a local VAD-based chunking system to send audio segments as the user speaks for progressive feedback, or is the sub-second batch latency sufficient?

2. **Correction UX:** How should users correct a transcription? Options include: (a) an inline edit popup before insertion, (b) undo with Cmd+Z and re-dictate, or (c) a correction mode that also auto-updates the dictionary.

3. **Multi-monitor behavior:** Should the floating indicator follow the active screen, the mouse cursor, or always appear on the primary display?

4. **Pricing model:** Free tier with a bundled Groq key (rate-limited) vs. BYOK (bring your own key) only vs. subscription wrapping Groq costs.

5. **Snippet conflict resolution:** What happens when a dictionary term and a snippet cue overlap? Which takes precedence?

---

## 13. Success Metrics

| Metric | Target (90 days post-launch) |
|--------|------------------------------|
| End-to-end success rate | > 95% of dictations result in correctly inserted text |
| User retention (weekly active) | > 40% of installers use Dictify at least 3x/week |
| Average dictations per user per day | > 8 |
| Transcription accuracy (WER) | < 5% on English conversational speech |
| Refinement accuracy | > 90% of filler removals and backtrack resolutions are correct |
| Crash-free sessions | > 99.5% |
| App Store rating | > 4.5 stars |

---

## Appendix A: Dictation Command Reference

| Spoken Command | Output |
|---------------|--------|
| "period" / "full stop" | `.` |
| "comma" | `,` |
| "question mark" | `?` |
| "exclamation point" / "exclamation mark" | `!` |
| "colon" | `:` |
| "semicolon" | `;` |
| "new line" | Line break |
| "new paragraph" | Double line break |
| "open quote" / "close quote" | `"` |
| "open paren" / "close paren" | `(` / `)` |
| "dash" / "hyphen" | `—` / `-` |
| "ellipsis" | `…` |

## Appendix B: Competitive Landscape

| Feature | Wispr Flow | macOS Dictation | Dictify (Ours) |
|---------|-----------|----------------|-----------------|
| Filler removal | Yes | No | Yes |
| Backtrack resolution | Yes | No | Yes |
| Auto formatting (lists) | Yes | No | Yes |
| Personal dictionary | Yes | Limited | Yes |
| Snippets | No (as of research date) | No | Yes |
| API flexibility | Proprietary | Apple on-device | Groq (Whisper + Llama) |
| Open model stack | No | No | Yes |
| Pricing | $8–$24/mo | Free | TBD (BYOK option) |
| Platforms | macOS, Windows, Android | Apple only | macOS (v1) |
