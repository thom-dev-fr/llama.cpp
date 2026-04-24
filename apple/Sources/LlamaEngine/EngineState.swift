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

/// Describes what kinds of inputs the currently loaded model accepts.
///
/// Populated when an `mmproj` projector is provided at load time and the
/// projector's backbone reports support for the corresponding modality.
/// Values are captured once at `load()` and kept across `sleep()`/`wake()`.
public struct EngineCapabilities: Sendable, Equatable {
    /// True when an mmproj has been loaded alongside the base model.
    public var hasMultimodal: Bool
    /// True when the loaded projector accepts image inputs.
    public var supportsVision: Bool
    /// True when the loaded projector accepts audio inputs (wav/mp3).
    public var supportsAudio: Bool

    public init(hasMultimodal: Bool = false,
                supportsVision: Bool = false,
                supportsAudio: Bool = false) {
        self.hasMultimodal  = hasMultimodal
        self.supportsVision = supportsVision
        self.supportsAudio  = supportsAudio
    }

    public static let none = EngineCapabilities()
}
