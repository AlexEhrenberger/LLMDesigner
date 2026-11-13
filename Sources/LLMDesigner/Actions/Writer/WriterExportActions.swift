import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterMoreActions() {
        register(WriterExportAction.self)
        registerWriterExtraActions()
    }
}

/// The folder an agent may write to without asking. Everything else is a place the person has to agree to.
enum ActionExportFolder {
    private static let settingsKey = "actionExportFolder"

    @MainActor static func url(settings: LibrarySettings) -> URL {
        if let path = settings.string(forKey: settingsKey), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return AppLibrary.defaultFolder.appendingPathComponent("Exporte", isDirectory: true)
    }

    @MainActor static func set(_ url: URL?, settings: LibrarySettings) {
        settings.set(url?.path, forKey: settingsKey)
    }

    /// Whether a path lies in the folder, with `..` and links followed, so a path can't only seem to.
    static func contains(_ path: URL, folder: URL) -> Bool {
        func resolved(_ url: URL) -> String {
            // A file that doesn't exist yet resolves through its folder.
            let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            return directory.appendingPathComponent(url.lastPathComponent).path
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let target = resolved(path.standardizedFileURL)
        return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// `~` and relative paths as the person typing them means them.
    static func expanded(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// A free file name in the folder.
    static func freeFile(named name: String, extension fileExtension: String, in folder: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent(safe).appendingPathExtension(fileExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safe) \(number)").appendingPathExtension(fileExtension)
            number += 1
        }
        return candidate
    }
}

struct WriterExportAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var format: String
        var path: String?
        var overwrite: Bool?
    }
    struct Output: Encodable, Sendable {
        var path: String
        var bytes: Int
    }

    static let formats: [String: WriterExportFormat] = ["pdf": .pdf, "latex": .latex, "markdown": .markdown, "plainMarkdown": .plainMarkdown]
    static let descriptor = ActionDescriptor(
        id: "writer.export", summary: "Exportiert ein Dokument als Datei", kind: .destructive, security: .outbound,
        input: .object([
            "doc": .string("Dokument (ID oder Titel)"),
            "format": .choice(["pdf", "latex", "markdown", "plainMarkdown"], "Dateiformat"),
            "path": .string("Zieldatei; ohne Angabe im Exportordner. Andere Orte brauchen eine Freigabe."),
            "overwrite": .boolean("Eine vorhandene Datei ersetzen"),
        ], required: ["doc", "format"]),
        output: .freeObject(), example: "llmd writer export --doc Bericht --format pdf", groups: ["core", "writer.core"]
    )

    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let document = try context.app.actionDocument(args.doc)
        let folder = ActionExportFolder.url(settings: context.app.settings)
        let inFolder = args.path.map { ActionExportFolder.contains(ActionExportFolder.expanded($0), folder: folder) } ?? true
        return ActionPreflight(readsUntrusted: document.isForeign, isInSafePlace: inFolder, target: args.path ?? folder.path, detail: document.displayTitle)
    }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocument(args.doc)
        guard let format = formats[args.format] else { throw RPCError.invalidParams("Unbekanntes Format „\(args.format)“.") }
        let fileExtension: String = switch format {
        case .pdf: "pdf"
        case .latex: "tex"
        case .markdown, .plainMarkdown: "md"
        }
        let folder = ActionExportFolder.url(settings: app.settings)
        let url: URL
        if let path = args.path {
            url = ActionExportFolder.expanded(path)
            guard args.overwrite == true || !FileManager.default.fileExists(atPath: url.path) else {
                throw RPCError.invalidTarget("Die Datei gibt es schon. Mit overwrite ersetzen oder anderen Pfad wählen: \(url.path)")
            }
        } else {
            url = ActionExportFolder.freeFile(named: document.displayTitle, extension: fileExtension, in: folder)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let input = await app.prepareExport(of: document)
        switch format {
        case .pdf:
            guard let engine = LaTeXEngine.locate() else { throw RPCError.unavailable(PDFExportError.noEngine.localizedDescription) }
            let current = input.document
            let pdf = try await engine.makePDF(parts: [input.part], paper: app.pdfPaperSize, typeface: current.pageFormat.font(current.font),
                                               format: current.pageFormat, design: current.pageDesign)
            try pdf.write(to: url, options: .atomic)
        case .latex, .markdown, .plainMarkdown:
            do {
                try app.writeTextExport(input, as: format, paper: app.pdfPaperSize, to: url)
            } catch {
                throw RPCError.invalidTarget(error.localizedDescription)
            }
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(path: url.path, bytes: bytes)
    }
}
