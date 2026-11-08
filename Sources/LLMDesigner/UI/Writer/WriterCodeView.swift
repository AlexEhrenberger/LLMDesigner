import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The code view of Writer Studio: the document as Markdown (what is stored; changes go straight into the document)
/// and as the LaTeX its PDF is set from. The LaTeX can be changed by hand when the PDF comes out wrong; those changes
/// are for the PDF made here only, the document stays as it is.
@MainActor @Observable
final class WriterCodeModel {
    enum Mode: String, CaseIterable, Identifiable {
        case markdown, latex
        var id: String { rawValue }
        var label: String { self == .markdown ? "Markdown" : "LaTeX" }
    }

    var mode: Mode = .markdown
    /// The document the LaTeX belongs to and the Markdown it was made from.
    private(set) var documentID: WriterDocument.ID?
    private(set) var latexSource: String?
    var latex = ""
    var isLaTeXEdited: Bool { latexSource != nil && latex != latexSource }
    private(set) var figures: [URL] = []
    private(set) var pdf: Data?
    private(set) var isBusy = false
    private(set) var error: String?
    /// The line of the LaTeX the engine complained about.
    private(set) var errorLine: Int?
    /// Asks the editor to show a line; the counter makes the same line count again.
    private(set) var reveal: (line: Int, token: Int)?
    private var compileTask: Task<Void, Never>?

    func isCurrent(for document: WriterDocument) -> Bool {
        documentID == document.id && latexSource != nil && madeFrom == document.markdown
    }

    private var madeFrom: String?

    /// The LaTeX of the document as the PDF export makes it, set at once. Formulas LaTeX refuses are printed as code,
    /// as the export does, so the starting point always works when anything can.
    func generate(_ document: WriterDocument, app: AppModel) {
        compileTask?.cancel()
        isBusy = true
        error = nil
        errorLine = nil
        let paper = app.pdfPaperSize
        compileTask = Task {
            let input = await app.prepareExport(of: document)
            let current = input.document
            func source(_ math: LaTeXWriter.MathMode) -> String {
                LaTeXWriter.document(parts: [input.part], paper: paper, math: math, typeface: current.pageFormat.font(current.font),
                                     format: current.pageFormat, design: current.pageDesign)
            }
            let images = Array(input.printFigures.values)
            documentID = document.id
            madeFrom = document.markdown
            figures = images
            pdf = nil
            guard let engine = LaTeXEngine.locate() else {
                setSource(source(.native))
                error = PDFExportError.noEngine.localizedDescription
                isBusy = false
                return
            }
            var firstError: Error?
            for math in LaTeXWriter.MathMode.allCases {
                let text = source(math)
                do {
                    let data = try await engine.compile(text, images: images)
                    guard !Task.isCancelled else { return }
                    setSource(text)
                    pdf = data
                    isBusy = false
                    return
                } catch {
                    if Task.isCancelled { return }
                    firstError = firstError ?? error
                }
            }
            setSource(source(.native))
            show(firstError)
            isBusy = false
        }
    }

    private func setSource(_ text: String) {
        latexSource = text
        latex = text
    }

    /// Sets the LaTeX as it stands now (⌘↩).
    func compile() {
        guard !latex.isEmpty else { return }
        guard let engine = LaTeXEngine.locate() else {
            error = PDFExportError.noEngine.localizedDescription
            return
        }
        compileTask?.cancel()
        isBusy = true
        error = nil
        errorLine = nil
        let text = latex
        let images = figures
        compileTask = Task {
            do {
                let data = try await engine.compile(text, images: images)
                guard !Task.isCancelled else { return }
                pdf = data
            } catch {
                if Task.isCancelled { return }
                show(error)
            }
            isBusy = false
        }
    }

    private func show(_ error: Error?) {
        let message = error?.localizedDescription ?? "LaTeX konnte das Dokument nicht setzen."
        self.error = message
        errorLine = Self.line(in: message)
    }

    /// The line an engine's message points to: Tectonic's "export.tex:123:", TeX's "l.123".
    static func line(in message: String) -> Int? {
        for pattern in [#"export\.tex:(\d+)"#, #"\bl\.(\d+)"#] {
            if let match = message.range(of: pattern, options: .regularExpression) {
                let digits = message[match].filter(\.isNumber)
                if let line = Int(digits), line > 0 { return line }
            }
        }
        return nil
    }

    func revealErrorLine() {
        guard let errorLine else { return }
        reveal = (errorLine, (reveal?.token ?? 0) + 1)
    }

    func savePDF(title: String, app: AppModel) {
        guard let pdf else { return }
        Task {
            guard let url = await app.askForDestination(fileName: title, type: .pdf) else { return }
            do {
                try pdf.write(to: url, options: .atomic)
                if app.pdfOpenAfterExport { NSWorkspace.shared.open(url) }
            } catch {
                app.exportError = error.localizedDescription
            }
        }
    }

    func saveLaTeX(title: String, app: AppModel) {
        let text = latex
        let images = figures
        Task {
            guard let url = await app.askForDestination(fileName: title, type: UTType(filenameExtension: "tex") ?? .plainText) else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                // The pictures go next to the file, where the LaTeX looks for them.
                let folder = url.deletingLastPathComponent()
                for image in Set(images) where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(image.lastPathComponent).path) {
                    try? FileManager.default.copyItem(at: image, to: folder.appendingPathComponent(image.lastPathComponent))
                }
            } catch {
                app.exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Toolbar

/// Above the code: Markdown or LaTeX, and what can be done with each.
struct WriterCodeToolbar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: WriterCodeModel
    let document: WriterDocument

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.mode) {
                ForEach(WriterCodeModel.Mode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(model.mode == .markdown
                 ? "So ist das Dokument gespeichert. Änderungen gehen direkt ins Dokument."
                 : "Daraus entsteht das PDF. Änderungen gelten nur für dieses PDF, das Dokument bleibt, wie es ist.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if model.mode == .latex {
                if model.isBusy { ProgressView().controlSize(.small) }
                Button {
                    model.generate(document, app: app)
                } label: { Label("Neu erzeugen", systemImage: "arrow.clockwise") }
                    .help("Das LaTeX neu aus dem Dokument erzeugen – eigene Änderungen am LaTeX gehen dabei verloren")
                Button {
                    model.compile()
                } label: { Label("Setzen", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Das LaTeX setzen und die Vorschau erneuern (⌘↩)")
                    .disabled(model.isBusy || model.latex.isEmpty)
                Menu {
                    Button("PDF sichern …") { model.savePDF(title: document.displayTitle, app: app) }
                        .disabled(model.pdf == nil)
                    Button("LaTeX sichern …") { model.saveLaTeX(title: document.displayTitle, app: app) }
                        .disabled(model.latex.isEmpty)
                } label: { Label("Sichern", systemImage: "square.and.arrow.down") }
                    .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
        .padding(.horizontal, 16)
    }
}

// MARK: - The view

struct WriterCodeView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: WriterCodeModel
    let document: WriterDocument

    var body: some View {
        Group {
            switch model.mode {
            case .markdown: MarkdownSourceEditor(document: document)
            case .latex: latexView
            }
        }
        .background(Theme.background)
    }

    private var latexView: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.isLaTeXEdited, !model.isCurrent(for: document), model.latex != "" {
                    notice("Das Dokument hat sich geändert. „Neu erzeugen“ übernimmt das, deine Änderungen am LaTeX gehen dabei verloren.")
                }
                CodeTextView(text: $model.latex, language: .latex, reveal: model.reveal)
            }
            .frame(minWidth: 320)
            preview
                .frame(minWidth: 280)
        }
        .onAppear(perform: generateIfNeeded)
        .onChange(of: document.id) { generateIfNeeded() }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("LaTeX meldet einen Fehler", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    ScrollView {
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    if let line = model.errorLine {
                        Button("Zu Zeile \(line) springen") { model.revealErrorLine() }
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warning.opacity(0.08))
            }
            if let pdf = model.pdf {
                PDFPreview(data: pdf)
            } else {
                VStack(spacing: 8) {
                    if model.isBusy {
                        ProgressView()
                        Text("LaTeX setzt das Dokument …")
                    } else {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 28))
                        Text("Noch keine Vorschau. „Setzen“ (⌘↩) macht das PDF.")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.1))
    }

    /// The LaTeX is made when it is first shown and again when the document changed, unless the user changed it.
    private func generateIfNeeded() {
        guard !model.isBusy else { return }
        if model.isCurrent(for: document) { return }
        if model.isLaTeXEdited, model.documentID == document.id { return }
        model.generate(document, app: app)
    }
}

/// The document's Markdown; a moment after the user stops typing it goes into the document, and the editor shows it.
private struct MarkdownSourceEditor: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var text = ""
    /// The Markdown last loaded or written; a change in the document that differs from it came from elsewhere.
    @State private var known = ""
    @State private var pending: Task<Void, Never>?

    var body: some View {
        CodeTextView(text: $text, language: .markdown, reveal: nil)
            .onAppear(perform: load)
            .onChange(of: document.id) { load() }
            .onChange(of: document.markdown) { _, markdown in
                if markdown != known, pending == nil {
                    text = markdown
                    known = markdown
                }
            }
            .onChange(of: text) { _, value in
                guard value != known else { return }
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    write(value)
                }
            }
            .onDisappear {
                if pending != nil { write(text) }
            }
    }

    private func load() {
        app.writerFlush?()
        let markdown = app.document(document.id)?.markdown ?? document.markdown
        text = markdown
        known = markdown
    }

    private func write(_ value: String) {
        pending?.cancel()
        pending = nil
        known = value
        app.updateDocument(document.id, markdown: value)
    }
}

// MARK: - Text and preview

/// A plain text editor for code: monospaced, no smart quotes or dashes, no spelling check; LaTeX commands and
/// Markdown's markup are coloured.
struct CodeTextView: NSViewRepresentable {
    enum Language { case markdown, latex }

    @Binding var text: String
    let language: Language
    var reveal: (line: Int, token: Int)?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, language: language) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Theme.background)
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Coordinator.font
        textView.textColor = NSColor(Theme.textPrimary)
        textView.backgroundColor = NSColor(Theme.background)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            coordinator.highlight()
        }
        if let reveal, reveal.token != coordinator.revealedToken {
            coordinator.revealedToken = reveal.token
            coordinator.show(line: reveal.line)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let text: Binding<String>
        let language: Language
        weak var textView: NSTextView?
        var revealedToken = 0
        private var highlightPending = false

        init(text: Binding<String>, language: Language) {
            self.text = text
            self.language = language
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            guard !highlightPending else { return }
            highlightPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.highlightPending = false
                self?.highlight()
            }
        }

        /// Selects the line and scrolls it into view.
        func show(line: Int) {
            guard let textView else { return }
            let string = textView.string as NSString
            var location = 0
            var current = 1
            while current < line, location < string.length {
                let range = string.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                current += 1
            }
            let range = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }

        /// Colours as temporary attributes: the text itself stays plain.
        func highlight() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let string = textView.string
            let whole = NSRange(location: 0, length: (string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            let accent = NSColor(Theme.accent)
            let quiet = NSColor(Theme.textTertiary)
            let rules: [(String, NSColor)] = switch language {
            case .latex: [
                (#"\\[A-Za-z@]+\*?"#, accent),
                (#"(?<!\\)%.*$"#, quiet),
            ]
            case .markdown: [
                (#"</?(span|u|sup|sub|br)\b[^>]*>"#, quiet),
                (#"^:::.*$"#, quiet),
                (#"\{[.#][^}\n]*\}"#, quiet),
                (#"^#{1,6} "#, accent),
                (#"\^\[[^\]\n]*\]"#, accent),
                (#"\[@[^\]\n]+\]"#, accent),
            ]
            }
            for (pattern, color) in rules {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
                for match in expression.matches(in: string, range: whole) {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
                }
            }
        }
    }
}

/// The PDF as it came out, page after page; it keeps its place when it is set again.
private struct PDFPreview: NSViewRepresentable {
    let data: Data

    final class Coordinator { var data: Data? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(Theme.background)
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        let page = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = PDFDocument(data: data)
        if let document = view.document, page < document.pageCount, let target = document.page(at: page) { view.go(to: target) }
    }
}
