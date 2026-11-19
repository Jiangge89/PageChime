import Foundation

enum AppConfig {
    /// PageChime API base URL, from the `PAGECHIME_BACKEND_URL` build setting
    /// (via Info.plist). Nil when unset: the app then uses keyword matching only.
    static var backendURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PageChimeBackendURL") as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return URL(string: value)
    }
}
