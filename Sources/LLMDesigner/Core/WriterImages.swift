import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture in a Writer Studio document. In Markdown it is a line of its own:
/// `![Bildunterschrift](Bilder/….png){width=50%}`, the width in Pandoc's attribute syntax.
struct WriterImageReference: Equatable, Sendable {
    /// Where the file is, as written in Markdown: relative to the documents folder, or an absolute path.
    var source: String
    var caption: String
    /// Percent of the column width; nil: the picture's own size, at most the column.
    var width: Int?
    /// Set for a plot of the formula above it (`.plot` and its settings in the attributes).
    var plot: PlotSpec?

    init(source: String, caption: String, width: Int?, plot: PlotSpec? = nil) {
        self.source = source
        self.caption = caption
        self.width = width
        self.plot = plot
    }

    /// The sizes the editor offers, in percent of the column.
    static let presetWidths = [33, 50, 75, 100]

    /// A line that consists of exactly one picture.
    static func parse(_ line: String) -> WriterImageReference? {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        guard characters.count > 5, characters[0] == "!", characters[1] == "[" else { return nil }
        var index = 2
        var caption = ""
        while index < characters.count, characters[index] != "]" {
            if characters[index] == "\\", index + 1 < characters.count {
                caption.append(characters[index + 1])
                index += 2
                continue
            }
            caption.append(characters[index])
            index += 1
        }
        guard index + 1 < characters.count, characters[index] == "]", characters[index + 1] == "(" else { return nil }
        index += 2

        var source = ""
        if index < characters.count, characters[index] == "<" {
            index += 1
            while index < characters.count, characters[index] != ">" {
                source.append(characters[index])
                index += 1
            }
            guard index < characters.count else { return nil }
            index += 1
        } else {
            var depth = 0
            while index < characters.count, characters[index] != " " {
                if characters[index] == "(" { depth += 1 }
                if characters[index] == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                source.append(characters[index])
                index += 1
            }
        }
        while index < characters.count, characters[index] == " " { index += 1 }
        // An optional title ("…") is dropped; the caption is the alt text.
        if index < characters.count, characters[index] == "\"" {
            index += 1
            while index < characters.count, characters[index] != "\"" { index += 1 }
            index += 1
            while index < characters.count, characters[index] == " " { index += 1 }
        }
        guard !source.isEmpty, index < characters.count, characters[index] == ")" else { return nil }
        index += 1

        var width: Int?
        var plot: PlotSpec?
        let rest = String(characters[index...]).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            guard rest.hasPrefix("{"), rest.hasSuffix("}") else { return nil }
            let attributes = rest.dropFirst().dropLast().split(separator: " ")
            if attributes.contains(".plot") { plot = PlotSpec() }
            for attribute in attributes {
                let pair = attribute.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                if pair[0] == "width", pair[1].hasSuffix("%"), let value = Int(pair[1].dropLast()) {
                    width = max(5, min(100, value))
                } else {
                    plot?.read(pair[0], pair[1])
                }
            }
        }
        return WriterImageReference(source: source, caption: caption, width: width, plot: plot)
    }

    var markdown: String {
        let caption = caption
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: " ")
        let destination = source.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<\(source)>" : source
        var attributes = width.map { ["width=\($0)%"] } ?? []
        attributes += plot?.markdownAttributes ?? []
        return "![\(caption)](\(destination))" + (attributes.isEmpty ? "" : "{" + attributes.joined(separator: " ") + "}")
    }
}

/// The pictures of Writer Studio: files in `Documents/Bilder`, referenced from the Markdown relative to the
/// documents folder, so the stored `.md` files show them in other Markdown programs too.
enum WriterImageStore {
    static let folderName = "Bilder"
    /// Larger pictures are scaled down on import; that is still sharp on paper at full width.
    static let maxPixelSize = 3200
    /// The width of the editor's column in points; a picture's own size is measured against it.
    static let referenceColumnWidth: CGFloat = 680

    static var documentsDirectory: URL { WriterDocumentStore.defaultDirectory }

    static var directory: URL {
        let url = documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies a picture into the folder and returns its Markdown source. PNG and JPEG keep their file;
    /// other formats (HEIC, TIFF, GIF, …) and very large pictures become PNG or JPEG, which LaTeX can print.
    static func importImage(_ source: AttachmentStore.Source) throws -> String {
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

        let type = CGImageSourceGetType(imageSource) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let longestSide = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let id = UUID().uuidString

        if type == UTType.png.identifier || type == UTType.jpeg.identifier, longestSide <= maxPixelSize, orientation == 1 {
            let fileName = id + (type == UTType.png.identifier ? ".png" : ".jpg")
            let destination = directory.appendingPathComponent(fileName)
            switch source {
            case .file(let url): try FileManager.default.copyItem(at: url, to: destination)
            case .data(let data): try data.write(to: destination, options: .atomic)
            }
            return folderName + "/" + fileName
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide > 0 ? min(longestSide, maxPixelSize) : maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw AttachmentError.unreadable(name)
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let fileName = id + (hasAlpha ? ".png" : ".jpg")
        let format = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(fileName) as CFURL, format.identifier as CFString, 1, nil) else {
            throw AttachmentError.writeFailed
        }
        var imageProperties: [CFString: Any] = [:]
        if !hasAlpha { imageProperties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        // Keep the resolution, so a Retina screenshot stays at its size on screen.
        if let dpi = properties?[kCGImagePropertyDPIWidth] { imageProperties[kCGImagePropertyDPIWidth] = dpi }
        if let dpi = properties?[kCGImagePropertyDPIHeight] { imageProperties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, imageProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.writeFailed }
        return folderName + "/" + fileName
    }

    /// The file of a Markdown source, if it is on this Mac. Pictures on the web are not loaded.
    static func url(for source: String) -> URL? {
        let path = source.removingPercentEncoding ?? source
        if path.hasPrefix("file://") { return URL(string: source).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        if path.contains("://") { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : documentsDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The picture's size in points (pixels at its resolution).
    static func naturalSize(of url: URL) -> CGSize? {
        if let cached = sizes[url.path] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let dpi = max(72, properties[kCGImagePropertyDPIWidth] as? CGFloat ?? 72)
        let size = CGSize(width: width * 72 / dpi, height: height * 72 / dpi)
        sizes[url.path] = size
        return size
    }

    /// The picture's own width as a share of the column (at most all of it).
    static func naturalWidthFraction(of url: URL) -> CGFloat {
        guard let size = naturalSize(of: url) else { return 1 }
        return max(0.1, min(1, size.width / referenceColumnWidth))
    }

    /// A version for the screen, at most `maxDisplayPixels` on its longest side, at the picture's size in points.
    @MainActor
    static func displayImage(for source: String) -> NSImage? {
        guard let url = url(for: source) else { return nil }
        if let cached = images.object(forKey: url.path as NSString) { return cached }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil), let size = naturalSize(of: url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: size)
        images.setObject(image, forKey: url.path as NSString)
        return image
    }

    nonisolated(unsafe) private static var sizes: [String: CGSize] = [:]
    nonisolated(unsafe) private static let images = NSCache<NSString, NSImage>()

    /// The sources of all pictures in a document.
    static func sources(in markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").compactMap { WriterImageReference.parse($0)?.source }
    }

    /// Replaces the sources of pictures (for exports, where the pictures sit in a folder next to the file).
    static func rewriteSources(in markdown: String, _ newSource: (String) -> String?) -> String {
        markdown.components(separatedBy: "\n").map { line in
            guard var reference = WriterImageReference.parse(line), let source = newSource(reference.source) else { return line }
            reference.source = source
            return reference.markdown
        }.joined(separator: "\n")
    }

    /// Deletes the pictures of a deleted document that no other document uses (with a plot's dark and PDF versions).
    static func removeUnused(_ sources: [String], stillUsedIn documents: [String]) {
        let used = Set(documents.flatMap(Self.sources(in:)))
        for source in Set(sources) where source.hasPrefix(folderName + "/") && !used.contains(source) {
            for variant in [source, darkVariant(of: source), pdfVariant(of: source)] {
                if let url = url(for: variant) { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    // MARK: Plots

    /// "Bilder/plot-1.png" → "Bilder/plot-1-dark.png": the version for the dark sheet.
    static func darkVariant(of source: String) -> String {
        let path = source as NSString
        return path.deletingPathExtension + "-dark." + (path.pathExtension.isEmpty ? "png" : path.pathExtension)
    }

    /// "Bilder/plot-1.png" → "Bilder/plot-1.pdf": the vector version for LaTeX.
    static func pdfVariant(of source: String) -> String {
        (source as NSString).deletingPathExtension + ".pdf"
    }

    /// Copies a freshly drawn plot into the pictures folder; returns the Markdown source of its light PNG.
    static func storePlot(_ output: PlotRenderer.Output) throws -> String {
        let name = "plot-" + UUID().uuidString.prefix(13).lowercased()
        let folder = directory
        try FileManager.default.copyItem(at: output.light, to: folder.appendingPathComponent(name + ".png"))
        try? FileManager.default.copyItem(at: output.dark, to: folder.appendingPathComponent(name + "-dark.png"))
        try? FileManager.default.copyItem(at: output.pdf, to: folder.appendingPathComponent(name + ".pdf"))
        return folderName + "/" + name + ".png"
    }

    /// The file LaTeX should print for a picture: a plot's PDF when there is one.
    static func printURL(for reference: WriterImageReference) -> URL? {
        if reference.plot != nil, let pdf = url(for: pdfVariant(of: reference.source)) { return pdf }
        return url(for: reference.source)
    }
}

/// A picture in the editor: an attachment on a paragraph of its own (block `.image`). Never changed in place;
/// a new size or caption replaces the attachment, so undo restores the old one.
final class WriterImageAttachment: NSTextAttachment {
    private(set) var reference = WriterImageReference(source: "", caption: "", width: nil)

    convenience init(reference: WriterImageReference) {
        self.init(data: nil, ofType: nil)
        self.reference = reference
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterImageCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterImageCell()
    }
}
