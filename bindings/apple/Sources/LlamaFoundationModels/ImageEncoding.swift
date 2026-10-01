import CoreGraphics
import CoreImage
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

/// Converts image attachments to bytes the engine decodes (PNG, lossless),
/// with the orientation applied: the model sees the image upright.
enum ImageEncoding {
    /// Encoding is CPU-bound and may take a while for a large photo: it runs
    /// here, never on the cooperative pool or the main actor.
    private static let queue = DispatchQueue(label: "org.ggml.llama.image-encoding", qos: .userInitiated,
                                             attributes: .concurrent)

    struct Failure: Error {
        var reason: String
    }

    static func png(_ image: Transcript.ImageAttachment) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try encode(image) })
            }
        }
    }

    static func encode(_ image: Transcript.ImageAttachment) throws -> Data {
        let upright = try oriented(image.cgImage, image.orientation)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(reason: "cannot create a PNG encoder")
        }
        CGImageDestinationAddImage(destination, upright, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(reason: "PNG encoding failed")
        }
        return data as Data
    }

    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        let rotated = CIImage(cgImage: image).oriented(orientation)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(rotated, from: rotated.extent) else {
            throw Failure(reason: "cannot apply the image orientation")
        }
        return result
    }
}
