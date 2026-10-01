import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import SwiftUI

/// An image of a prompt: the pixels as stored and their orientation, which
/// the adapter applies before the projector sees the image.
struct PromptImage: Identifiable, @unchecked Sendable {
    // CGImage is immutable and thread-safe.
    let id = UUID()
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation

    /// Longest side kept: the projector resizes the image anyway, a smaller
    /// copy saves memory and conversion time.
    static let maximumPixelSize = 1536

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "The file is not a readable image." }
    }

    /// Decodes and downsizes image data off the main actor. The EXIF
    /// orientation is read, not applied, so it reaches the model with the image.
    @concurrent static func decode(_ data: Data) async throws -> PromptImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Unreadable() }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Unreadable() }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return PromptImage(cgImage: image, orientation: CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    @concurrent static func load(_ url: URL) async throws -> PromptImage {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try await decode(try Data(contentsOf: url))
    }

    var attachment: Attachment<ImageAttachmentContent> {
        Attachment(cgImage, orientation: orientation)
    }

    /// The image upright, for display.
    var image: Image {
        Image(decorative: cgImage, scale: 1, orientation: Image.Orientation(orientation))
    }
}

extension Image.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
