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

/// Sound cues for a whole book page, found before it is read aloud.
struct PageAnalysis {
    /// One-shots and mid-page ambience changes, in reading order, each with
    /// the phrase from the page that sets it off.
    let cues: [LLMSoundMatch]
    /// Ambience at the top of the page, or nil to keep the current scene.
    let ambience: [String]?
    /// Sounds the following pages will probably need.
    let upcoming: [String]
}

protocol PageAnalyzing: AnyObject {
    func analyzePage(text: String, context: String) async throws -> PageAnalysis
}

protocol SoundMatching: AnyObject {
    /// - Parameters:
    ///   - text: Newly read text.
    ///   - context: The story read just before it, for understanding the scene.
    func analyze(text: String, context: String) async throws -> SoundAnalysis
}
