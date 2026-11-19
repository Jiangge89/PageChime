import AVFoundation
import Foundation

/// AVAudioEngine-based mixer with two buses:
/// - one-shots: pools of voices with slight random pitch and level, so
///   repeated sounds don't sound identical and can overlap;
/// - ambience: up to three looping beds that fade in and out, hold while the
///   scene lasts, and duck under the reader's voice.
///
/// Sounds come from two places. Bundled sounds are pre-decoded in memory.
/// Cloud library sounds (stereo, 44.1 kHz, several variants each) are played
/// from the disk cache, and downloaded first if needed. Cloud ambience is
/// streamed from its file and looped with a crossfade, so long beds don't
/// need to fit in memory and loop points don't click.
final class SoundEffectPlayer: SoundEffectPlaying {
    private let engine = AVAudioEngine()
    private let effectsMixer = AVAudioMixerNode()
    private let ambienceMixer = AVAudioMixerNode()
    private let buffers: AudioBufferCache
    private let catalog: SoundCatalogProviding
    private let cloud: CloudSoundSource?
    private var bundledVoices: [Voice] = []
    private var cloudVoices: [Voice] = []
    private var beds: [Bed] = []
    private var fadeTimer: Timer?
    private var configObserver: NSObjectProtocol?

    private var volume: Float = 0.4
    private var duckLevel: Float = 1
    private var lastSpeechActivity = Date.distantPast
    /// Bumped by stopAll, so downloads finishing afterwards are ignored.
    private var playbackGeneration = 0
    /// Ambience requested but still downloading, with when the request expires.
    private var pendingAmbience: [String: (event: StoryEvent, holdUntil: Date)] = [:]
    private var cloudBuffers = CloudBufferCache(limit: 24)

    /// Format of cloud library files (see backend/scripts/build-library.mjs).
    static let cloudFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private static let bundledVoiceCount = 8
    private static let cloudVoiceCount = 6
    static let maxBeds = 3
    /// Background sounds play until the scene changes. They fade out only
    /// once nobody has read for this long (the book was put down), counted
    /// from the last speech or the last time the bed was asked for.
    var quietTimeout: TimeInterval = 120
    /// A background sound still downloading is dropped after this long.
    private let pendingTimeout: TimeInterval = 30
    private let fadeInDuration: TimeInterval = 1.5
    private let fadeOutDuration: TimeInterval = 2.5
    private let duckedLevel: Float = 0.5
    /// Ducking releases this long after the last speech activity.
    private let duckRelease: TimeInterval = 1.2
    /// A one-shot that took longer than this to download is skipped.
    private let oneShotDownloadDeadline: TimeInterval = 1.5
    private let maxLoopCrossfade: TimeInterval = 3
    private let tick: TimeInterval = 1.0 / 30

    private final class Voice {
        let node = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        var generation = 0
        var isBusy = false
        var startedAt = Date.distantPast
    }

    private final class Bed {
        /// Plays bundled (in-memory) loops.
        let bufferNode = AVAudioPlayerNode()
        /// Two nodes alternate to crossfade a streamed file into itself.
        let fileNodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
        var fileFormat: AVAudioFormat?

        var soundID: String?
        var source: Source = .none
        var gain: Float = 0.6
        /// Current and target fade level, 0...1.
        var level: Float = 0
        var target: Float = 0
        /// When the scene last asked for this bed.
        var lastRequested = Date.distantPast

        // Streamed-loop state.
        var activeFileNode = 0
        var segmentStartedAt = Date.distantPast
        var crossfadeStartedAt: Date?

        enum Source {
            case none
            case buffer
            case file(AVAudioFile, duration: TimeInterval)
        }

        var isFile: Bool {
            if case .file = source { return true }
            return false
        }
    }

    init(
        buffers: AudioBufferCache = AudioBufferCache(),
        catalog: SoundCatalogProviding = SoundLibrary.shared,
        cloud: CloudSoundSource? = SoundLibrary.shared
    ) {
        self.buffers = buffers
        self.catalog = catalog
        self.cloud = cloud

        engine.attach(effectsMixer)
        engine.attach(ambienceMixer)
        engine.connect(effectsMixer, to: engine.mainMixerNode, format: nil)
        engine.connect(ambienceMixer, to: engine.mainMixerNode, format: nil)

        bundledVoices = (0..<Self.bundledVoiceCount).map { _ in makeVoice(format: buffers.format) }
        cloudVoices = (0..<Self.cloudVoiceCount).map { _ in makeVoice(format: Self.cloudFormat) }

        for _ in 0..<Self.maxBeds {
            let bed = Bed()
            engine.attach(bed.bufferNode)
            engine.connect(bed.bufferNode, to: ambienceMixer, format: buffers.format)
            for node in bed.fileNodes {
                engine.attach(node)
                engine.connect(node, to: ambienceMixer, format: Self.cloudFormat)
            }
            bed.fileFormat = Self.cloudFormat
            beds.append(bed)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func makeVoice(format: AVAudioFormat) -> Voice {
        let voice = Voice()
        engine.attach(voice.node)
        engine.attach(voice.varispeed)
        engine.connect(voice.node, to: voice.varispeed, format: format)
        engine.connect(voice.varispeed, to: effectsMixer, format: format)
        return voice
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

    /// Recently started one-shots, newest last (for tests and debugging).
    private(set) var recentOneShots: [String] = []
    /// Times a streamed bed has crossfaded into its own start (for tests).
    private(set) var completedLoops = 0

    /// Ambience beds streaming from a cloud file (for tests and debugging).
    var streamedAmbienceIDs: Set<String> {
        Set(beds.compactMap { $0.target > 0 && $0.isFile ? $0.soundID : nil })
    }

    // MARK: - SoundEffectPlaying

    func play(event: StoryEvent) {
        if catalog.info(for: event.soundID)?.isAmbience == true {
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
        pendingAmbience = pendingAmbience.filter { wanted.contains($0.key) }
        for event in events.prefix(Self.maxBeds) {
            addBed(event)
        }
        startFadeTimerIfNeeded()
    }

    func noteSpeechActivity() {
        lastSpeechActivity = Date()
    }

    func stopAll() {
        playbackGeneration += 1
        pendingAmbience.removeAll()
        stopFadeTimer()
        for voice in bundledVoices + cloudVoices {
            voice.generation += 1
            voice.isBusy = false
            voice.node.stop()
        }
        for bed in beds {
            resetBed(bed)
        }
        duckLevel = 1
        ambienceMixer.outputVolume = 1
        engine.stop()
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        for bed in beds where bed.soundID != nil {
            applyVolume(bed)
        }
    }

    // MARK: - One-shots

    private func playOneShot(_ event: StoryEvent) {
        let soundID = event.soundID

        // Prefer a downloaded cloud variant: that's where the variety is.
        if let cloud, let url = cloud.localFile(for: soundID), let buffer = cloudBuffer(url) {
            startVoice(in: cloudVoices, buffer: buffer, event: event)
            return
        }
        // The copy shipped with the app plays at full quality right away.
        if let url = AudioBufferCache.bundledFile(for: soundID), let buffer = cloudBuffer(url) {
            startVoice(in: cloudVoices, buffer: buffer, event: event)
            if let cloud, cloud.hasCloudVariants(soundID) {
                Task { _ = try? await cloud.fetchFile(for: soundID) }
            }
            return
        }
        if let buffer = buffers.buffer(for: soundID) {
            startVoice(in: bundledVoices, buffer: buffer, event: event)
            // Fetch a cloud variant for next time.
            if let cloud, cloud.hasCloudVariants(soundID) {
                Task { _ = try? await cloud.fetchFile(for: soundID) }
            }
            return
        }
        guard let cloud, cloud.hasCloudVariants(soundID) else { return }

        // Not on the device yet: download, and play only if still timely.
        let requestedAt = Date()
        let generation = playbackGeneration
        Task { @MainActor [weak self] in
            guard let url = try? await cloud.fetchFile(for: soundID),
                  let self, self.playbackGeneration == generation,
                  Date().timeIntervalSince(requestedAt) <= self.oneShotDownloadDeadline,
                  let buffer = self.cloudBuffer(url)
            else { return }
            self.startVoice(in: self.cloudVoices, buffer: buffer, event: event)
        }
    }

    private func startVoice(in pool: [Voice], buffer: AVAudioPCMBuffer, event: StoryEvent) {
        guard ensureRunning() else { return }
        recentOneShots = Array((recentOneShots + [event.soundID]).suffix(20))
        let voice = pool.first { !$0.isBusy } ?? pool.min { $0.startedAt < $1.startedAt }!
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

    private func cloudBuffer(_ url: URL) -> AVAudioPCMBuffer? {
        if let cached = cloudBuffers.get(url) { return cached }
        guard let buffer = AudioBufferCache.decode(url, to: Self.cloudFormat) else { return nil }
        cloudBuffers.set(url, buffer)
        return buffer
    }

    // MARK: - Ambience

    private func addBed(_ event: StoryEvent) {
        let soundID = event.soundID
        let holdUntil = Date().addingTimeInterval(pendingTimeout)

        if let bed = beds.first(where: { $0.soundID == soundID }) {
            bed.lastRequested = Date()
            bed.target = 1
            startFadeTimerIfNeeded()
            return
        }

        if let cloud, let url = cloud.localFile(for: soundID), let file = try? AVAudioFile(forReading: url) {
            startBed(event) { bed in self.startFileBed(bed, file: file) }
            return
        }
        // The copy shipped with the app streams with the same crossfaded loop.
        if let url = AudioBufferCache.bundledFile(for: soundID), let file = try? AVAudioFile(forReading: url) {
            startBed(event) { bed in self.startFileBed(bed, file: file) }
            if let cloud, cloud.hasCloudVariants(soundID) {
                Task { _ = try? await cloud.fetchFile(for: soundID) }
            }
            return
        }
        if let buffer = buffers.buffer(for: soundID) {
            startBed(event) { bed in
                bed.source = .buffer
                bed.bufferNode.scheduleBuffer(buffer, at: nil, options: .loops)
                bed.bufferNode.play()
            }
            if let cloud, cloud.hasCloudVariants(soundID) {
                Task { _ = try? await cloud.fetchFile(for: soundID) }
            }
            return
        }
        guard let cloud, cloud.hasCloudVariants(soundID), pendingAmbience[soundID] == nil else {
            pendingAmbience[soundID]?.holdUntil = holdUntil
            return
        }

        // Download, then start the bed if the scene still wants it.
        pendingAmbience[soundID] = (event, holdUntil)
        let generation = playbackGeneration
        Task { @MainActor [weak self] in
            let url = try? await cloud.fetchFile(for: soundID)
            guard let self, self.playbackGeneration == generation,
                  let pending = self.pendingAmbience.removeValue(forKey: soundID),
                  Date() < pending.holdUntil,
                  let url, let file = try? AVAudioFile(forReading: url)
            else { return }
            self.startBed(pending.event) { bed in self.startFileBed(bed, file: file) }
        }
    }

    /// Takes a free (or the least needed) bed and starts it fading in.
    private func startBed(_ event: StoryEvent, start: (Bed) -> Void) {
        guard ensureRunning() else { return }
        let bed = beds.first { $0.soundID == nil }
            ?? beds.filter { $0.target == 0 }.min { $0.level < $1.level }
            ?? beds.min { $0.lastRequested < $1.lastRequested }!

        resetBed(bed)
        bed.soundID = event.soundID
        bed.gain = multiplier(event.intensity)
        bed.target = 1
        bed.lastRequested = Date()
        start(bed)
        applyVolume(bed)
        startFadeTimerIfNeeded()
    }

    private func startFileBed(_ bed: Bed, file: AVAudioFile) {
        // Library files are 44.1 kHz stereo, but reconnect if one isn't, rather
        // than crash on a format mismatch.
        if bed.fileFormat != file.processingFormat {
            for node in bed.fileNodes {
                engine.connect(node, to: ambienceMixer, format: file.processingFormat)
            }
            bed.fileFormat = file.processingFormat
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        bed.source = .file(file, duration: duration)
        bed.activeFileNode = 0
        bed.segmentStartedAt = Date()
        bed.crossfadeStartedAt = nil
        let node = bed.fileNodes[0]
        node.scheduleFile(file, at: nil)
        node.play()
    }

    private func resetBed(_ bed: Bed) {
        bed.bufferNode.stop()
        bed.fileNodes.forEach { $0.stop() }
        bed.soundID = nil
        bed.source = .none
        bed.level = 0
        bed.target = 0
        bed.crossfadeStartedAt = nil
    }

    private func loopCrossfade(for duration: TimeInterval) -> TimeInterval {
        min(maxLoopCrossfade, duration / 4)
    }

    /// Starts the other file node near the end of each pass, so the file
    /// crossfades into its own beginning.
    private func advanceLoop(_ bed: Bed, now: Date) {
        guard case .file(let file, let duration) = bed.source else { return }
        let crossfade = loopCrossfade(for: duration)

        if let started = bed.crossfadeStartedAt {
            if now.timeIntervalSince(started) >= crossfade {
                bed.fileNodes[bed.activeFileNode].stop()
                bed.activeFileNode = 1 - bed.activeFileNode
                bed.segmentStartedAt = started
                bed.crossfadeStartedAt = nil
                completedLoops += 1
            }
        } else if now.timeIntervalSince(bed.segmentStartedAt) >= duration - crossfade {
            let next = bed.fileNodes[1 - bed.activeFileNode]
            next.stop()
            next.volume = 0
            next.scheduleFile(file, at: nil)
            next.play()
            bed.crossfadeStartedAt = now
        }
    }

    private func applyVolume(_ bed: Bed, now: Date = Date()) {
        let base = bed.level * bed.gain * volume
        switch bed.source {
        case .none:
            break
        case .buffer:
            bed.bufferNode.volume = base
        case .file(_, let duration):
            var gains: (active: Float, next: Float) = (1, 0)
            if let started = bed.crossfadeStartedAt {
                // Equal-power crossfade keeps loudness steady through the seam.
                let t = min(1, now.timeIntervalSince(started) / loopCrossfade(for: duration))
                gains = (Float(cos(t * .pi / 2)), Float(sin(t * .pi / 2)))
            }
            bed.fileNodes[bed.activeFileNode].volume = base * gains.active
            bed.fileNodes[1 - bed.activeFileNode].volume = base * gains.next
        }
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

        var hasActiveBed = !pendingAmbience.isEmpty
        for bed in beds where bed.soundID != nil {
            if now.timeIntervalSince(max(lastSpeechActivity, bed.lastRequested)) > quietTimeout { bed.target = 0 }
            let duration = bed.target > bed.level ? fadeInDuration : fadeOutDuration
            bed.level = approach(bed.level, bed.target, step: Float(tick / duration))
            advanceLoop(bed, now: now)
            applyVolume(bed, now: now)

            if bed.level == 0, bed.target == 0 {
                resetBed(bed)
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
        for voice in bundledVoices + cloudVoices {
            voice.generation += 1
            voice.isBusy = false
        }
        let activeBeds = beds.filter { $0.soundID != nil }
        guard !activeBeds.isEmpty, ensureRunning() else { return }
        for bed in activeBeds {
            switch bed.source {
            case .none:
                break
            case .buffer:
                guard let soundID = bed.soundID, let buffer = buffers.buffer(for: soundID) else { continue }
                bed.bufferNode.stop()
                bed.bufferNode.scheduleBuffer(buffer, at: nil, options: .loops)
                bed.bufferNode.play()
            case .file(let file, _):
                bed.fileNodes.forEach { $0.stop() }
                startFileBed(bed, file: file)
            }
            applyVolume(bed)
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

/// Small LRU of decoded cloud one-shots.
private struct CloudBufferCache {
    let limit: Int
    private var buffers: [URL: AVAudioPCMBuffer] = [:]
    private var order: [URL] = []

    init(limit: Int) { self.limit = limit }

    mutating func get(_ url: URL) -> AVAudioPCMBuffer? {
        guard let buffer = buffers[url] else { return nil }
        order.removeAll { $0 == url }
        order.append(url)
        return buffer
    }

    mutating func set(_ url: URL, _ buffer: AVAudioPCMBuffer) {
        buffers[url] = buffer
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > limit {
            buffers[order.removeFirst()] = nil
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
        preload: Bool = false
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
        guard let url = Self.url(for: soundID), let buffer = Self.decode(url, to: format) else { return nil }
        lock.withLock { storage[soundID] = buffer }
        return buffer
    }

    private func preloadAll() {
        let urls = Self.extensions.flatMap {
            (Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: "Sounds") ?? [])
                + (Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [])
        }
        for url in urls {
            let soundID = url.deletingPathExtension().lastPathComponent
            guard lock.withLock({ storage[soundID] }) == nil, let buffer = Self.decode(url, to: format) else { continue }
            lock.withLock { storage[soundID] = buffer }
        }
    }

    /// Reads an audio file fully and converts it to `format`.
    static func decode(_ url: URL, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let source = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
              ),
              (try? file.read(into: source)) != nil
        else { return nil }

        if file.processingFormat == format { return source }
        return convert(source, to: format)
    }

    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        if source.format.channelCount == 1, format.channelCount == 2 {
            // Put a mono source in both channels, not just the left.
            converter.channelMap = [0, 0]
        }
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

    private static let extensions = ["mp3", "m4a", "wav"]

    private static func url(for soundID: String) -> URL? {
        bundledFile(for: soundID)
    }

    /// The sound's file shipped with the app (the first variant of its
    /// generated library sound), if any.
    static func bundledFile(for soundID: String) -> URL? {
        for ext in extensions {
            if let url = Bundle.main.url(forResource: soundID, withExtension: ext, subdirectory: "Sounds")
                ?? Bundle.main.url(forResource: soundID, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
