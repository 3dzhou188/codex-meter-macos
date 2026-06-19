import Foundation

enum StatusDisplayMode: String, CaseIterable, Identifiable {
    case usageAndAgent
    case usageOnly
    case agentOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usageAndAgent: "额度 + Agent"
        case .usageOnly: "仅额度"
        case .agentOnly: "仅 Agent"
        }
    }
}
