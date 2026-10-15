import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AttachmentError: LocalizedError {
    case unreadable(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "„\(name)“ ist kein Bild, das die App lesen kann."
        case .writeFailed: "Das Bild konnte nicht gespeichert werden."
        }
    }
}

/// Pictures attached to messages, stored as JPEG files under Application Support. They are scaled down
/// on import: vision models work at a fixed resolution anyway, and every picture is sent again with each
/// question in the chat.
enum AttachmentStore {
    /// Where a picture comes from: a file, or image data from the clipboard or a drag.
    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    static let maxPixelSize = 1600

    /// In the open library.
    static var directory: URL { AppLibrary.current.folder("Attachments") }

    static func url(for attachment: ImageAttachment) -> URL {
        directory.appendingPathComponent(attachment.fileName)
    }

    /// Reads the picture, scales it to at most `maxPixelSize`, flattens transparency onto white and saves it as JPEG.
    static func importImage(_ source: Source) throws -> ImageAttachment {
        let name: String
        let imageSource: CGImageSource?
        switch source {
        case .file(let url):
            name = url.lastPathComponent
            imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data(let data):
            name = "Bild"
            imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let imageSource, CGImageSourceGetCount(imageSource) > 0 else { throw AttachmentError.unreadable(name) }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let longestSide = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide > 0 ? min(longestSide, maxPixelSize) : maxPixelSize,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let image = flattened(scaled) else { throw AttachmentError.unreadable(name) }

        let attachment = ImageAttachment(fileName: UUID().uuidString + ".jpg", width: image.width, height: image.height)
        guard let destination = CGImageDestinationCreateWithURL(url(for: attachment) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.writeFailed }
        return attachment
    }

    /// The picture as a `data:` URL for the chat request.
    static func dataURL(for attachment: ImageAttachment) -> String? {
        guard let data = try? Data(contentsOf: url(for: attachment)) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// Deletes pictures that no chat and no draft uses any more. Files from the last minutes stay: they may
    /// belong to a picture that is being imported or edited right now.
    static func removeUnused(keeping fileNames: Set<String>) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let cutoff = Date().addingTimeInterval(-15 * 60)
        for file in files where !fileNames.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

/// Finds pictures on a pasteboard (clipboard or drag): image files, or raw image data such as a screenshot.
@MainActor
enum ImagePasteboard {
    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]
    private static let dataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
    ]

    /// Cheap check while a drag moves over a view.
    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions) || pasteboard.availableType(from: dataTypes) != nil
    }

    /// The pictures on the pasteboard, or nil if there are none. With `preferText`, copied text wins over
    /// an image that comes along with it (apps like Excel put both on the clipboard).
    static func sources(on pasteboard: NSPasteboard, preferText: Bool) -> [AttachmentStore.Source]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            return urls.map { .file($0) }
        }
        if preferText && pasteboard.string(forType: .string) != nil { return nil }
        guard let type = pasteboard.availableType(from: dataTypes), let data = pasteboard.data(forType: type) else { return nil }
        return [.data(data)]
    }
}
