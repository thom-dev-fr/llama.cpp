import Foundation

public enum LlamaError: Error, CustomStringConvertible, Sendable {
    case notLoaded
    case alreadyLoaded
    case loadFailed(String)
    case invalidArgument(String)
    case invalidRequest(String)
    case inference(String, payload: String?)
    case cancelled
    case timeout
    case internalError(String)

    public var description: String {
        switch self {
        case .notLoaded:              return "engine not loaded"
        case .alreadyLoaded:          return "engine already loaded"
        case .loadFailed(let m):      return "failed to load model: \(m)"
        case .invalidArgument(let m): return "invalid argument: \(m)"
        case .invalidRequest(let m):  return "invalid request: \(m)"
        case .inference(let m, _):    return "inference error: \(m)"
        case .cancelled:              return "cancelled"
        case .timeout:                return "timeout"
        case .internalError(let m):   return "internal error: \(m)"
        }
    }
}
