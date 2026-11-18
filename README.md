# PageChime — Interactive Sound Effects for Family Storytime

PageChime enhances parent-child reading by listening to a parent's narration and playing matching sound effects in real time. Read any physical children's book aloud — when the story mentions a frog, rain, a car, or a knock at the door, the app plays the corresponding sound.

## Current Scope

- Native iOS 17+ app built with Swift and SwiftUI
- Live speech recognition (English and Simplified Chinese)
- Two-speed analysis: an **instant local keyword path** on every partial transcript, plus a **scene-aware LLM** (with a learned phrase cache) for sounds keywords miss and for the scene's ambience
- 58 bilingual sound effects across animals, weather, vehicles, machines, actions, and environments
- Layered ambience: up to 3 looping beds (e.g. storm + rain) that crossfade with the scene, hold while it lasts, and duck under the reader's voice
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
┌──▼───┐ ┌──▼───┐ ┌──▼───┐ ┌──▼─────────┐
│Speech│ │Sound │ │ LLM  │ │SoundEffect │
│Recog.│ │Cache │ │ Svc  │ │Player      │
│ Svc  │ └──────┘ └──────┘ └────────────┘
└──────┘
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
| `LLMService` | Calls OpenAI Chat Completions (`gpt-4o-mini`) with recent story context; returns one-shot sounds with trigger phrases, plus the ambience set for the current scene |
| `StoryEventEngine` | Offline keyword matching with exclude patterns, word-start matching, proximity negation, and cooldowns |
| `TriggerLibrary` | Bilingual keyword-to-sound mappings (English + Chinese); also supplies Speech contextual strings |
| `SoundEffectPlayer` | AVAudioEngine mixer: pooled one-shot voices with random pitch/level, up to 3 crossfading ambience beds, ducking under speech; sounds are pre-decoded into memory |
| `ReadingSessionViewModel` | Runs the instant keyword path, dispatches cache/LLM segments, applies scenes, owns transient UI state and the debug log |
| `ContentView` | SwiftUI interface with calm children's-book visual style |

Speech and playback are injected via protocols (`SpeechRecognizing`, `SoundEffectPlaying`) for testability.

## How Analysis Works

1. **Instant keyword path** (`StoryEventEngine`): every partial transcript is scanned locally, so obvious sounds ("frog", "thunder", "knock") play with no network wait.
2. **Segments**: unanalyzed text is handed on after a 0.6s pause, or as soon as 10 (Chinese) / 30 (English) new characters arrive.
3. **Cache** (`SoundCache`): each segment is normalized and checked against trigger phrases learned from earlier LLM results; hits play instantly.
4. **Scene LLM** (`LLMService`): every segment is also sent to `gpt-4o-mini` with the previous ~300 characters as context. It returns one-shot sounds for the new text and the ambience beds for the current scene (or `null` to keep the scene). Requests run concurrently and are never cancelled by newer speech.
5. **Merging**: LLM one-shots already played by the keyword path for that text are skipped; one-shots arriving more than 4s late are dropped; ambience is always applied, since it follows the scene rather than a single word.

## Privacy Design

- **No app backend or accounts.** There is no PageChime server and no login.
- **Transcript text is sent to OpenAI.** When an API key is configured, newly recognized text snippets are sent to the OpenAI API for sound matching. Audio is never sent to OpenAI. Without a key, the app falls back to fully local keyword matching.
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
- Optional: an OpenAI API key (without one, only keyword matching is used)

### Steps

1. Generate the Xcode project: `xcodegen generate` (the project is defined in `project.yml`).
2. Create `PageChime/Config/Secrets.swift` (git-ignored):

   ```swift
   enum Secrets {
       static let openAIKey = ""   // your OpenAI key; leave empty for keyword matching only
   }
   ```

3. Open `PageChime.xcodeproj` in Xcode and select your development team under **Signing & Capabilities**.
4. Select a simulator or connected iPhone as the run destination.
5. Press **⌘R** to build and run. Press **⌘U** to run the unit tests.

> **Security note:** the key in `Secrets.swift` is compiled into the app binary and can be extracted from a distributed build. That's acceptable for local development; a production release should route requests through a backend proxy instead.

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

## How to Add a New Sound

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

3. Add the sound ID and a short description to `soundCatalog` in `PageChime/Services/LLMService.swift` so the LLM can return it.
4. Document the source and licence in `Resources/Sounds/ATTRIBUTION.md`.

Steps 2 and 3 are both required: LLM results are only played if the sound ID also exists in `TriggerLibrary`, and the keyword fallback only knows sounds in `TriggerLibrary`. (`cooldownSeconds` on `TriggerEntry` is currently unused; a unified 3s cooldown applies.)

## How to Add a New Language

Add a case to `ReadingLanguage`, keyword arrays for it in each trigger entry's `keywords` dictionary, negation words in `StoryEventEngine.isNegated`, a debounce threshold in `ReadingSessionViewModel`, and UI strings in `ContentView`.

## Known Limitations

- **Network latency for non-keyword sounds.** Sounds only the LLM recognizes wait on an OpenAI round-trip; one-shots later than 4s are dropped. The debug panel shows actual latency.
- **Cache matching is substring-based.** A learned phrase matches whenever it appears inside new text, regardless of context.
- **Keyword matching is prefix-based.** English keywords must start a word, but "frogman" still matches "frog". Exclude patterns cover some Chinese cases (e.g. 牛奶 is not a cow).
- **Short, single-variant sounds.** Each sound has one file and ambience loops are ~6s, so loops are audible on long scenes. Random pitch/level helps one-shots but doesn't replace real variants.
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

- **Backend proxy for the LLM** — Keep API keys off device and allow model changes without an app update.
- **Local semantic model** — A Core ML or on-device model to replace the network LLM for lower latency and full offline use.
- **Remote sound packs** — Downloadable themed sound libraries.
- **Camera-based page understanding** — Detect book pages and preload relevant sounds.
- **AR animation** — Visual effects overlaid on the book via the camera.
- **Parent voice cloning** — Character voices generated from the parent's voice.
- **Subscription and VIP features** — Premium sounds, languages, or models.
