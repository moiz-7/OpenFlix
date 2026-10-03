import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Reference images from local files
//
// Until 2026-09 neither the CLI nor the app could do image-to-video from a file
// on this Mac. Every provider takes the image *by URL* and fetches it itself,
// nothing uploaded anything, and so both halves refused every local reference
// ("must be a public http(s) URL"). In the app that meant image-to-video was
// refused for every remote provider — including "Recreate this shot", whose
// reference is always a frame grabbed to disk.
//
// The fix does not need a hosting service of our own. Verified against each
// provider's current documentation (2026-09-27):
//
// | Provider  | Local image delivery                         | Limit used here |
// |-----------|----------------------------------------------|-----------------|
// | Runway    | `data:` URI in `promptImage` (≤ 5 MB encoded)| 3.5 MB raw      |
// | MiniMax   | `data:` URI (V1 ≤ 20 MB; V2 body ≤ 64 MB)    | 8 MB raw        |
// | Kling     | Base64 in `contents[].url` (≤ 50 MB)         | 8 MB raw        |
// | fal       | upload to fal's CDN, pass the returned URL   | 10 MB raw       |
// | Replicate | `data:` URI                                  | 1 MB raw        |
// | Luma      | **public URL only** — no upload, no base64   | refused         |
//
// Luma's own docs: "You should upload and use your own cdn image urls,
// currently this is the only way to pass an image." That is the one honest
// refusal left.

/// How a provider must receive an image that lives on this Mac.
public enum ReferenceTransport: Equatable {
    /// `data:<mime>;base64,<…>` in the provider's image field.
    case dataURI(maxBytes: Int)
    /// Bare base64 (no `data:` prefix) in the provider's image field.
    case rawBase64(maxBytes: Int)
    /// Upload to the provider's own storage first; send the resulting URL.
    case upload(maxBytes: Int)
    /// The provider cannot accept a local image at all.
    case unsupported(reason: String)

    /// The largest encoded image this transport will carry.
    public var maxBytes: Int? {
        switch self {
        case .dataURI(let b), .rawBase64(let b), .upload(let b): return b
        case .unsupported: return nil
        }
    }

    /// The transport each provider needs for a local file. Remote http(s)
    /// references are always passed through unchanged and never reach this.
    public static func forProvider(_ providerId: String) -> ReferenceTransport {
        switch providerId {
        case "runway":             return .dataURI(maxBytes: 3_500_000)
        case "minimax":            return .dataURI(maxBytes: 8_000_000)
        case "kling":              return .rawBase64(maxBytes: 8_000_000)
        case "fal", "seedance":    return .upload(maxBytes: 10_000_000)
        case "replicate":          return .dataURI(maxBytes: 1_000_000)
        case "luma":
            return .unsupported(reason:
                "Luma's API only accepts an image by public URL — it has no upload "
                + "endpoint and does not take base64. Use Kling, Runway, MiniMax, fal "
                + "or Replicate for a local image, or host the image and pass its URL.")
        default:
            return .unsupported(reason: "\(providerId) cannot receive a local reference image.")
        }
    }
}

/// A reference image ready to send: the bytes plus their media type.
public struct EncodedImage: Equatable {
    public let data: Data
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// True when the original file's bytes are sent untouched.
    public let isOriginalBytes: Bool

    public var base64: String { data.base64EncodedString() }
    public var dataURI: String { "data:\(mimeType);base64,\(base64)" }

    public var fileExtension: String {
        switch mimeType {
        case "image/png":  return "png"
        case "image/webp": return "webp"
        default:           return "jpg"
        }
    }
}

public enum ReferenceImageError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case notAnImage(String)
    case tooSmall(width: Int, height: Int, minimum: Int)
    case extremeAspectRatio(width: Int, height: Int)
    case cannotFit(bytes: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "Couldn't read the reference image at \(path)."
        case .notAnImage(let path):
            return "The reference file isn't an image this Mac can decode: \(path)."
        case .tooSmall(let w, let h, let min):
            return "The reference image is \(w)×\(h); providers need at least \(min) px on the short side."
        case .extremeAspectRatio(let w, let h):
            return "The reference image is \(w)×\(h). Providers accept aspect ratios between 2:5 and 5:2 — crop it and try again."
        case .cannotFit(let bytes):
            return "The reference image couldn't be compressed under \(bytes / 1_000_000) MB for this provider."
        }
    }
}

public enum ReferenceImageEncoder {

    /// Shorter side must be at least this. Kling and MiniMax V1 both require
    /// 300 px; everyone else is looser, and nothing useful is smaller.
    public static let minimumShortEdge = 300

    /// Longest side sent. Every provider downsamples to ≤ 1080p output, so
    /// anything larger is upload time and payload spent on pixels nobody keeps.
    public static let maximumLongEdge = 2048

    /// Widest aspect every provider accepts (MiniMax: [0.4, 2.5]; Kling:
    /// 1:2.5 – 2.5:1). Refusing here is cheaper than a 400 after queueing.
    public static let maximumAspect = 2.5

    private static let passThroughTypes: [String: String] = [
        UTType.jpeg.identifier: "image/jpeg",
        UTType.png.identifier: "image/png",
        UTType.webP.identifier: "image/webp",
    ]

    /// Reads, validates and (only when needed) re-encodes a local image.
    ///
    /// The original bytes are sent when the file is already JPEG/PNG/WebP,
    /// upright, within `maxBytes` and at most `maximumLongEdge` on its long
    /// side — the provider then sees exactly what the user chose. Anything
    /// else (HEIC, TIFF, rotated EXIF, too large) is rendered upright at
    /// ≤ `maximumLongEdge` and written as JPEG, stepping quality down until it
    /// fits. Pure: no network, no globals.
    public static func encode(fileURL: URL, maxBytes: Int) throws -> EncodedImage {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ReferenceImageError.unreadable(fileURL.path)
        }
        return try encode(data: data, sourceDescription: fileURL.path, maxBytes: maxBytes)
    }

    public static func encode(data: Data, sourceDescription: String = "image", maxBytes: Int) throws -> EncodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int,
              rawW > 0, rawH > 0 else {
            throw ReferenceImageError.notAnImage(sourceDescription)
        }

        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        // EXIF orientations 5–8 swap width and height once applied.
        let (w, h) = orientation >= 5 ? (rawH, rawW) : (rawW, rawH)

        guard min(w, h) >= minimumShortEdge else {
            throw ReferenceImageError.tooSmall(width: w, height: h, minimum: minimumShortEdge)
        }
        guard Double(max(w, h)) / Double(min(w, h)) <= maximumAspect else {
            throw ReferenceImageError.extremeAspectRatio(width: w, height: h)
        }

        if let type = CGImageSourceGetType(source) as String?,
           let mime = passThroughTypes[type],
           orientation == 1,
           data.count <= maxBytes,
           max(w, h) <= maximumLongEdge {
            return EncodedImage(data: data, mimeType: mime, pixelWidth: w, pixelHeight: h, isOriginalBytes: true)
        }

        // Re-render upright and bounded. The thumbnail API applies the EXIF
        // transform, which a plain CGImageSourceCreateImageAtIndex would not.
        var longEdge = min(maximumLongEdge, max(w, h))
        while longEdge >= minimumShortEdge {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longEdge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                throw ReferenceImageError.notAnImage(sourceDescription)
            }
            for quality in [0.9, 0.8, 0.7, 0.6] {
                if let jpeg = jpegData(image, quality: quality), jpeg.count <= maxBytes {
                    return EncodedImage(data: jpeg, mimeType: "image/jpeg",
                                        pixelWidth: image.width, pixelHeight: image.height,
                                        isOriginalBytes: false)
                }
            }
            // Still too big at the lowest quality: shrink and retry, but never
            // below the providers' minimum short edge.
            let next = Int(Double(longEdge) * 0.75)
            let nextShort = Int(Double(next) * Double(min(w, h)) / Double(max(w, h)))
            if nextShort < minimumShortEdge { break }
            longEdge = next
        }
        throw ReferenceImageError.cannotFit(bytes: maxBytes)
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - Resolution: local file → something the provider can use

/// Uploads bytes to a provider's storage and returns the public URL. Injected
/// so the resolver stays testable without a network.
public typealias ReferenceUploader = (_ image: EncodedImage, _ apiKey: String) async throws -> URL

public enum ReferenceImageResolver {

    /// Whether `url` names a file on this Mac rather than a remote image.
    public static func isLocal(_ url: URL) -> Bool {
        url.isFileURL || url.scheme == nil
    }

    /// Checks — without sending anything — that a local reference can be
    /// delivered to `providerId`. Returns a user-facing refusal, or nil.
    public static func refusal(for url: URL, providerId: String) -> String? {
        guard isLocal(url) else {
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" || scheme == "data" { return nil }
            return "Reference image must be a local file or an http(s) URL (got: \(url.absoluteString))."
        }
        let transport = ReferenceTransport.forProvider(providerId)
        if case .unsupported(let reason) = transport { return reason }
        do {
            _ = try ReferenceImageEncoder.encode(fileURL: url, maxBytes: transport.maxBytes ?? 0)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Turns a reference into the URL a provider's request body should carry.
    ///
    /// - http(s) / data URLs pass through untouched.
    /// - A local file is encoded for the provider's transport: a `data:` URI,
    ///   or an upload whose returned https URL is used. Kling's raw-base64 form
    ///   is also returned as a `data:` URI; `KlingWire` strips the prefix,
    ///   because a bare base64 string is not a URL.
    public static func resolve(_ url: URL, providerId: String, apiKey: String,
                               uploader: ReferenceUploader?) async throws -> URL {
        guard isLocal(url) else { return url }
        let transport = ReferenceTransport.forProvider(providerId)
        switch transport {
        case .unsupported(let reason):
            throw ProviderError.invalidResponse(reason)
        case .dataURI(let maxBytes), .rawBase64(let maxBytes):
            let image = try ReferenceImageEncoder.encode(fileURL: url, maxBytes: maxBytes)
            guard let dataURL = URL(string: image.dataURI) else {
                throw ProviderError.invalidResponse("Could not form a data URI for the reference image.")
            }
            return dataURL
        case .upload(let maxBytes):
            guard let uploader else {
                throw ProviderError.invalidResponse("\(providerId) needs an uploader for local reference images.")
            }
            let image = try ReferenceImageEncoder.encode(fileURL: url, maxBytes: maxBytes)
            return try await uploader(image, apiKey)
        }
    }
}
