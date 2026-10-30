import SwiftUI

/// The right-hand panel of an open document, like the chat's: its table of contents (made by the model, or from
/// its own chapters and headings) and its bookmarks.
struct DocumentPanel: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let controller: WriterEditorController
    let assistant: WriterAssistant

    var body: some View {
        let mode = document.effectiveTOCMode
        let isGenerating = app.documentOutlineGeneratingIDs.contains(document.id)
        let bookmarks = WriterBookmark.entries(in: document.markdown)

        VStack(spacing: 0) {
            HStack(spacing: 2) {
                PanelTab(title: "Inhalt", count: nil, isSelected: app.documentPanelTab == .contents) {
                    app.documentPanelTab = .contents
                }
                // Four tabs don't fit the panel by name: the others show their symbol, the name is the tooltip.
                PanelTab(title: "Lesezeichen", count: bookmarks.count, isSelected: app.documentPanelTab == .bookmarks, symbol: "bookmark") {
                    app.documentPanelTab = .bookmarks
                }
                PanelTab(title: "Quellen", count: CitationMarkup.keys(in: document.markdown).count, isSelected: app.documentPanelTab == .sources,
                         symbol: "quote.bubble") {
                    app.documentPanelTab = .sources
                }
                PanelTab(title: "Kommentare", count: controller.comments.filter { !$0.comment.isResolved }.count,
                         isSelected: app.documentPanelTab == .comments, symbol: "text.bubble") {
                    app.documentPanelTab = .comments
                }
                Spacer(minLength: 0)
                if app.documentPanelTab == .contents, mode == .dynamic {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                            .help("Inhaltsverzeichnis wird erstellt …")
                    } else {
                        IconButton(systemName: "arrow.clockwise", help: "Inhaltsverzeichnis neu erstellen", size: 13, frameSize: Theme.titleBarControlSize) {
                            app.refreshDocumentOutline(document.id)
                        }
                        .disabled(assistant.isBusy)
                    }
                }
                IconButton(systemName: "sidebar.right", help: "Seitenleiste ausblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            if app.documentPanelTab == .contents {
                Picker("", selection: Binding(get: { mode }, set: { app.setDocumentTOCMode(document.id, $0) })) {
                    ForEach(WriterTOCMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .help("Dynamisch: das Modell gliedert den Text in Themen. Überschriften: deine Kapitel und Überschriften.")
            }

            if app.documentPanelTab == .sources {
                DocumentSourcesPanel(document: document, controller: controller, library: app.citations)
            } else if app.documentPanelTab == .comments {
                CommentsPanel(controller: controller, assistant: assistant)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch app.documentPanelTab {
                        case .bookmarks: bookmarkList(bookmarks)
                        case .contents, .sources, .comments:
                            if mode == .headings { headingList } else { dynamicContents(isGenerating: isGenerating) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }

            if app.documentPanelTab == .contents, mode == .dynamic, let outline = document.outline {
                footer(outline, isGenerating: isGenerating)
            }
        }
        .background(Theme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    // MARK: Headings

    @ViewBuilder
    private var headingList: some View {
        let headings = WriterHeadings.headings(in: document.markdown)
        let isFormal = WriterHeadings.isFormal(document.markdown)
        if headings.isEmpty {
            placeholder(
                icon: "list.number",
                title: "Noch keine Überschriften",
                text: "Lege über das Absatzformat (¶) Kapitel (⌥⌘K) und Überschriften (⌥⌘1–3) an. Sie erscheinen hier sofort."
            )
        } else {
            let top = headings.map(\.level).min() ?? 0
            VStack(alignment: .leading, spacing: 1) {
                ForEach(headings) { heading in
                    HeadingRow(heading: heading, indent: heading.level - top, isActive: controller.currentHeading == heading.index) {
                        controller.jumpToHeading(heading.index)
                    }
                    .padding(.top, heading.level == top && heading.index > 0 ? 6 : 0)
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            if isFormal {
                Label("Im Dokument steht ein Inhaltsverzeichnis. Kapitel und Überschriften sind nummeriert – genau so im PDF- und LaTeX-Export.", systemImage: "checkmark.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if WriterTOCAttachment.kind(in: document.markdown) == true {
                actionButton("Inhaltsverzeichnis auf Überschriften umstellen", systemImage: "list.number") {
                    controller.setTableOfContents(dynamic: false)
                }
                Text("Im Dokument steht gerade das dynamische Inhaltsverzeichnis des Modells.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                actionButton("Inhaltsverzeichnis einfügen", systemImage: "list.bullet.rectangle") {
                    controller.insertTableOfContents()
                }
                Text("Fügt ein Inhaltsverzeichnis an der Cursorposition ein. Kapitel und Überschriften werden dann nummeriert und so exportiert.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 16)
    }

    // MARK: Dynamic

    @ViewBuilder
    private func dynamicContents(isGenerating: Bool) -> some View {
        dynamicOutline(isGenerating: isGenerating)
        // The model's table of contents can be the document's own: in the text and in the export.
        VStack(alignment: .leading, spacing: 8) {
            switch WriterTOCAttachment.kind(in: document.markdown) {
            case true?:
                Label("Dieses Inhaltsverzeichnis steht im Dokument und im Export (im PDF mit Seitenzahlen). Es wächst mit dem Text.", systemImage: "checkmark.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case false?:
                actionButton("Im Dokument dieses verwenden", systemImage: "list.bullet.rectangle") {
                    controller.setTableOfContents(dynamic: true)
                }
                Text("Ersetzt das Inhaltsverzeichnis aus den Überschriften im Dokument durch die Themen des Modells.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                actionButton("Als Inhaltsverzeichnis einfügen", systemImage: "list.bullet.rectangle") {
                    controller.insertTableOfContents(dynamic: true)
                }
                Text("Fügt diese Gliederung an der Cursorposition ins Dokument ein – auch für den PDF-, LaTeX- und Markdown-Export. Sie wächst mit dem Text.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func dynamicOutline(isGenerating: Bool) -> some View {
        if let outline = document.outline {
            let blockCount = MarkdownParser.parse(WriterBookmark.strip(document.markdown)).count
            if !outline.summary.isEmpty {
                RichText.make(outline.summary, mathSize: 13)
                    .font(.system(size: 12.5))
                    .italic()
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
            }
            ForEach(Array(outline.sections.enumerated()), id: \.element.id) { index, section in
                OutlineRow(title: section.title, number: index + 1, level: 0, isActive: false) {
                    controller.jump(to: section.anchor, blockCount: blockCount)
                }
                .padding(.top, index == 0 ? 0 : 8)
                ForEach(section.items) { item in
                    OutlineRow(title: item.title, number: nil, level: 1, isActive: false) {
                        controller.jump(to: item.anchor, blockCount: blockCount)
                    }
                }
            }
        } else if isGenerating {
            placeholder(icon: "list.bullet.rectangle", title: "Erstelle Inhaltsverzeichnis …", text: "Das Modell gliedert das Dokument in Themen und Unterpunkte.")
        } else if let error = app.documentOutlineErrors[document.id] {
            placeholder(icon: "exclamationmark.triangle", title: "Hat nicht geklappt", text: error)
            actionButton("Erneut versuchen", systemImage: "arrow.clockwise") { app.refreshDocumentOutline(document.id) }
                .padding(.horizontal, 6)
                .padding(.top, 12)
        } else {
            placeholder(
                icon: "list.bullet.rectangle",
                title: "Noch kein Inhaltsverzeichnis",
                text: "Ab etwa \(DocumentOutlineBuilder.minimumWords) Wörtern entsteht es von selbst und wächst mit dem Text."
            )
            actionButton("Jetzt erstellen", systemImage: "sparkles") { app.refreshDocumentOutline(document.id) }
                .padding(.horizontal, 6)
                .padding(.top, 12)
                .disabled(document.isEmpty || assistant.isBusy)
        }
    }

    private func footer(_ outline: DocumentOutline, isGenerating: Bool) -> some View {
        HStack(spacing: 6) {
            if DocumentOutlineBuilder.isOutdated(document) && !isGenerating {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(Theme.warning)
                Text("Text hat sich seitdem geändert")
            } else {
                Text("Erstellt von \(LaTeXWriter.speakerName(forModel: outline.model)) · \(outline.generatedAt.formatted(date: .omitted, time: .shortened))")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: Bookmarks

    @ViewBuilder
    private func bookmarkList(_ bookmarks: [WriterBookmarkEntry]) -> some View {
        if bookmarks.isEmpty {
            placeholder(
                icon: "bookmark",
                title: "Noch keine Lesezeichen",
                text: "Markiere eine Stelle und wähle per Rechtsklick „Lesezeichen anlegen“ – oder ⌥⌘B. Ohne Markierung gilt das Lesezeichen dem ganzen Absatz."
            )
            actionButton("Lesezeichen an der Cursorposition", systemImage: "bookmark") { controller.toggleBookmark() }
                .padding(.horizontal, 6)
                .padding(.top, 12)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(bookmarks) { bookmark in
                    BookmarkRow(
                        title: bookmark.title,
                        excerpt: bookmark.excerpt,
                        caption: bookmark.section.map { "In „\($0)“" } ?? "Am Anfang des Dokuments",
                        isHighlighted: controller.recentBookmarkID == bookmark.id,
                        onOpen: { controller.jumpToBookmark(bookmark.id) },
                        onRename: { controller.renameBookmark(bookmark.id, to: $0) },
                        onDelete: { controller.removeBookmark(bookmark.id) }
                    )
                }
            }
        }
    }

    // MARK: Pieces

    private func placeholder(icon: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A chapter or heading: its number (in a formal document), indented by level; the one the reader is in is marked.
private struct HeadingRow: View {
    let heading: WriterHeading
    let indent: Int
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let number = heading.number {
                    Text(number)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                }
                RichText.make(heading.title, mathSize: indent == 0 ? 14 : 13.5)
                    .font(.system(size: indent == 0 ? 13 : 12.5, weight: indent == 0 ? .semibold : .regular))
                    .foregroundStyle(indent == 0 || hovering || isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + CGFloat(indent) * 14)
            .padding(.trailing, 6)
            .padding(.vertical, indent == 0 ? 6 : 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.14) : (hovering ? Theme.hover : .clear))
            )
            .overlay(alignment: .leading) {
                if isActive {
                    Capsule().fill(Theme.accent).frame(width: 2.5).padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Zu dieser Stelle springen")
    }
}
