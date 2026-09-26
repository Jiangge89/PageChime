# PageChime — Interactive Sound Effects for Family Storytime

PageChime enhances parent-child reading by listening to a parent's narration and playing matching sound effects in real time. Read any physical children's book aloud — when the story mentions a frog, rain, a car, or a knock at the door, the app plays the corresponding sound.

## MVP Scope (Phase 1)

- Native iOS 17+ app built with Swift and SwiftUI
- Live speech recognition (English and Simplified Chinese)
- Deterministic local keyword-matching engine — no LLM, no network backend
- 33 bilingual trigger concepts across animals, weather, vehicles, actions, and environments
- 33 procedurally generated placeholder sound files
- Negation detection (e.g. "The frog did not croak" → no sound)
- Question detection with delayed playback (e.g. "What sound does a frog make?" → 1.5s delay)
- Cooldown-based duplicate suppression (default 15 seconds)
- Maximum 2 sound effects per sentence
- Privacy-first: all session data in memory only, cleared on stop

## Architecture

```
┌────────────────────────────────┐
│        ContentView (UI)        │
│   language · status · volume   │
└──────────────┬─────────────────┘
               │
┌──────────────▼─────────────────┐
│   ReadingSessionViewModel      │
│   coordinates all services     │
└──┬──────────┬──────────┬───────┘
   │          │          │
┌──▼──┐  ┌───▼───┐  ┌───▼────────┐
│Speech│  │Story  │  │SoundEffect │
│Recog.│  │Event  │  │Player      │
│Svc   │  │Engine │  │            │
└──────┘  └───┬───┘  └────────────┘
              │
         ┌────▼─────┐
         │ Trigger   │
         │ Library   │
         └───────────┘
```

| Component | Responsibility |
|-----------|---------------|
| `SpeechRecognizerService` | Microphone capture, live speech-to-text via Apple Speech framework |
| `StoryEventEngine` | Keyword matching, negation/question detection, cooldowns, trigger policies |
| `TriggerLibrary` | Bilingual keyword-to-sound mappings (English + Chinese) |
| `SoundEffectPlayer` | AVAudioPlayer-based playback, volume control, ambience looping |
| `ReadingSessionViewModel` | Coordinates services, owns transient UI state |
| `ContentView` | SwiftUI interface with calm children's-book visual style |

All services are injected via protocols (`SpeechRecognizing`, `SoundEffectPlaying`) for testability.

## Privacy Design

- **No backend server.** All processing happens on device.
- **No accounts or login.**
- **No data saved.** Microphone audio and transcripts exist only in memory during an active reading session and are cleared when the session stops or the app terminates.
- **No analytics, advertising, or tracking SDKs.**
- **On-device speech recognition preferred.** The app requests `requiresOnDeviceRecognition = true` when the device supports it.
- **Apple Speech framework note:** Depending on the device, language, and iOS version, Apple may process speech data through Apple servers. The app itself does not operate a server or retain any transcript. See [Apple's Speech privacy documentation](https://developer.apple.com/documentation/speech) for details.

## How to Open and Run

### Requirements

- macOS with Xcode 16+
- iOS 17+ deployment target
- Physical iPhone recommended for microphone and speech recognition testing

### Steps

1. Open `PageChime.xcodeproj` in Xcode.
2. Select your development team under **Signing & Capabilities**.
3. Select a simulator or connected iPhone as the run destination.
4. Press **⌘R** to build and run.

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

1. Place a WAV file in `PageChime/Resources/Sounds/` (e.g. `wolf_howl.wav`).
2. Regenerate the Xcode project (`xcodegen generate`) or manually add the file to the Xcode project's resources.
3. The `SoundEffectPlayer` looks up sounds by `soundID` → `{soundID}.wav` in the app bundle.
4. Document the source, author, and licence in `Resources/Sounds/ATTRIBUTION.md`.

## How to Add a New Trigger Phrase or Language

1. Open `PageChime/Services/TriggerLibrary.swift`.
2. Add a new `TriggerEntry` to the appropriate category array:

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
    ]
)
```

3. To add a new language, add a new case to `ReadingLanguage` and include its keyword arrays in each trigger entry's `keywords` dictionary. No changes to `StoryEventEngine` are needed.

## Known Limitations

- **Placeholder sounds.** All 33 sound files are procedurally generated sine waves and noise, not realistic recordings. Replace with production audio for release.
- **Keyword matching only.** The engine uses substring matching, not semantic understanding. Phrases like "frogman" would match "frog". Phase 2 can add a local semantic model.
- **No background listening.** The app works in the foreground only. Screen sleep is disabled during active sessions.
- **Apple Speech recognition limits.** Recognition tasks may time out after ~60 seconds; the app auto-restarts them. Network-based recognition may be used when on-device is unavailable.
- **No compound negation.** "It's not that the frog didn't croak" (double negation) would be incorrectly suppressed.
- **Single-character Chinese matches.** Short keywords like "马" (horse) or "牛" (cow) could match as substrings of longer words. Context-aware matching is a Phase 2 improvement.

## Background Microphone Limitations

iOS restricts background microphone access to specific app categories (VoIP, navigation, music). PageChime does not qualify for these entitlements without misrepresenting its purpose. Future versions could explore:

- `UIBackgroundModes: audio` for continued playback (not recording)
- Picture-in-Picture or Live Activities as visual anchors
- A companion Apple Watch app for background listening

For now, keep the app in the foreground during reading sessions.

## Future Ideas (Not Implemented)

These are Phase 2+ concepts. None are built.

- **Local semantic model** — Replace or supplement keyword matching with a Core ML or Whisper-based model for context-aware detection.
- **Cloud LLM** — Optional thin backend for richer story understanding.
- **Remote sound packs** — Downloadable themed sound libraries.
- **Camera-based page understanding** — Detect book pages and preload relevant sounds.
- **AR animation** — Visual effects overlaid on the book via the camera.
- **Parent voice cloning** — Character voices generated from the parent's voice.
- **Subscription and VIP features** — Premium sounds, languages, or models.
