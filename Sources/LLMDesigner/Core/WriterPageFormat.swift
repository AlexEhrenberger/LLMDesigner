import Foundation

/// How a Writer Studio document is set, in the editor and in print: on the paper of the settings (DIN A4 unless
/// changed there), as a paperback, or as standard manuscript pages ("Normseiten"), the form publishers and agencies
/// ask authors for: 30 lines of at most 60 characters in Courier 12 pt, one and a half lines apart, ragged right
/// without hyphenation.
///
/// The two book formats indent paragraphs instead of setting them apart, start chapters on a new page, and the
/// editor shows where their pages end. The editor sets the text in the format's line length and line distance at
/// screen size, so a Normseite breaks its lines and pages as the print does; a paperback comes close (the print
/// is justified by TeX).
enum WriterPageFormat: String, CaseIterable, Identifiable, Sendable {
    case standard
    case paperback = "taschenbuch"
    case manuscript = "normseite"
    /// The user's own paper, margins, text size and line spacing (`WriterPageSetup`, kept by the document).
    case custom = "eigen"

    var id: String { rawValue }

    /// The formats the menus list by themselves; the user's own ones come with their names.
    static let builtIn: [WriterPageFormat] = [.standard, .paperback, .manuscript]

    var label: String {
        switch self {
        case .standard: "Standard"
        case .paperback: "Taschenbuch"
        case .manuscript: "Normseite"
        case .custom: "Eigenes Format"
        }
    }

    /// What the format is, next to its name (the standard sheet is named by its paper).
    var detail: String {
        switch self {
        case .standard: "Papier wie in den Einstellungen"
        case .paperback: "12,5 × 19 cm, 10 pt, Blocksatz, 34 Zeilen"
        case .manuscript: "DIN A4, 30 Zeilen à 60 Anschläge, Courier 12 pt"
        case .custom: "Papier, Ränder und Schrift nach Wahl"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "doc"
        case .paperback: "book.closed"
        case .manuscript: "doc.text"
        case .custom: "doc.badge.gearshape"
        }
    }

    /// Indented paragraphs, chapters on new pages, pages shown in the editor.
    var isBook: Bool { self == .paperback || self == .manuscript }

    /// The editor shows where the pages end: the book formats and the user's own.
    var showsPages: Bool { self != .standard }

    /// The text size in print, in points.
    var printSize: CGFloat {
        switch self {
        case .standard, .custom: WriterFont.printSize
        case .paperback: 10
        case .manuscript: 12
        }
    }

    /// Baseline to baseline in print, in points: LaTeX's 12 pt for 10 pt text a little opened, and one and a half
    /// lines of Courier New 12 pt as word processors set them. nil: LaTeX's own.
    var lineDistance: CGFloat? {
        switch self {
        case .standard, .custom: nil
        case .paperback: 12.6
        case .manuscript: 20.4
        }
    }

    /// The font the format prescribes, or the document's own.
    func font(_ documentFont: WriterFont) -> WriterFont {
        self == .manuscript ? .courier : documentFont
    }

    /// Lines of text on a full page.
    var linesPerPage: Int {
        switch self {
        case .standard, .custom: 0
        case .paperback: 34
        case .manuscript: 30
        }
    }

    static let manuscriptCharactersPerLine = 60
    /// What publishers count a Normseite as when they go by characters (spaces included).
    static let manuscriptCharactersPerPage = 1800
    /// A Normseite's paragraphs start five characters in, a typewriter's tab.
    static let manuscriptIndentCharacters = 5

    /// A paperback's text block, in points of print: 9.5 cm wide.
    static let paperbackTextWidth: CGFloat = 95 * pointsPerMillimetre

    /// The line length of a Normseite: 60 characters of Courier New (0.6 em wide) and a hair, so a full line fits.
    static var manuscriptTextWidth: CGFloat {
        CGFloat(manuscriptCharactersPerLine) * 0.6 * WriterPageFormat.manuscript.printSize + 1
    }

    static let pointsPerMillimetre: CGFloat = 72 / 25.4

    // MARK: LaTeX

    /// The `geometry` options: the paper, and for the book formats a text block of exactly `linesPerPage` lines.
    func geometry(paper: PaperSize, setup: WriterPageSetup? = nil) -> String {
        switch self {
        case .standard:
            return paper.geometry
        case .custom:
            return (setup ?? WriterPageSetup()).geometry
        case .paperback:
            return "paperwidth=125mm,paperheight=190mm,left=15mm,textwidth=95mm,top=16mm,textheight=\(textHeight)pt,footskip=24pt"
        case .manuscript:
            return "a4paper,left=25mm,textwidth=\(Self.format(Self.manuscriptTextWidth))pt,top=25mm,textheight=\(textHeight)pt,headheight=21pt,headsep=22pt"
        }
    }

    /// The first line's height (LaTeX's \topskip, the text size) and the others' distance, and a point more:
    /// \linespread rounds the distance up a little, which would push the last line onto the next page.
    private var textHeight: String {
        Self.format(printSize + CGFloat(linesPerPage - 1) * (lineDistance ?? printSize * 1.2) + 1)
    }

    /// Set in the preamble after the packages: line distance, indented paragraphs, quiet headings.
    var latexSetup: String {
        guard isBook, let lineDistance else { return "" }
        // The class sets 12 pt lines for 10 pt text and 14.5 pt for 12 pt; \linespread stretches them.
        let classDistance: CGFloat = self == .paperback ? 12 : 14.5
        var lines = ["\\linespread{\(Self.format(lineDistance / classDistance, digits: 4))}"]
        lines.append("\\setlength{\\parskip}{0pt}")
        lines.append("\\setlength{\\parindent}{\(paragraphIndent)}")
        lines.append("\\makeatletter")
        switch self {
        case .paperback:
            lines += [
                #"\renewcommand\section{\@startsection{section}{1}{\z@}{-\baselineskip}{0.5\baselineskip}{\normalfont\large\bfseries\raggedright}}"#,
                #"\renewcommand\subsection{\@startsection{subsection}{2}{\z@}{-\baselineskip}{0.5\baselineskip}{\normalfont\normalsize\bfseries\raggedright}}"#,
                #"\renewcommand\subsubsection{\@startsection{subsubsection}{3}{\z@}{-0.5\baselineskip}{0.25\baselineskip}{\normalfont\normalsize\itshape\raggedright}}"#,
                #"\@ifundefined{chapter}{}{\def\@makechapterhead#1{\vspace*{2\baselineskip}{\parindent\z@\raggedright\normalfont\Large\bfseries\thechapter\quad #1\par\nobreak}\vspace{2\baselineskip}}"#,
                #"\def\@makeschapterhead#1{\vspace*{2\baselineskip}{\parindent\z@\raggedright\normalfont\Large\bfseries #1\par\nobreak}\vspace{2\baselineskip}}}"#,
            ]
        case .manuscript:
            // Headings in the text's own size with an empty line before and after, so every line stays on the grid
            // of 30; no hyphenation, page numbers at the top right.
            lines += [
                #"\renewcommand\section{\@startsection{section}{1}{\z@}{-\baselineskip}{\baselineskip}{\normalfont\normalsize\bfseries\raggedright}}"#,
                #"\renewcommand\subsection{\@startsection{subsection}{2}{\z@}{-\baselineskip}{\baselineskip}{\normalfont\normalsize\bfseries\raggedright}}"#,
                #"\renewcommand\subsubsection{\@startsection{subsubsection}{3}{\z@}{-\baselineskip}{\baselineskip}{\normalfont\normalsize\bfseries\raggedright}}"#,
                #"\@ifundefined{chapter}{}{\def\@makechapterhead#1{{\parindent\z@\raggedright\normalfont\normalsize\bfseries\thechapter\quad #1\par\nobreak}\vspace{\baselineskip}}"#,
                #"\def\@makeschapterhead#1{{\parindent\z@\raggedright\normalfont\normalsize\bfseries #1\par\nobreak}\vspace{\baselineskip}}}"#,
                #"\hyphenpenalty=10000"#,
                #"\fancyfoot{}\fancyhead[R]{\thepage}"#,
                #"\fancypagestyle{plain}{\fancyhf{}\fancyhead[R]{\thepage}}"#,
            ]
        case .standard, .custom:
            break
        }
        lines.append("\\makeatother")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The factor of `\\linespread` the text is set with: a book's from its line distance, the user's own format's
    /// line spacing, 1 for the standard sheet.
    func lineSpread(setup: WriterPageSetup?) -> Double {
        switch self {
        case .standard: 1
        case .custom: setup?.lineSpacing ?? 1
        case .paperback: 12.6 / 12
        case .manuscript: 20.4 / 14.5
        }
    }

    /// LaTeX's first-line indent of a paragraph.
    var paragraphIndent: String {
        switch self {
        case .standard, .custom: "0pt"
        case .paperback: "1em"
        case .manuscript: "\(Self.format(CGFloat(Self.manuscriptIndentCharacters) * 0.6 * printSize))pt"
        }
    }

    /// Writer Studio's text is ragged right like in the editor; a paperback is justified with hyphenation.
    var isRaggedRight: Bool { self != .paperback }
    var isJustified: Bool { self == .paperback }

    static func format(_ value: CGFloat, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", Double(value))
    }
}
