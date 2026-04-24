import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case system
        case user
        case assistant
        case tool
    }

    struct ToolCall: Identifiable, Equatable {
        var id: String          // tool_call_id généré côté serveur
        var name: String
        var arguments: String   // JSON brut, potentiellement accumulé par streaming
    }

    let id = UUID()
    var role: Role
    var content: String
    var reasoning: String = ""
    var isStreaming: Bool = false

    /// Appels de fonction émis par un message `assistant`.
    var toolCalls: [ToolCall] = []

    /// Renseignés uniquement sur les messages `role == .tool` (résultat
    /// d'exécution renvoyé au modèle).
    var toolCallID: String? = nil
    var toolName: String?   = nil

    var hasReasoning: Bool { !reasoning.isEmpty }
    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

