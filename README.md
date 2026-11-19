# PageChime — Interactive Sound Effects for Family Storytime

PageChime enhances parent-child reading by listening to a parent's narration and playing matching sound effects in real time. Read any physical children's book aloud — when the story mentions a frog, rain, a car, or a knock at the door, the app plays the corresponding sound.

## Current Scope

- Native iOS 17+ app built with Swift and SwiftUI
- Live speech recognition (English and Simplified Chinese)
- Two-speed analysis: an **instant local keyword path** on every partial transcript, plus a **scene-aware LLM** (with a learned phrase cache) for sounds keywords miss and for the scene's ambience
- A small Cloudflare Worker backend (`backend/`) holds the OpenAI key and only serves genuine copies of the app (App Attest)
- 58 bundled bilingual sound effects across animals, weather, vehicles, machines, actions, and environments, plus a **cloud sound library** (R2) whose sounds the LLM can choose; they are downloaded on demand into a 200 MB on-device cache
- Cloud sounds are 44.1 kHz stereo with several variants each (never the same variant twice in a row); cloud ambience streams from disk and loops with an equal-power crossfade
- Layered ambience: up to 3 looping beds (e.g. storm + rain) that fade with the scene, hold while it lasts, and duck under the reader's voice
- One-shot variation: slight random pitch and level on every play, and overlapping playback
- Proximity-based negation detection in the keyword path (e.g. "There was no frog" / "没有青蛙" → no sound); English keywords must start a word ("then" ≠ "hen")
- Unified 3-second per-sound cooldown to suppress repeats
- Bilingual UI that follows the selected reading language
- In-app debug panel showing each analysis: input text, method (Cache / LLM / Keyword / No Match), wait and analysis latency, and matched sounds

## Architecture

```
┌────────────────────────────────┐
│        ContentView (UI)        │
│  language · status · volume ·  │
│  recent effects · debug log    │
└──────────────┬─────────────────┘
               │
┌──────────────▼─────────────────┐
│    ReadingSessionViewModel     │
│  instant keywords · cache +    │
│  scene LLM · cooldowns         │
└──┬────────┬────────┬────────┬──┘
   │        │        │        │
┌──▼───┐ ┌──▼───┐ ┌──▼─────┐ ┌▼───────────┐
│Speech│ │Sound │ │Backend │ │SoundEffect │
│Recog.│ │Cache │ │Sound   │ │Player      │
│ Svc  │ └──────┘ │Matcher │ └────────────┘
└──────┘          └──┬─────┘
                     │ HTTPS + App Attest session
          ┌──────────▼───────────┐     ┌────────┐
          │ PageChime API        │────►│ OpenAI │
          │ (Cloudflare Worker)  │     └────────┘
          └──────────────────────┘
          ┌──────────────┐   ┌──────────────┐
          │ StoryEvent   │──►│TriggerLibrary│
          │ Engine       │   └──────────────┘
          │ (instant)    │
          └──────────────┘
```

| Component | Responsibility |
|-----------|---------------|
| `SpeechRecognizerService` | Microphone capture, live speech-to-text via Apple Speech framework, auto-restart on timeouts and interruptions |
| `SoundCache` | Persistent phrase → sound cache learned from LLM results; per-language buckets, up to 5,000 entries each, LRU eviction |
| `BackendSoundMatcher` | Sends new text plus recent story context to the PageChime API; returns one-shot sounds with trigger phrases, plus the ambience set for the current scene |
| `AppAttestSessionProvider` | Proves the app is genuine with App Attest and caches the hour-long session token (Debug builds on the simulator use a local dev session instead) |
| `backend/` (Cloudflare Worker) | Owns the prompt and sound catalog (bundled sounds + the cloud library), calls OpenAI (`gpt-4o-mini`) with the server-side key, serves the library from R2, verifies App Attest, rate-limits each device |
| `StoryEventEngine` | Offline keyword matching with exclude patterns, word-start matching, proximity negation, and cooldowns |
| `TriggerLibrary` | Bilingual keyword-to-sound mappings (English + Chinese); also supplies Speech contextual strings |
| `SoundEffectPlayer` | AVAudioEngine mixer: pooled one-shot voices with random pitch/level, up to 3 ambience beds, ducking under speech. Bundled sounds are pre-decoded; cloud one-shots are decoded on first use, cloud ambience streams from its file with a crossfaded loop. Missing cloud sounds are downloaded: one-shots play only if that takes under 1.5s, ambience starts if the scene still wants it |
| `SoundLibrary` | Cloud library client: fetches `/v1/library` (ETag-cached, stored for offline use), downloads `/v1/sounds/<file>` into a 200 MB LRU cache, picks variants, and describes cloud sounds to the view model and player |
| `ReadingSessionViewModel` | Runs the instant keyword path, dispatches cache/LLM segments, applies scenes, owns transient UI state and the debug log |
| `ContentView` | SwiftUI interface with calm children's-book visual style |

Speech, playback and analysis are injected via protocols (`SpeechRecognizing`, `SoundEffectPlaying`, `SoundMatching`) for testability.

## How Analysis Works

1. **Instant keyword path** (`StoryEventEngine`): every partial transcript is scanned locally, so obvious sounds ("frog", "thunder", "knock") play with no network wait.
2. **Segments**: unanalyzed text is handed on after a 0.6s pause, or as soon as 10 (Chinese) / 30 (English) new characters arrive.
3. **Cache** (`SoundCache`): each segment is normalized and checked against trigger phrases learned from earlier LLM results; hits play instantly.
4. **Scene LLM** (`BackendSoundMatcher` → PageChime API): every segment is also sent, via the backend, to `gpt-4o-mini` with the previous ~300 characters as context. It returns one-shot sounds for the new text and the ambience beds for the current scene (or `null` to keep the scene). Requests run concurrently and are never cancelled by newer speech.
5. **Merging**: LLM one-shots already played by the keyword path for that text are skipped; one-shots arriving more than 4s late are dropped; ambience is always applied, since it follows the scene rather than a single word.

## Privacy Design

- **No accounts.** There is no login. The PageChime API identifies a device only by an anonymous App Attest key.
- **Transcript text goes through the PageChime API to OpenAI.** Newly recognized text snippets (plus ~300 characters of preceding story) are sent to the PageChime API on Cloudflare, which forwards them to OpenAI for sound matching and returns the result. The API does not store or log the text. Audio is never sent. Without a configured backend URL, the app uses fully local keyword matching.
- **The API stores only App Attest keys:** each device's attested public key and signature counter, in Cloudflare KV.
- **Cloud sounds are cached on device** in `Library/Caches/SoundLibrary` (up to 200 MB; iOS may purge it), with the library manifest in `Application Support/SoundLibrary`.
- **Learned phrases are stored on device.** `SoundCache` persists short trigger phrases (e.g. "the dog barked") and their sound IDs to `Documents/sound_cache.json`. Full transcripts are not saved.
- **Live transcript and debug logs are in memory only** and are cleared when the session stops or the app terminates.
- **No analytics, advertising, or tracking SDKs.**
- **On-device speech recognition preferred.** The app requests `requiresOnDeviceRecognition = true` when the device supports it.
- **Apple Speech framework note:** Depending on the device, language, and iOS version, Apple may process speech data through Apple servers. See [Apple's Speech privacy documentation](https://developer.apple.com/documentation/speech) for details.

## How to Open and Run

### Requirements

- macOS with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- iOS 17+ deployment target
- Physical iPhone recommended for microphone and speech recognition testing
- Node.js 20+ for the backend
- Optional: an OpenAI API key (without the backend, only keyword matching is used)

### Steps

1. Start the backend locally:

   ```bash
   cd backend
   npm install
   cp .dev.vars.example .dev.vars   # then put your OpenAI key in it
   npm run dev                      # serves http://localhost:8787
   ```

2. Generate the Xcode project: `xcodegen generate` (the project is defined in `project.yml`).
3. Open `PageChime.xcodeproj` in Xcode and select your development team under **Signing & Capabilities**.
4. Select a simulator or connected iPhone as the run destination.
5. Press **⌘R** to build and run. Press **⌘U** to run the unit tests; `npm test` in `backend/` runs the backend tests.

Debug builds talk to `http://localhost:8787` (`PAGECHIME_BACKEND_URL` in `project.yml`). That works from the simulator, which can't use App Attest and so gets a dev session (`ALLOW_DEV_SESSIONS=true` in `.dev.vars`). On a physical iPhone, `localhost` is the phone itself: run `npx wrangler dev --ip 0.0.0.0` and set `PAGECHIME_BACKEND_URL` to `http://<your Mac's LAN IP>:8787`, or use the deployed URL. A device always goes through App Attest, even in Debug.

> **Security note:** the OpenAI key lives only on the backend (`.dev.vars` locally, a Worker secret in production). An older `PageChime/Config/Secrets.swift` is no longer compiled in and can be deleted.

### Deploying the Backend

```bash
cd backend
npx wrangler login
npx wrangler kv namespace create DEVICE_KEYS   # copy the id into wrangler.toml
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put TOKEN_SECRET           # any long random string
npm run deploy
```

Create the sound bucket once with `npx wrangler r2 bucket create pagechime-sounds`. Then set `PAGECHIME_BACKEND_URL` for Release in `project.yml` to the deployed `https://pagechime-api.<subdomain>.workers.dev` URL. Keep `ALLOW_DEV_SESSIONS = "false"` in production. Consider a monthly spending limit on the OpenAI project as a backstop.

### Running on a Physical iPhone

1. Connect your iPhone via USB or Wi-Fi.
2. In Xcode, select your device as the run destination.
3. If prompted, trust the developer profile on the device: **Settings → General → VPN & Device Management**.
4. Grant microphone and speech recognition permissions when prompted.

### Simulator Limitations

- The iOS Simulator does not have a real microphone — speech recognition will not produce results.
- Sound playback works in the simulator.
- Use a physical device to test the full reading flow.

## Required iOS Permissions

| Permission | Key | Purpose |
|-----------|-----|---------|
| Microphone | `NSMicrophoneUsageDescription` | Capture the parent's narration |
| Speech Recognition | `NSSpeechRecognitionUsageDescription` | Convert speech to text for event detection |

## Cloud Sound Library

Cloud sounds need no app update. Put source audio (any format ffmpeg reads) in a folder with a `sounds.json`:

```json
[
  {
    "id": "wolf_howl",
    "kind": "oneShot",
    "name": "wolf",
    "category": "animal",
    "description": "a lone wolf howling at night",
    "files": ["wolf_howl_1.wav", "wolf_howl_2.wav", "wolf_howl_3.wav"]
  }
]
```

`kind` is `oneShot` or `ambience`; `category` is one of animal, weather, vehicle, action, environment, object (it picks the icon); `description` is what the LLM sees; each file is one variant. Then build and upload (requires ffmpeg):

```bash
cd backend
node scripts/build-library.mjs path/to/sounds --upload local    # for `npm run dev`
node scripts/build-library.mjs path/to/sounds --upload remote   # for production
```

The script converts each file to 44.1 kHz stereo AAC, normalizes loudness (one-shots −18 LUFS, ambience −26 LUFS so beds sit under the voice), trims leading silence from one-shots, names files by content hash, and uploads the manifest last. Ambience works best at 30s or longer: the player crossfades the end of the file into its start. The source folder is the source of truth: each build replaces the manifest. Only use audio licensed for commercial redistribution, and record its source.

A cloud sound may reuse a bundled ID (e.g. `thunder`) to add variants: the bundled version plays at once and a cloud variant is downloaded for next time.

## How to Add a Bundled Sound

1. Place a WAV file in `PageChime/Resources/Sounds/` (e.g. `wolf_howl.wav`) and regenerate the project (`xcodegen generate`).
2. Add a `TriggerEntry` in `PageChime/Services/TriggerLibrary.swift`:

```swift
TriggerEntry(
    entity: "wolf",
    soundID: "wolf_howl",
    eventType: .animal,
    intensity: .normal,
    cooldownSeconds: 15,
    isAmbience: false,
    keywords: [
        "en": ["wolf", "wolves"],
        "zh": ["狼"]
    ],
    excludePatterns: ["zh": ["狼狈"]]   // optional
)
```

3. Add the sound ID and a short description to `CATALOG` in `backend/src/catalog.ts` (mark ambience with `ambience: true`) and redeploy the backend, so the LLM can return it.
4. Document the source and licence in `Resources/Sounds/ATTRIBUTION.md`.

Steps 2 and 3 are both required for a bundled sound: LLM results are only played if the app knows the ID, from `TriggerLibrary` or the cloud library (so older app versions safely ignore IDs they don't know), and the keyword fallback only knows sounds in `TriggerLibrary`. (`cooldownSeconds` on `TriggerEntry` is currently unused; a unified 3s cooldown applies.)

## How to Add a New Language

Add a case to `ReadingLanguage`, keyword arrays for it in each trigger entry's `keywords` dictionary, negation words in `StoryEventEngine.isNegated`, a debounce threshold in `ReadingSessionViewModel`, and UI strings in `ContentView`.

## Known Limitations

- **Network latency for non-keyword sounds.** Sounds only the LLM recognizes wait on a backend + OpenAI round-trip (about 1–2s); one-shots later than 4s are dropped. The debug panel shows actual latency.
- **App Attest on devices is untested so far.** The server-side verification is unit-tested against a synthetic certificate chain and the real Apple root parses, but no real device attestation has been verified yet.
- **Cache matching is substring-based.** A learned phrase matches whenever it appears inside new text, regardless of context.
- **Keyword matching is prefix-based.** English keywords must start a word, but "frogman" still matches "frog". Exclude patterns cover some Chinese cases (e.g. 牛奶 is not a cow).
- **Bundled sounds are short and single-variant.** The 58 bundled files are mono 22 kHz with ~6s ambience loops, and their source and licence are unverified, so they stay bundled and are not uploaded to the cloud library. Cloud sounds fix this, but the library is empty until sounds are added.
- **The LLM prompt lists every sound.** Fine for hundreds of sounds; a much larger library needs description-based retrieval.
- **First use of a cloud sound waits for a download.** One-shots that take more than 1.5s to download are skipped (they're cached for next time).
- **Keyword negation only looks before the keyword.** The keyword engine checks ~15 characters (English) or 5 characters (Chinese) before a keyword. "There was no frog" is suppressed, but "The frog did not croak" still triggers. This is deliberate: Chinese recognition produces no punctuation, so sentence-level negation would suppress every keyword in the transcript.
- **No question handling.** Questions like "What sound does a frog make?" trigger immediately, without delay.
- **No background listening.** The app works in the foreground only. Screen sleep is disabled during active sessions.
- **Apple Speech recognition limits.** Recognition tasks may time out after ~60 seconds; the app auto-restarts them. Network-based recognition may be used when on-device is unavailable.

## Background Microphone Limitations

iOS restricts background microphone access to specific app categories (VoIP, navigation, music). PageChime does not qualify for these entitlements without misrepresenting its purpose. Future versions could explore:

- `UIBackgroundModes: audio` for continued playback (not recording)
- Picture-in-Picture or Live Activities as visual anchors
- A companion Apple Watch app for background listening

For now, keep the app in the foreground during reading sessions.

## Future Ideas (Not Implemented)

- **Local semantic model** — A Core ML or on-device model to replace the network LLM for lower latency and full offline use.
- **Camera-based page understanding** — Detect book pages and preload relevant sounds.
- **AR animation** — Visual effects overlaid on the book via the camera.
- **Parent voice cloning** — Character voices generated from the parent's voice.
- **Subscription and VIP features** — Premium sounds, languages, or models.
