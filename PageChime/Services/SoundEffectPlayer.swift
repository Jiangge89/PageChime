import AVFoundation
import Foundation

/// AVAudioEngine-based mixer with two buses:
/// - one-shots: a pool of voices with slight random pitch and level, so
///   repeated sounds don't sound identical and can overlap;
/// - ambience: up to three looping beds that fade in and out, hold while the
///   scene lasts, and duck under the reader's voice.
final class SoundEffectPlayer: SoundEffectPlaying {
    private let engine = AVAudioEngine()
    private let effectsMixer = AVAudioMixerNode()
    private let ambienceMixer = AVAudioMixerNode()
    private let buffers: AudioBufferCache
    private var voices: [Voice] = []
    private var beds: [Bed] = []
    private var fadeTimer: Timer?
    private var configObserver: NSObjectProtocol?

    private var volume: Float = 0.4
    private var duckLevel: Float = 1
    private var lastSpeechActivity = Date.distantPast

    private let ambienceSounds: Set<String> = Set(
        TriggerLibrary.defaultTriggers.filter(\.isAmbience).map(\.soundID)
    )

    private static let voiceCount = 8
    static let maxBeds = 3
    /// How long a bed keeps playing after it was last requested.
    private let ambienceHold: TimeInterval = 45
    private let fadeInDuration: TimeInterval = 1.5
    private let fadeOutDuration: TimeInterval = 2.5
    private let duckedLevel: Float = 0.5
    /// Ducking releases this long after the last speech activity.
    private let duckRelease: TimeInterval = 1.2
    private let tick: TimeInterval = 1.0 / 30

    private final class Voice {
        let node = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        var generation = 0
        var isBusy = false
        var startedAt = Date.distantPast
    }

    private final class Bed {
        let node = AVAudioPlayerNode()
        var soundID: String?
        var gain: Float = 0.6
        /// Current and target fade level, 0...1.
        var level: Float = 0
        var target: Float = 0
        var holdUntil = Date.distantPast
    }

    init(buffers: AudioBufferCache = AudioBufferCache()) {
        self.buffers = buffers
        let format = buffers.format

        engine.attach(effectsMixer)
        engine.attach(ambienceMixer)
        engine.connect(effectsMixer, to: engine.mainMixerNode, format: nil)
        engine.connect(ambienceMixer, to: engine.mainMixerNode, format: nil)

        for _ in 0..<Self.voiceCount {
            let voice = Voice()
            engine.attach(voice.node)
            engine.attach(voice.varispeed)
            engine.connect(voice.node, to: voice.varispeed, format: format)
            engine.connect(voice.varispeed, to: effectsMixer, format: format)
            voices.append(voice)
        }
        for _ in 0..<Self.maxBeds {
            let bed = Bed()
            engine.attach(bed.node)
            engine.connect(bed.node, to: ambienceMixer, format: format)
            beds.append(bed)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        fadeTimer?.invalidate()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    /// Ambience beds currently playing or fading in (for tests and debugging).
    var activeAmbienceIDs: Set<String> {
        Set(beds.compactMap { $0.target > 0 ? $0.soundID : nil })
    }

    // MARK: - SoundEffectPlaying

    func play(event: StoryEvent) {
        if ambienceSounds.contains(event.soundID) {
            addBed(event)
        } else {
            playOneShot(event)
        }
    }

    func setAmbience(_ events: [StoryEvent]) {
        let wanted = Set(events.map(\.soundID))
        for bed in beds {
            if let soundID = bed.soundID, !wanted.contains(soundID) {
                bed.target = 0
            }
        }
        for event in events.prefix(Self.maxBeds) {
            addBed(event)
        }
        startFadeTimerIfNeeded()
    }

    func noteSpeechActivity() {
        lastSpeechActivity = Date()
    }

    func stopAll() {
        stopFadeTimer()
        for voice in voices {
            voice.generation += 1
            voice.isBusy = false
            voice.node.stop()
        }
        for bed in beds {
            bed.node.stop()
            bed.soundID = nil
            bed.level = 0
            bed.target = 0
        }
        duckLevel = 1
        ambienceMixer.outputVolume = 1
        engine.stop()
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        for bed in beds where bed.soundID != nil {
            bed.node.volume = bed.level * bed.gain * volume
        }
    }

    // MARK: - One-shots

    private func playOneShot(_ event: StoryEvent) {
        guard let buffer = buffers.buffer(for: event.soundID), ensureRunning() else { return }

        let voice = voices.first { !$0.isBusy } ?? voices.min { $0.startedAt < $1.startedAt }!
        voice.generation += 1
        let generation = voice.generation
        voice.node.stop()
        voice.isBusy = true
        voice.startedAt = Date()

        // Small random variation so repeats don't sound copy-pasted.
        voice.varispeed.rate = Float.random(in: 0.93...1.07)
        voice.node.volume = min(1, volume * multiplier(event.intensity) * Float.random(in: 0.85...1.0))

        voice.node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak voice] _ in
            DispatchQueue.main.async {
                guard let voice, voice.generation == generation else { return }
                voice.isBusy = false
            }
        }
        voice.node.play()
    }

    // MARK: - Ambience

    private func addBed(_ event: StoryEvent) {
        let holdUntil = Date().addingTimeInterval(ambienceHold)

        if let bed = beds.first(where: { $0.soundID == event.soundID }) {
            bed.holdUntil = holdUntil
            bed.target = 1
            startFadeTimerIfNeeded()
            return
        }

        guard let buffer = buffers.buffer(for: event.soundID), ensureRunning() else { return }

        let bed = beds.first { $0.soundID == nil }
            ?? beds.filter { $0.target == 0 }.min { $0.level < $1.level }
            ?? beds.min { $0.holdUntil < $1.holdUntil }!

        bed.node.stop()
        bed.soundID = event.soundID
        bed.gain = multiplier(event.intensity)
        bed.level = 0
        bed.target = 1
        bed.holdUntil = holdUntil
        bed.node.volume = 0
        bed.node.scheduleBuffer(buffer, at: nil, options: .loops)
        bed.node.play()
        startFadeTimerIfNeeded()
    }

    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            self?.updateFades()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func updateFades() {
        let now = Date()

        let isSpeaking = now.timeIntervalSince(lastSpeechActivity) < duckRelease
        let duckTarget: Float = isSpeaking ? duckedLevel : 1
        let duckDuration: TimeInterval = duckTarget < duckLevel ? 0.4 : 1.0
        duckLevel = approach(duckLevel, duckTarget, step: Float(tick / duckDuration) * (1 - duckedLevel))
        ambienceMixer.outputVolume = duckLevel

        var hasActiveBed = false
        for bed in beds where bed.soundID != nil {
            if now > bed.holdUntil { bed.target = 0 }
            let duration = bed.target > bed.level ? fadeInDuration : fadeOutDuration
            bed.level = approach(bed.level, bed.target, step: Float(tick / duration))
            bed.node.volume = bed.level * bed.gain * volume

            if bed.level == 0, bed.target == 0 {
                bed.node.stop()
                bed.soundID = nil
            } else {
                hasActiveBed = true
            }
        }

        if !hasActiveBed {
            stopFadeTimer()
        }
    }

    private func approach(_ value: Float, _ target: Float, step: Float) -> Float {
        value < target ? min(target, value + step) : max(target, value - step)
    }

    // MARK: - Engine

    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// The engine stops when the audio route or session changes (for example
    /// when speech recognition restarts). Restart it and resume the beds.
    private func handleConfigurationChange() {
        for voice in voices {
            voice.generation += 1
            voice.isBusy = false
        }
        let activeBeds = beds.filter { $0.soundID != nil }
        guard !activeBeds.isEmpty, ensureRunning() else { return }
        for bed in activeBeds {
            guard let soundID = bed.soundID, let buffer = buffers.buffer(for: soundID) else { continue }
            bed.node.stop()
            bed.node.scheduleBuffer(buffer, at: nil, options: .loops)
            bed.node.play()
        }
    }

    private func multiplier(_ intensity: EffectIntensity) -> Float {
        switch intensity {
        case .soft: return 0.6
        case .normal: return 1.0
        case .strong: return 1.3
        }
    }
}

/// Decoded, format-normalized PCM buffers for bundled sounds, kept in memory
/// so playback never touches the disk.
final class AudioBufferCache {
    let format: AVAudioFormat
    private var storage: [String: AVAudioPCMBuffer] = [:]
    private let lock = NSLock()

    init(
        format: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!,
        preload: Bool = true
    ) {
        self.format = format
        guard preload else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.preloadAll()
        }
    }

    func buffer(for soundID: String) -> AVAudioPCMBuffer? {
        if let cached = lock.withLock({ storage[soundID] }) {
            return cached
        }
        guard let url = Self.url(for: soundID), let buffer = load(url) else { return nil }
        lock.withLock { storage[soundID] = buffer }
        return buffer
    }

    private func preloadAll() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "Sounds") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
        for url in urls {
            let soundID = url.deletingPathExtension().lastPathComponent
            guard lock.withLock({ storage[soundID] }) == nil, let buffer = load(url) else { continue }
            lock.withLock { storage[soundID] = buffer }
        }
    }

    private func load(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
              ),
              (try? file.read(into: source)) != nil
        else { return nil }

        if file.processingFormat == format { return source }
        return convert(source)
    }

    private func convert(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }
        return status == .error ? nil : output
    }

    private static func url(for soundID: String) -> URL? {
        Bundle.main.url(forResource: soundID, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: soundID, withExtension: "wav")
    }
}
