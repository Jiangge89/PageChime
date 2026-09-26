import Foundation

enum ListeningState: Equatable {
    case ready
    case listening
    case paused
    case permissionRequired
    case error(String)

    var displayText: String {
        switch self {
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .paused: return "Paused"
        case .permissionRequired: return "Permission Required"
        case .error(let message): return "Error: \(message)"
        }
    }
}
