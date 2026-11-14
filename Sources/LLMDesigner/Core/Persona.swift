import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A character the user chats with as if with a person: picture, name, life story and manner. A chat runs either
/// with one persona or with skills, never both. Each persona has its own folder (`PersonaStore`) for the picture,
/// its files and, later, its memories (Thalamus).
struct Persona: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Who the persona is: life story, background, what makes them who they are.
    var biography: String
    /// How the persona is and reacts: temperament, way of speaking, quirks.
    var behavior: String
    /// Profile picture in the persona's folder. A new picture gets a new name, so cached images notice the change.
    var avatarFileName: String?
    /// Colour taken from the picture, for the halo in conversation mode.
    var tint: UInt32?
    /// Qwen TTS voice; nil speaks with the voice from the settings.
    var voice: String?
    /// How the voice should sound, sent to Qwen TTS as `instructions`, e.g. "ruhig und warm".
    var voiceStyle: String?
    /// Files the persona can search and read while answering.
    var files: [PersonaFile]?
    var createdAt = Date()
    var updatedAt = Date()

    static let symbol = "person.crop.circle"

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unbenannte Persona" : trimmed
    }

    /// Up to two letters for a persona without a picture.
    var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// The first sentence of the biography, for lists.
    var tagline: String? {
        let text = biography.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty else { return nil }
        if let end = line.firstIndex(where: { ".!?".contains($0) }), line.distance(from: line.startIndex, to: end) > 12 {
            return String(line[...end])
        }
        return line
    }

    var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && biography.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && behavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && avatarFileName == nil && (files ?? []).isEmpty
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query) || biography.localizedStandardContains(query)
            || behavior.localizedStandardContains(query)
    }

    static func sorted(_ personas: [Persona]) -> [Persona] {
        personas.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// A file the user gave a persona. The original lies in the persona's `files` folder, its text in `text`.
struct PersonaFile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// Name as the user added it; the model asks for the file by this name.
    var name: String
    /// File name in the persona's `files` folder.
    var storedName: String
    var byteCount: Int
    /// Length of the extracted text.
    var characterCount: Int
    var addedAt = Date()
}

enum PersonaPrompt {
    /// The system prompt of a chat with a persona: the general one from the settings, then who the persona is.
    static func compose(base: String, persona: Persona) -> String {
        [base, instructions(for: persona)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func instructions(for persona: Persona) -> String {
        let name = persona.displayName
        var parts = [
            "Du bist \(name). Du führst dieses Gespräch als \(name): in der ersten Person, aus deiner eigenen Sicht und auf deine eigene Art. Bleib in deiner Rolle.",
        ]
        let biography = persona.biography.trimmingCharacters(in: .whitespacesAndNewlines)
        if !biography.isEmpty { parts.append("## Wer du bist\n\(biography)") }
        let behavior = persona.behavior.trimmingCharacters(in: .whitespacesAndNewlines)
        if !behavior.isEmpty { parts.append("## Wie du dich verhältst\n\(behavior)") }
        return parts.joined(separator: "\n\n")
    }
}

enum PersonaError: LocalizedError {
    case unreadableImage(String)
    case unsupportedFile(String)
    case noText(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): "„\(name)“ ist kein Bild, das die App lesen kann."
        case .unsupportedFile(let name): "„\(name)“ kann die App nicht als Text lesen. Möglich sind z. B. PDF, Word, RTF, Text, Markdown und HTML."
        case .noText(let name): "In „\(name)“ steht kein lesbarer Text (bei einem gescannten PDF fehlt die Texterkennung)."
        case .writeFailed(let name): "„\(name)“ konnte nicht gespeichert werden."
        }
    }
}

/// Every persona has a folder in the library's `Personas` folder: `persona.json`, the profile picture, `files/` with the
/// originals of its files and `text/` with their extracted text.
enum PersonaStore {
    static var directory: URL { AppLibrary.current.folder("Personas") }

    static let avatarPixelSize = 512

    static func folder(for id: Persona.ID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func avatarURL(of persona: Persona) -> URL? {
        persona.avatarFileName.map { folder(for: persona.id).appendingPathComponent($0) }
    }

    static func fileURL(_ file: PersonaFile, of personaID: Persona.ID) -> URL {
        folder(for: personaID).appendingPathComponent("files", isDirectory: true).appendingPathComponent(file.storedName)
    }

    static func textURL(_ file: PersonaFile, of personaID: Persona.ID) -> URL {
        folder(for: personaID).appendingPathComponent("text", isDirectory: true).appendingPathComponent("\(file.id.uuidString).txt")
    }

    // MARK: Personas

    static func loadAll() -> [Persona] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> Persona? in
            let url = folder.appendingPathComponent("persona.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try decoder.decode(Persona.self, from: Data(contentsOf: url))
            } catch {
                print("LLMDesigner: Persona \(folder.lastPathComponent) konnte nicht gelesen werden: \(error)")
                return nil
            }
        }
    }

    static func save(_ persona: Persona) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = folder(for: persona.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(persona).write(to: folder.appendingPathComponent("persona.json"), options: .atomic)
        } catch {
            print("LLMDesigner: Persona \(persona.id) konnte nicht gespeichert werden: \(error)")
        }
    }

    /// Removes the persona's folder with its picture and files.
    static func delete(_ id: Persona.ID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    static func removeItem(named name: String, of id: Persona.ID) {
        try? FileManager.default.removeItem(at: folder(for: id).appendingPathComponent(name))
    }

    // MARK: Profile picture

    /// Cuts the middle square out of the picture, scales it to `avatarPixelSize` and saves it as JPEG.
    /// Returns the new file name and the picture's dominant colour.
    static func importAvatar(_ source: AttachmentStore.Source, for id: Persona.ID) throws -> (fileName: String, tint: UInt32?) {
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
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: avatarPixelSize * 3,
        ]
        guard let imageSource, CGImageSourceGetCount(imageSource) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let square = squared(image, size: avatarPixelSize) else { throw PersonaError.unreadableImage(name) }

        let folder = folder(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = "avatar-\(UUID().uuidString.prefix(8)).jpg"
        guard let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent(fileName) as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PersonaError.writeFailed(name) }
        CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PersonaError.writeFailed(name) }
        return (fileName, dominantColor(of: square))
    }

    /// The middle square of the picture at `size` × `size` pixels, transparency flattened onto black.
    private static func squared(_ image: CGImage, size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        let side = Double(min(image.width, image.height))
        let scale = Double(size) / side
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Portraits keep the upper part, where the face usually is.
        let y = height > width ? Double(size) - height + (height - Double(size)) * 0.25 : (Double(size) - height) / 2
        context.draw(image, in: CGRect(x: (Double(size) - width) / 2, y: y, width: width, height: height))
        return context.makeImage()
    }

    /// The most colourful average of the picture, brightened so it glows on black.
    private static func dominantColor(of image: CGImage) -> UInt32? {
        let side = 24
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var red = 0.0, green = 0.0, blue = 0.0, weights = 0.0
        for index in 0..<(side * side) {
            let r = Double(pixels[index * 4]) / 255, g = Double(pixels[index * 4 + 1]) / 255, b = Double(pixels[index * 4 + 2]) / 255
            let maximum = max(r, g, b), minimum = min(r, g, b)
            // Colourful, not too dark pixels count most; grey backgrounds hardly at all.
            let weight = (maximum - minimum) * maximum + 0.02
            red += r * weight
            green += g * weight
            blue += b * weight
            weights += weight
        }
        guard weights > 0 else { return nil }
        let color = NSColor(srgbRed: red / weights, green: green / weights, blue: blue / weights, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // An almost grey picture gets the app's violet instead of a dull grey.
        guard saturation > 0.12 else { return nil }
        let glowing = NSColor(hue: hue, saturation: min(0.75, max(0.45, saturation)), brightness: 0.98, alpha: 1)
        guard let rgb = glowing.usingColorSpace(.sRGB) else { return nil }
        let r = UInt32((rgb.redComponent * 255).rounded()), g = UInt32((rgb.greenComponent * 255).rounded())
        let b = UInt32((rgb.blueComponent * 255).rounded())
        return r << 16 | g << 8 | b
    }

    // MARK: Files

    /// Copies a file into the persona's folder and stores its text. `takenNames` keeps names unique within the persona.
    static func importFile(_ url: URL, for id: Persona.ID, takenNames: Set<String>) throws -> PersonaFile {
        let originalName = url.lastPathComponent
        let text = try DocumentText.extract(from: url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PersonaError.noText(originalName) }

        var name = originalName
        if takenNames.contains(name) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var number = 2
            repeat {
                name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
                number += 1
            } while takenNames.contains(name)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let file = PersonaFile(name: name, storedName: name, byteCount: size, characterCount: text.count)

        let original = fileURL(file, of: id)
        let textFile = textURL(file, of: id)
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: textFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.removeItem(at: original) }
            try FileManager.default.copyItem(at: url, to: original)
            try text.write(to: textFile, atomically: true, encoding: .utf8)
        } catch {
            throw PersonaError.writeFailed(originalName)
        }
        return file
    }

    static func removeFile(_ file: PersonaFile, of id: Persona.ID) {
        try? FileManager.default.removeItem(at: fileURL(file, of: id))
        try? FileManager.default.removeItem(at: textURL(file, of: id))
    }

    static func text(of file: PersonaFile, personaID: Persona.ID) -> String {
        (try? String(contentsOf: textURL(file, of: personaID), encoding: .utf8)) ?? ""
    }
}

/// Reads the text of a document: PDF, Word, RTF, OpenDocument, HTML or any plain-text format.
enum DocumentText {
    static func extract(from url: URL) throws -> String {
        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw PersonaError.unsupportedFile(name) }
            let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            return tidy(pages.joined(separator: "\n\n"))
        }
        if type?.conforms(to: .html) == true {
            guard let data = try? Data(contentsOf: url) else { throw PersonaError.unsupportedFile(name) }
            let html = String(decoding: data, as: UTF8.self)
            let page = HTMLText.readableText(fromHTML: html)
            return [page.title, page.text].compactMap { $0 }.joined(separator: "\n\n")
        }
        let richTypes: [UTType] = [.rtf, .rtfd, .flatRTFD, UTType("org.openxmlformats.wordprocessingml.document"),
                                   UTType("com.microsoft.word.doc"), UTType("org.oasis-open.opendocument.text")].compactMap { $0 }
        if let type, richTypes.contains(where: type.conforms(to:)) {
            guard let document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw PersonaError.unsupportedFile(name)
            }
            return tidy(document.string)
        }
        // Everything else counts as text if it decodes and has no binary zeros.
        guard let data = try? Data(contentsOf: url), !data.prefix(8_192).contains(0) else { throw PersonaError.unsupportedFile(name) }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) {
            return tidy(text)
        }
        throw PersonaError.unsupportedFile(name)
    }

    /// Unifies line breaks and drops runs of empty lines.
    static func tidy(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{000C}", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
