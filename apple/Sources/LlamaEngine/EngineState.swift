import Foundation

public enum EngineState: Int, Sendable, CustomStringConvertible {
    case unloaded  = 0
    case loading   = 1
    case ready     = 2
    case sleeping  = 3
    case unloading = 4

    public var description: String {
        switch self {
        case .unloaded:  return "unloaded"
        case .loading:   return "loading"
        case .ready:     return "ready"
        case .sleeping:  return "sleeping"
        case .unloading: return "unloading"
        }
    }
}
