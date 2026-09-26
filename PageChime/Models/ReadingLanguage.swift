import Foundation

enum ReadingLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    var speechLocales: [String] {
        switch self {
        case .english: return ["en-US", "en-GB", "en-SG", "en-AU", "en"]
        case .chinese: return ["zh-CN", "zh_CN", "zh-Hans-CN", "zh-Hans", "zh-SG", "zh_SG"]
        }
    }
}
