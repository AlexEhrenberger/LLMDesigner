import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Emoji in exported PDFs. XeTeX (Tectonic) can't draw Apple Color Emoji, so each emoji is written as
/// `\llmdemoji{<name>}` and drawn here as a PNG next to the LaTeX source.
enum LaTeXEmoji {
    /// A file name made of the emoji's code points, e.g. `llmdemoji-1F44D-1F3FD`: letters, digits and hyphens only,
    /// so it is safe both in LaTeX and on disk.
    static func name(_ character: Character) -> String {
        "llmdemoji-" + character.unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: "-")
    }

    static func character(fromName name: String) -> Character? {
        guard name.hasPrefix("llmdemoji-") else { return nil }
        let scalars = name.dropFirst("llmdemoji-".count).split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        guard !scalars.isEmpty else { return nil }
        let string = String(String.UnicodeScalarView(scalars))
        return string.count == 1 ? string.first : nil
    }

    /// Draws every emoji the source refers to as `<name>.png` in `directory`.
    static func renderPictures(in source: String, to directory: URL) {
        let pattern = try! NSRegularExpression(pattern: #"\\llmdemoji\{(llmdemoji-[0-9A-F-]+)\}"#)
        let names = Set(pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })
        for name in names {
            guard let character = character(fromName: name), let png = png(character) else { continue }
            try? png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    /// The emoji on a transparent square, large enough to stay sharp in print. Core Graphics instead of AppKit,
    /// because the export runs off the main thread.
    static func png(_ character: Character, size: CGFloat = 160) -> Data? {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size * 0.8, nil)
        let text = NSAttributedString(string: String(character), attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let side = Int(size)
        guard bounds.width > 0,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
