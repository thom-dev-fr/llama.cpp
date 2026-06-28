import Foundation

struct ChatMessage: Identifiable, Equatable {
  enum Role: String {
    case system
    case user
    case assistant
    case tool
  }

  struct ToolCall: Identifiable, Equatable {
    var id: String
    var name: String
    var arguments: String
  }

  /// Image or audio data attached to a user message.
  struct Attachment: Identifiable, Equatable {
    enum Kind: Equatable {
      /// Image with a standard MIME type, such as `image/png` or `image/jpeg`.
      case image(mime: String)
      /// Audio format accepted by the OpenAI-compatible request parser.
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

  /// Function calls emitted by an assistant message.
  var toolCalls: [ToolCall] = []

  /// Populated only on tool-result messages.
  var toolCallID: String? = nil
  var toolName: String? = nil

  /// Attachments are only set on user messages.
  var attachments: [Attachment] = []

  var hasReasoning: Bool { !reasoning.isEmpty }
  var hasToolCalls: Bool { !toolCalls.isEmpty }
  var hasAttachments: Bool { !attachments.isEmpty }
}
