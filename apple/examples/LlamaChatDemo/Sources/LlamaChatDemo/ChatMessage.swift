import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case system
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var content: String
    var reasoning: String = ""
    var isStreaming: Bool = false

    var hasReasoning: Bool { !reasoning.isEmpty }
}
