import Foundation

struct AnalysisLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let inputText: String
    let method: Method
    let waitMs: Int
    let analysisMs: Int
    let soundIDs: [String]

    var totalMs: Int { waitMs + analysisMs }

    enum Method: String {
        case cache = "Cache"
        case llm = "LLM"
        case keyword = "Keyword"
        case noMatch = "No Match"
    }
}
