import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Reads a PDF page by page: the text layer, or the recognised text of a page that is only a picture (a scan), and
/// the figures on each page, cut out as pictures.
enum PDFReader {
    struct Result {
        var text: String
        var recognizedPages: [Int]
        var figures: [DocumentFigure]
    }

    /// A page with less text than this is taken for a scan and recognised.
    static let minimumPageText = 25

    static func read(_ pdf: PDFDocument, documentID: UUID, progress: DocumentStore.Progress) -> Result {
        var pages: [String] = []
        var recognized: [Int] = []
        var figures: [DocumentFigure] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let number = index + 1
            progress(pdf.pageCount > 1 ? "Seite \(number) von \(pdf.pageCount) …" : "Text wird gelesen …")
            let geometry = PageGeometry(page)
            var text = page.string ?? ""
            var lines = geometry.textLines(of: page)
            var isScan = false
            if text.filter({ !$0.isWhitespace }).count < minimumPageText {
                progress("Seite \(number) wird erkannt …")
                let found = TextRecognizer.lines(on: page, geometry: geometry)
                if !found.isEmpty {
                    lines = found
                    text = found.map(\.text).joined(separator: "\n")
                    recognized.append(number)
                    isScan = true
                }
            }
            if figures.count < DocumentStore.maxFigures {
                for area in FigureFinder.areas(on: page, geometry: geometry, textLines: lines, isScan: isScan, pageText: text) {
                    guard figures.count < DocumentStore.maxFigures else { break }
                    let figureNumber = figures.count + 1
                    let fileName = "\(documentID.uuidString)-abb\(figureNumber).jpg"
                    guard let size = FigureFinder.save(area, of: page, geometry: geometry, to: DocumentStore.url(fileName)) else { continue }
                    figures.append(DocumentFigure(
                        number: figureNumber, page: number, caption: FigureFinder.caption(for: area, in: lines),
                        imageFileName: fileName, width: size.width, height: size.height
                    ))
                }
            }
            let tidy = DocumentText.tidy(text)
            pages.append(tidy.isEmpty ? "[Seite \(number)]" : "[Seite \(number)]\n\(tidy)")
        }
        return Result(text: pages.joined(separator: "\n\n"), recognizedPages: recognized, figures: figures)
    }
}

/// A line of text on a page, in the page's drawing space (points, origin bottom left, rotation applied).
struct PageLine: Sendable {
    var text: String
    var rect: CGRect
}

/// Where things are on a page as it is drawn: PDFKit applies the page's rotation and box origin when drawing.
struct PageGeometry {
    let size: CGSize
    let transform: CGAffineTransform

    init(_ page: PDFPage) {
        transform = page.transform(for: .mediaBox)
        let box = page.bounds(for: .mediaBox).applying(transform)
        size = CGSize(width: abs(box.width), height: abs(box.height))
    }

    func textLines(of page: PDFPage) -> [PageLine] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return PageLine(text: text, rect: line.bounds(for: page).applying(transform).standardized)
        }
    }

    /// The page drawn at `scale` (1 = 72 dpi), optionally only the part `area` of it, on white.
    func render(_ page: PDFPage, scale: CGFloat, area: CGRect? = nil, gray: Bool = false) -> CGImage? {
        let region = area ?? CGRect(origin: .zero, size: size)
        let width = Int((region.width * scale).rounded(.up)), height = Int((region.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height < 40_000_000 else { return nil }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

/// Text recognition on the device (Vision), for pages that are only a picture.
enum TextRecognizer {
    static func lines(on page: PDFPage, geometry: PageGeometry) -> [PageLine] {
        // About 220 dpi: small print of a scan still comes out.
        guard let picture = geometry.render(page, scale: 3) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: picture).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * geometry.size.width, y: box.minY * geometry.size.height,
                              width: box.width * geometry.size.width, height: box.height * geometry.size.height)
            return PageLine(text: text, rect: rect)
        }
    }
}

/// Finds figures on a page without knowing how the PDF is built: the page is drawn without its text, and what is
/// left in larger patches is a picture or a drawing. That finds photos and vector charts alike.
enum FigureFinder {
    /// One cell of the search grid, in points (about 1 mm).
    private static let cell: CGFloat = 3
    /// Ink closer than this many cells belongs to one figure (bars of a chart, a legend).
    private static let reach = 4
    private static let minimumWidth: CGFloat = 54
    private static let minimumHeight: CGFloat = 40
    private static let minimumShare: CGFloat = 0.015

    static func areas(on page: PDFPage, geometry: PageGeometry, textLines: [PageLine], isScan: Bool, pageText: String) -> [CGRect] {
        let size = geometry.size
        guard size.width > 0, size.height > 0,
              let image = geometry.render(page, scale: 1, gray: true),
              let ink = inkCells(image, size: size, hiding: textLines, threshold: isScan ? 170 : 236) else { return [] }
        let columns = ink.columns, rows = ink.rows

        // Grow the ink by `reach`, then find connected patches; their extent is measured on the ink itself.
        var grown = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns where ink.cells[row * columns + column] {
                for r in max(0, row - reach)...min(rows - 1, row + reach) {
                    for c in max(0, column - reach)...min(columns - 1, column + reach) { grown[r * columns + c] = true }
                }
            }
        }
        var label = [Int](repeating: -1, count: columns * rows)
        var boxes: [CGRect] = []
        var counts: [Int] = []
        for start in 0..<(columns * rows) where grown[start] && label[start] < 0 {
            let id = boxes.count
            var minColumn = Int.max, maxColumn = Int.min, minRow = Int.max, maxRow = Int.min, count = 0
            var stack = [start]
            label[start] = id
            while let index = stack.popLast() {
                let row = index / columns, column = index % columns
                if ink.cells[index] {
                    count += 1
                    minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
                    minRow = min(minRow, row); maxRow = max(maxRow, row)
                }
                for (r, c) in [(row - 1, column), (row + 1, column), (row, column - 1), (row, column + 1)]
                where r >= 0 && r < rows && c >= 0 && c < columns {
                    let next = r * columns + c
                    if grown[next] && label[next] < 0 { label[next] = id; stack.append(next) }
                }
            }
            boxes.append(count == 0 ? .null : CGRect(x: CGFloat(minColumn) * cell, y: CGFloat(minRow) * cell,
                                                    width: CGFloat(maxColumn - minColumn + 1) * cell, height: CGFloat(maxRow - minRow + 1) * cell))
            counts.append(count)
        }

        let pageArea = size.width * size.height
        let hasMuchText = pageText.count > 200
        var found = zip(boxes, counts).compactMap { box, count -> CGRect? in
            guard !box.isNull, box.width >= minimumWidth, box.height >= minimumHeight, box.width * box.height >= pageArea * minimumShare else { return nil }
            // Lines and empty frames (a table's border) have little ink for their size.
            let cells = (box.width / cell) * (box.height / cell)
            guard Double(count) >= Double(cells) * 0.04, count >= 40 else { return nil }
            // A coloured page background or the paper of a scan is not a figure.
            if box.width * box.height > pageArea * 0.85 && (isScan || hasMuchText) { return nil }
            return box.intersection(CGRect(origin: .zero, size: size))
        }
        found = merged(found)
        // Top to bottom, then left to right (origin bottom left).
        return found.sorted { abs($0.maxY - $1.maxY) > 12 ? $0.maxY > $1.maxY : $0.minX < $1.minX }
    }

    /// Writes the area as JPEG (about 180 dpi, at most 1600 px). Returns its size in pixels.
    static func save(_ area: CGRect, of page: PDFPage, geometry: PageGeometry, to url: URL) -> (width: Int, height: Int)? {
        let padded = area.insetBy(dx: -6, dy: -6).intersection(CGRect(origin: .zero, size: geometry.size))
        let scale = min(2.5, CGFloat(AttachmentStore.maxPixelSize) / max(padded.width, padded.height))
        guard let image = geometry.render(page, scale: scale, area: padded) else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (image.width, image.height)
    }

    private static let captionPattern = try! NSRegularExpression(
        pattern: #"^\s*(abb\.|abbildung|bild|grafik|diagramm|fig\.|figure|tab\.|tabelle|table)\s*[0-9IVX]"#, options: [.caseInsensitive]
    )

    static func isCaption(_ text: String) -> Bool {
        captionPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The caption line closest below the figure, else closest above it.
    static func caption(for area: CGRect, in lines: [PageLine]) -> String? {
        let candidates = lines.filter { isCaption($0.text) && $0.rect.maxX > area.minX && $0.rect.minX < area.maxX }
        let below = candidates.filter { $0.rect.maxY <= area.minY + 4 && area.minY - $0.rect.maxY < 50 }.max { $0.rect.maxY < $1.rect.maxY }
        let above = candidates.filter { $0.rect.minY >= area.maxY - 4 && $0.rect.minY - area.maxY < 50 }.min { $0.rect.minY < $1.rect.minY }
        guard let line = below ?? above else { return nil }
        return String(line.text.prefix(200))
    }

    // MARK: Private

    private struct InkGrid {
        var cells: [Bool]
        var columns: Int
        var rows: Int
    }

    /// Cells with dark pixels, the text lines left out. Row 0 is the bottom of the page.
    private static func inkCells(_ image: CGImage, size: CGSize, hiding lines: [PageLine], threshold: UInt8) -> InkGrid? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let width = image.width, height = image.height, stride = image.bytesPerRow
        let columns = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
        var hidden = [Bool](repeating: false, count: width * height)
        for line in lines {
            let rect = line.rect.insetBy(dx: -1.5, dy: -1.5)
            let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX.rounded(.up)))
            let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(rect.maxY.rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 { hidden[y * width + x] = true } }
        }
        var cells = [Bool](repeating: false, count: columns * rows)
        for memoryRow in 0..<height {
            // The bitmap's first row is the top of the page.
            let y = height - 1 - memoryRow
            let row = min(rows - 1, Int(CGFloat(y) / cell))
            let base = memoryRow * stride
            for x in 0..<width where bytes[base + x] < threshold && !hidden[y * width + x] {
                cells[row * columns + min(columns - 1, Int(CGFloat(x) / cell))] = true
            }
        }
        return InkGrid(cells: cells, columns: columns, rows: rows)
    }

    /// Joins areas that overlap or almost touch.
    private static func merged(_ areas: [CGRect]) -> [CGRect] {
        var result = areas
        var changed = true
        while changed {
            changed = false
            outer: for i in result.indices {
                for j in result.indices where j > i && result[i].insetBy(dx: -6, dy: -6).intersects(result[j]) {
                    result[i] = result[i].union(result[j])
                    result.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }
}
