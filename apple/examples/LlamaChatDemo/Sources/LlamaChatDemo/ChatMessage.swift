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

    /// Pièce jointe (image ou audio) attachée à un message utilisateur.
    /// Les octets sont conservés directement — le format d'encodage est
    /// préservé jusqu'à l'envoi où ils sont base64-isés dans le JSON.
    struct Attachment: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Image, `mime` est un type MIME standard (ex. `image/png`, `image/jpeg`).
            case image(mime: String)
            /// Audio, `format` est `wav` ou `mp3` (contraintes OpenAI).
            case audio(format: String)
        }
        let id = UUID()
        var kind: Kind
        var data: Data
        var filename: String

        var isImage: Bool { if case .image = kind { return true } else { return false } }
        var isAudio: Bool { if case .audio = kind { return true } else { return false } }
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

    /// Pièces jointes (images, audio) — uniquement sur les messages `user`.
    var attachments: [Attachment] = []

    var hasReasoning: Bool { !reasoning.isEmpty }
    var hasToolCalls: Bool { !toolCalls.isEmpty }
    var hasAttachments: Bool { !attachments.isEmpty }
}

