import AppKit
import PDFKit

/// Printing with the Mac's own print panel (⌘P). A Writer Studio document is typeset with LaTeX first, so the paper
/// shows the fonts, colours, formulas and code as the PDF export does; a presentation prints the slides as they are
/// shown. The print panel brings everything macOS has: printers, pages per sheet, "Save as PDF", the preview.
extension AppModel {
    /// ⌘P: the open document or presentation.
    func printOpenDocument() {
        guard let document = selectedDocument else { return }
        if document.isPresentation { printPresentation(document.id) } else { printWriterDocument(document.id) }
    }

    func printWriterDocument(_ id: WriterDocument.ID) {
        writerFlush?()
        guard let document = document(id), !exportingIDs.contains(id) else { return }
        guard let engine = LaTeXEngine.locate() else {
            exportError = PDFExportError.noEngine.localizedDescription
            return
        }
        let paper = pdfPaperSize
        exportingIDs.insert(id)
        Task {
            let input = await prepareExport(of: document)
            do {
                let format = input.document.pageFormat
                let pdf = try await engine.makePDF(parts: [input.part], paper: paper, typeface: format.font(input.document.font), format: format,
                                                   design: input.document.pageDesign)
                exportingIDs.remove(id)
                // A paperback's small pages are printed at their size in the middle of the printer's paper; a page of the
                // user's own size goes onto paper of that size.
                let sheet = input.document.customSetup.map { NSSize(width: $0.paperSize.width, height: $0.paperSize.height) } ?? paper.pointSize
                showPrintPanel(for: pdf, title: input.document.displayTitle, paper: sheet, fitsUp: false)
            } catch {
                exportingIDs.remove(id)
                exportError = error.localizedDescription
            }
        }
    }

    func printPresentation(_ id: WriterDocument.ID) {
        writerFlush?()
        guard let document = document(id), let deck = document.deck, !exportingIDs.contains(id) else { return }
        exportingIDs.insert(id)
        Task {
            citations.loadIfNeeded()
            let data = await SlidePrinter.pdf(deck: deck, title: document.displayTitle, family: document.font, citations: citations)
            exportingIDs.remove(id)
            guard let data else {
                exportError = "Die Folien ließen sich nicht zum Drucken zeichnen."
                return
            }
            let paper = pdfPaperSize.pointSize
            showPrintPanel(for: data, title: document.displayTitle, paper: NSSize(width: paper.height, height: paper.width), fitsUp: true)
        }
    }

    /// Shows the print panel for a PDF, as a sheet of the window. `fitsUp`: pages smaller than the paper are scaled up
    /// to it (slides); otherwise only larger ones are scaled down (the LaTeX pages are made for the paper).
    func showPrintPanel(for pdf: Data, title: String, paper: NSSize, fitsUp: Bool) {
        guard let document = PDFDocument(data: pdf) else {
            exportError = "Das PDF zum Drucken ließ sich nicht öffnen."
            return
        }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = paper
        info.orientation = paper.width > paper.height ? .landscape : .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        guard let operation = document.printOperation(for: info, scalingMode: fitsUp ? .pageScaleToFit : .pageScaleDownToFit, autoRotate: true) else {
            exportError = "Das Drucken konnte nicht vorbereitet werden."
            return
        }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

extension PaperSize {
    /// The sheet in points (portrait).
    var pointSize: NSSize {
        switch self {
        case .a4: NSSize(width: 595.28, height: 841.89)
        case .a5: NSSize(width: 419.53, height: 595.28)
        case .letter: NSSize(width: 612, height: 792)
        }
    }
}
