import Foundation

/// Errors of the runtime, independent of Foundation Models.
public enum LlamaEngineError: Error, Sendable, Equatable {
    /// The native engine is not part of this build yet.
    case engineUnavailable(String)
    /// The prompt, or the prompt and the generated tokens, exceed the context.
    case contextExceeded(LlamaContextOverflow)
    /// An error reported by the native engine: its category (invalid_request,
    /// load_failed, queue_full, cancelled, unloaded, ...), message and JSON details.
    case native(category: String, message: String, details: Data)
    /// Two tasks read the same request at the same time.
    case concurrentReaders
    /// A configuration value is out of range.
    case invalidConfiguration(String)
    /// The admission queue is full: `waitingCapacity` requests already wait.
    case queueFull(waitingCapacity: Int)
    /// A request waited for admission longer than the configured limit.
    case admissionTimedOut(Duration)
    /// No model with this identifier is in the runtime catalog.
    case modelNotFound(LlamaModelID)
    /// The model is being unloaded or removed: its admissions are closed.
    case modelUnavailable(LlamaModelID, reason: String)
    /// The explicit unload of the model ended this request; its history is the
    /// caller's and a new request may load the model again.
    case unloaded(LlamaModelID)
    /// A model with this identifier already exists.
    case modelExists(LlamaModelID)
    /// A file to import is missing, unreadable, incomplete or not a GGUF file.
    case invalidModelFile(String)
    /// The volume of the model store has less free space than the import needs.
    case insufficientSpace(required: Int64, available: Int64)
}

extension LlamaEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let reason):
            return "The llama.cpp engine is unavailable: \(reason)"
        case .contextExceeded(let overflow):
            return overflow.message
        case .native(let category, let message, _):
            return message.isEmpty ? "llama.cpp engine error: \(category)" : message
        case .concurrentReaders:
            return "A llama.cpp request has a single reader at a time"
        case .invalidConfiguration(let reason):
            return "Invalid llama.cpp runtime configuration: \(reason)"
        case .queueFull(let capacity):
            return "The llama.cpp admission queue is full (\(capacity) waiting requests)"
        case .admissionTimedOut(let limit):
            return "The request waited for admission longer than \(limit)"
        case .modelNotFound(let id):
            return "No llama.cpp model '\(id)' in the catalog"
        case .modelUnavailable(let id, let reason):
            return "The llama.cpp model '\(id)' is unavailable: \(reason)"
        case .unloaded(let id):
            return "The llama.cpp model '\(id)' was unloaded"
        case .modelExists(let id):
            return "A llama.cpp model '\(id)' already exists"
        case .invalidModelFile(let reason):
            return "Invalid model file: \(reason)"
        case .insufficientSpace(let required, let available):
            return "Not enough free space: \(required) bytes needed, \(available) available"
        }
    }
}
