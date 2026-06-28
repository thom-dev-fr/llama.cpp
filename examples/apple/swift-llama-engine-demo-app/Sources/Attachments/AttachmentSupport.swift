import Foundation
import UniformTypeIdentifiers

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Converts user-selected files into chat attachments and decodes image data
/// back into SwiftUI images for display.
enum AttachmentSupport {
  /// Maximum resized image side in pixels before sending to the model.
  static let maxImageSide: Int = 1024

  /// Maximum accepted audio size in bytes.
  static let maxAudioBytes: Int = 20 * 1024 * 1024

  // MARK: - Images

  /// Loads an image URL, downscales it when possible, and stores it as JPEG.
  static func makeImageAttachment(from url: URL) -> ChatMessage.Attachment? {
    guard let raw = try? Data(contentsOf: url) else { return nil }
    let filename = url.lastPathComponent

    if let downscaled = downscaleImage(data: raw, maxSide: maxImageSide) {
      return ChatMessage.Attachment(
        kind: .image(mime: "image/jpeg"),
        data: downscaled,
        filename: filename
      )
    }

    let mime = mimeForImageURL(url) ?? "application/octet-stream"
    return ChatMessage.Attachment(
      kind: .image(mime: mime),
      data: raw,
      filename: filename
    )
  }

  /// Creates an image attachment from in-memory bytes.
  static func makeImageAttachment(from data: Data, filename: String) -> ChatMessage.Attachment {
    if let downscaled = downscaleImage(data: data, maxSide: maxImageSide) {
      return ChatMessage.Attachment(
        kind: .image(mime: "image/jpeg"),
        data: downscaled,
        filename: filename
      )
    }
    return ChatMessage.Attachment(
      kind: .image(mime: detectMimeFromMagicBytes(data) ?? "image/png"),
      data: data,
      filename: filename
    )
  }

  // MARK: - Audio

  /// Loads an audio file supported by the OpenAI-compatible request parser.
  static func makeAudioAttachment(from url: URL) -> ChatMessage.Attachment? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard data.count <= maxAudioBytes else { return nil }

    let ext = url.pathExtension.lowercased()
    let format: String
    switch ext {
    case "wav", "wave": format = "wav"
    case "mp3":         format = "mp3"
    default:            return nil
    }
    return ChatMessage.Attachment(
      kind: .audio(format: format),
      data: data,
      filename: url.lastPathComponent
    )
  }

  // MARK: - Internals

  /// Downscales through ImageIO and re-encodes as JPEG.
  private static func downscaleImage(data: Data, maxSide: Int) -> Data? {
#if canImport(ImageIO)
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform:   true,
      kCGImageSourceThumbnailMaxPixelSize:          maxSide,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
      return nil
    }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
    CGImageDestinationAddImage(dest, cg, destOpts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
#else
    return nil
#endif
  }

  private static func mimeForImageURL(_ url: URL) -> String? {
    if let t = UTType(filenameExtension: url.pathExtension.lowercased()),
       let mime = t.preferredMIMEType {
      return mime
    }
    return nil
  }

  private static func detectMimeFromMagicBytes(_ data: Data) -> String? {
    guard data.count >= 4 else { return nil }
    // PNG: 89 50 4E 47
    if data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return "image/png" }
    // JPEG: FF D8 FF
    if data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "image/jpeg" }
    // GIF: "GIF8"
    if data[0] == 0x47, data[1] == 0x49, data[2] == 0x46, data[3] == 0x38 { return "image/gif" }
    // WEBP: RIFF....WEBP
    if data.count >= 12,
       data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
       data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return "image/webp" }
    return nil
  }
}
