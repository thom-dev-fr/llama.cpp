import Foundation

public enum EngineState: Int, Sendable, CustomStringConvertible {
    case unloaded  = 0
    case loading   = 1
    case ready     = 2
    case paused    = 3
    case unloading = 4
    case pausing   = 5
    case resuming  = 6

    public var description: String {
        switch self {
        case .unloaded:  return "unloaded"
        case .loading:   return "loading"
        case .ready:     return "ready"
        case .paused:    return "paused"
        case .unloading: return "unloading"
        case .pausing:   return "pausing"
        case .resuming:  return "resuming"
        }
    }
}
