import SwiftUI

/// The right-hand panel of a presentation: its contents (chapters and slides), the bookmarks on all slides and the
/// sources it cites.
struct PresenterPanel: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let currentSlideID: PresentationSlide.ID
    let controller: WriterEditorController

    var body: some View {
        let bookmarks = bookmarkEntries
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                PanelTab(title: "Inhalt", count: nil, isSelected: app.documentPanelTab == .contents) {
                    app.documentPanelTab = .contents
                }
                PanelTab(title: "Lesezeichen", count: bookmarks.count, isSelected: app.documentPanelTab == .bookmarks) {
                    app.documentPanelTab = .bookmarks
                }
                PanelTab(title: "Quellen", count: CitationMarkup.keys(in: document.markdown).count, isSelected: app.documentPanelTab == .sources) {
                    app.documentPanelTab = .sources
                }
                Spacer(minLength: 0)
                IconButton(systemName: "sidebar.right", help: "Seitenleiste ausblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            if app.documentPanelTab == .sources {
                DocumentSourcesPanel(document: document, controller: controller, library: app.citations)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if app.documentPanelTab == .bookmarks { bookmarkList(bookmarks) } else { contents }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    // MARK: Contents

    /// The title slides, the chapters and the slides in them, numbered like the slide list.
    @ViewBuilder
    private var contents: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(deck.slides.enumerated()), id: \.element.id) { index, slide in
                let inChapter = slide.role == .content && deck.chapter(of: slide.id) != nil
                ContentsRow(
                    number: index + 1,
                    title: slide.title.isEmpty ? "Folie ohne Titel" : slide.title,
                    role: slide.role,
                    indent: inChapter ? 1 : 0,
                    isActive: slide.id == currentSlideID,
                    isEmpty: slide.title.isEmpty
                ) {
                    app.selectSlide(slide.id)
                }
                .padding(.top, slide.role != .content && index > 0 ? 8 : 0)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Kapitelfolien gliedern die Präsentation. Eine Agenda-Folie listet die Kapitel auf.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            actionButton("Agenda-Folie einfügen", systemImage: "list.bullet.rectangle") {
                app.insertAgendaSlide(document.id, after: deck.slides.first(where: { $0.role == .title })?.id ?? currentSlideID)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 16)
    }

    // MARK: Bookmarks

    private struct Entry: Identifiable {
        let bookmark: WriterBookmarkEntry
        let slideID: PresentationSlide.ID
        let number: Int
        let slideTitle: String
        var id: String { bookmark.id }
    }

    private var bookmarkEntries: [Entry] {
        deck.slides.enumerated().flatMap { index, slide in
            WriterBookmark.entries(in: slide.markdown).map {
                Entry(bookmark: $0, slideID: slide.id, number: index + 1, slideTitle: slide.title)
            }
        }
    }

    @ViewBuilder
    private func bookmarkList(_ entries: [Entry]) -> some View {
        if entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 2)
                Text("Noch keine Lesezeichen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Markiere Text auf einer Folie und wähle per Rechtsklick „Lesezeichen anlegen“ – oder ⌥⌘B.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    BookmarkRow(
                        title: entry.bookmark.title,
                        excerpt: entry.bookmark.excerpt,
                        caption: "Folie \(entry.number)" + (entry.slideTitle.isEmpty ? "" : " · \(entry.slideTitle)"),
                        isHighlighted: controller.recentBookmarkID == entry.bookmark.id,
                        onOpen: { open(entry) },
                        onRename: { title in onSlide(entry) { controller.renameBookmark(entry.bookmark.id, to: title) } },
                        onDelete: { onSlide(entry) { controller.removeBookmark(entry.bookmark.id) } }
                    )
                }
            }
        }
    }

    private func open(_ entry: Entry) {
        onSlide(entry) { controller.jumpToBookmark(entry.bookmark.id) }
    }

    /// Opens the bookmark's slide first; the editor needs a moment to load it.
    private func onSlide(_ entry: Entry, then action: @escaping () -> Void) {
        guard entry.slideID != currentSlideID else { return action() }
        app.selectSlide(entry.slideID)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
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

private struct ContentsRow: View {
    let number: Int
    let title: String
    let role: SlideRole
    let indent: Int
    let isActive: Bool
    let isEmpty: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                    .frame(minWidth: 16, alignment: .trailing)
                if role != .content {
                    Image(systemName: role.symbol)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(title)
                    .font(.system(size: role == .content ? 12.5 : 13, weight: role == .content ? .regular : .semibold))
                    .foregroundStyle(isEmpty ? Theme.textTertiary : (role != .content || hovering || isActive ? Theme.textPrimary : Theme.textSecondary))
                    .italic(isEmpty)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + CGFloat(indent) * 12)
            .padding(.trailing, 6)
            .padding(.vertical, role == .content ? 4 : 6)
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
        .help("Zu dieser Folie")
    }
}
