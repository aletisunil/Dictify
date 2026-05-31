# Dictify

Hold `fn`, speak, get polished text anywhere on macOS.

Dictify is a native macOS app that turns speech into clean, punctuated text and inserts it directly into whatever app you're focused on. It uses Groq Whisper for transcription and Groq Llama to strip fillers, resolve backtracks, and auto-punctuate on the fly.

![Dictify](screenshots/Home.png)


## Features

### Voice-activated dictation

Hold `fn` (or any shortcut you prefer) to record. Release to transcribe and insert. A minimal floating indicator at the bottom of the screen shows recording state and elapsed time — no windows to focus, no modes to switch.

[![Watch the demo](https://img.youtube.com/vi/uoDtB8owK8Q/maxresdefault.jpg)](https://youtu.be/uoDtB8owK8Q)

### AI refinement, your choice of speed

Groq Llama cleans up what you actually said: removes "um" / "uh" / "like", resolves self-corrections ("meet at 2, actually 3" → "meet at 3"), and adds punctuation. Pick **Quality** (`llama-3.3-70b-versatile`, best cleanup) or **Fast** (`llama-3.1-8b-instant`, lower latency) per your preference.

![General settings](screenshots/General.png)

### One home for everything

Home, history, dictionary, snippets, and settings all live in a single main window with a sidebar. The Home tab shows live stats — session words, total words, words-per-minute, and your most recent transcriptions. Close the window whenever you like; the global hotkey keeps working in the background, and a menu bar icon is always there for a quick reopen or quit.

### Snippets with categories

Spoken triggers that expand to full text blocks. Organize them by category (email, contact, general, …) and use built-in variables like `{{date}}`, `{{time}}`, and `{{clipboard}}`.

![Snippets](screenshots/Snippets.png)

### Bring your own Groq key

Paste your key once — Dictify stores it in the macOS Keychain and verifies it with a one-click **Test Connection**. The models in use are shown right in the API tab.

![API settings](screenshots/API.png)

### The rest

- **Personal dictionary** — teach Dictify your custom terms, names, and phonetic hints; they're injected into the Whisper prompt to bias recognition.
- **Direct text insertion** — uses macOS Accessibility APIs to type into any text field; falls back to paste if a field is read-only.
- **Dictation commands** — spoken punctuation ("period", "new paragraph", etc.).
- **Configurable activation** — choose `fn` or record any custom key/combo. Adjust the tap-vs-hold threshold to taste.
- **Sound effects & visual feedback** — optional start/stop tones and an elapsed-time readout on the floating indicator.
- **Optional Dock presence** — run as a menu-bar-only app or show in the Dock, your call.
- **Launch at login** — one toggle, handled via `SMAppService`.
- **Local-first storage** — dictionary, snippets, and history live on your Mac in `~/Library/Application Support/Dictify/`.
- **Keychain-encrypted API key** — your Groq API key never touches disk in plaintext.

## Requirements

- macOS 14 (Sonoma) or later
- A [Groq API key](https://console.groq.com/keys) — the free tier is enough for typical personal use
- **Microphone** and **Accessibility** permissions (Dictify walks you through granting both on first launch)

## Install

**Option 1 — Homebrew (recommended)**

```bash
brew tap aletisunil/tap
brew install --cask dictify
```

After tapping once, `brew install dictify` works too, and `brew upgrade --cask dictify` keeps it current.

**Option 2 — Download the signed DMG**

Grab the latest `Dictify.dmg` from the [Releases page](../../releases), drag the app to `/Applications`, and launch.

**Option 3 — Build from source**

Open `Dictify.xcodeproj` in Xcode and press ⌘R for the fastest feedback loop.

Or from the command line:

```bash
xcodebuild -project Dictify.xcodeproj -scheme Dictify -configuration Debug build
```

No code signing is needed for local development. The release pipeline (signing, notarization, DMG packaging) is automated in [`.github/workflows/release.yml`](.github/workflows/release.yml) and driven by the scripts in [`scripts/`](scripts/).

## Configuration

1. Launch Dictify — it walks you through granting Microphone + Accessibility permissions on first run.
2. Open the **API** tab, paste your Groq API key, and hit **Test Connection** to confirm. The key is stored in the macOS Keychain.
3. (Optional) Under **General**, pick your activation key, tap/hold threshold, and refinement speed.
4. (Optional) Under **Dictionary**, add custom terms, names, or acronyms Dictify should bias toward.
5. (Optional) Under **Snippets**, create spoken triggers that expand to longer text.
6. Close the window (the app keeps running) and hold `fn` to start talking.

## Privacy

Dictify sends recorded audio only to [Groq's API](https://groq.com/privacy-policy/) for transcription and refinement. There is no analytics, no telemetry, and no other network traffic. The app ships a privacy manifest declaring exactly what system APIs it touches and why.

Your Groq API key is stored encrypted in the macOS Keychain. Your dictionary, snippets, and transcription history are stored as plain JSON under `~/Library/Application Support/Dictify/` — local to your Mac.

## License

[MIT](LICENSE) © Sunil Aleti
