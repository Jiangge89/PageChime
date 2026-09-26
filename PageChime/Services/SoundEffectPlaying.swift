import Foundation

protocol SoundEffectPlaying: AnyObject {
    func play(event: StoryEvent)
    func stopAll()
    func setVolume(_ volume: Float)
}
