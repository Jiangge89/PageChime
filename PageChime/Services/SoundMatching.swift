import Foundation

struct LLMSoundMatch {
    let id: String
    let trigger: String
}

struct SoundAnalysis {
    /// Sounds triggered by the new text.
    let sounds: [LLMSoundMatch]
    /// Ambience beds for the current scene, or nil if the scene is unchanged.
    let ambience: [String]?
    /// Sounds the story makes likely soon, to download ahead of time.
    var upcoming: [String] = []
}

protocol SoundMatching: AnyObject {
    /// - Parameters:
    ///   - text: Newly read text.
    ///   - context: The story read just before it, for understanding the scene.
    func analyze(text: String, context: String) async throws -> SoundAnalysis
}
