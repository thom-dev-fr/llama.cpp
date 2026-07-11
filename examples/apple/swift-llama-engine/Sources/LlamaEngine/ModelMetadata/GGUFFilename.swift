import Foundation

/// Parsed information derived from a GGUF-like model filename.
public struct GGUFFilenameInfo: Sendable, Hashable, Codable {
    /// Human-readable display name derived from the filename.
    public var displayName: String

    /// Trailing quantization suffix when present, e.g. `Q4_K_M` or `Q8_0`.
    public var quantizationSuffix: String?

    /// Filename base used to match companion files such as `mmproj-*`.
    public var baseName: String?

    public init(displayName: String,
                quantizationSuffix: String? = nil,
                baseName: String? = nil) {
        self.displayName = displayName
        self.quantizationSuffix = quantizationSuffix
        self.baseName = baseName
    }
}

/// Pure filename helpers for common GGUF ecosystem naming conventions.
public enum GGUFFilename {
    /// Detects a model base name from a filename by dropping the last
    /// dash-separated component (typically the quantization suffix) after
    /// removing one known model extension.
    ///
    /// Example: `"Qwen2.5-Omni-3B-Q4_K_M.gguf"` -> `"Qwen2.5-Omni-3B"`.
    /// Returns `nil` if the filename has fewer than two dash-separated parts.
    public static func baseName(from filename: String) -> String? {
        let stem = droppingKnownExtension(from: filename)
        let parts = stem.components(separatedBy: "-")
        guard parts.count >= 2 else { return nil }
        return parts.dropLast().joined(separator: "-")
    }

    /// Cleans a model filename and extracts its trailing quantization suffix.
    ///
    /// - Strips a known extension (`.gguf`, `.bin`, `.pt`, `.onnx`, `.safetensors`).
    /// - Extracts a trailing `-Q...` / `_Q...` quantization marker if present.
    /// - Replaces dashes/underscores with spaces and collapses whitespace.
    /// - Capitalizes the first letter of the display name.
    public static func parse(_ filename: String) -> GGUFFilenameInfo {
        var stem = droppingKnownExtension(from: filename)
        let companionBaseName = baseName(from: filename)

        var quantizationSuffix: String? = nil
        if let match = stem.range(of: "[-_](Q[0-9]+[A-Za-z0-9_\\-]*)$", options: .regularExpression) {
            let quantPart = String(stem[match])
            quantizationSuffix = String(quantPart.dropFirst())
            stem.removeSubrange(match)
        }

        var cleaned = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = cleaned.first {
            cleaned.replaceSubrange(cleaned.startIndex...cleaned.startIndex, with: String(first).capitalized)
        }

        return GGUFFilenameInfo(
            displayName: cleaned,
            quantizationSuffix: quantizationSuffix,
            baseName: companionBaseName
        )
    }

    private static func droppingKnownExtension(from filename: String) -> String {
        let knownExtensions: Set<String> = ["gguf", "bin", "pt", "onnx", "safetensors"]
        guard let ext = filename.split(separator: ".").last,
              knownExtensions.contains(ext.lowercased()) else { return filename }
        return String(filename.dropLast(ext.count + 1))
    }
}
