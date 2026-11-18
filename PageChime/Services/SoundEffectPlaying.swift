import Foundation

protocol SoundEffectPlaying: AnyObject {
    /// Plays a one-shot sound, or adds an ambience bed for ambience sounds.
    func play(event: StoryEvent)
    /// Makes these the only ambience beds, crossfading from the current ones.
    func setAmbience(_ events: [StoryEvent])
    /// Called while the reader is speaking, so ambience can duck under the voice.
    func noteSpeechActivity()
    func stopAll()
    func setVolume(_ volume: Float)
}
