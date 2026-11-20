import SwiftUI

// The slide list on the left of Presenter Studio (see PresenterScreen).

// MARK: Slide list

/// What is dragged when slides are put in another order.
struct SlideDrag: Codable, Transferable {
    let slideID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct SlideStrip: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let currentSlideID: PresentationSlide.ID
    let find: DocumentFind
    @State private var dropTarget: Int?

    /// The content slides that belong to a chapter (a chapter slide comes before them), found in one pass rather
    /// than once per row.
    private var indentedSlides: Set<PresentationSlide.ID> {
        var result = Set<PresentationSlide.ID>()
        var inChapter = false
        for slide in deck.slides {
            if slide.role == .chapter { inChapter = true } else if inChapter, slide.role == .content { result.insert(slide.id) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    let indented = indentedSlides
                    LazyVStack(spacing: 4) {
                        ForEach(Array(deck.slides.enumerated()), id: \.element.id) { index, slide in
                            SlideStripRow(
                                document: document, deck: deck, slide: slide, number: index + 1,
                                isSelected: slide.id == currentSlideID, showsDropMark: dropTarget == index,
                                isIndented: indented.contains(slide.id), foundCount: find.count(on: slide.id)
                            )
                            .id(slide.id)
                            .draggable(SlideDrag(slideID: slide.id)) {
                                SlideThumbnail(slide: slide, deck: deck, family: document.font)
                                    .frame(width: 140)
                                    .environment(app)
                            }
                            .dropDestination(for: SlideDrag.self) { items, _ in
                                guard let item = items.first else { return false }
                                app.moveSlide(document.id, item.slideID, to: index, undoManager: MainWindow.window?.undoManager)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = index } else if dropTarget == index { dropTarget = nil }
                            }
                        }
                        // Dropped below the last slide: to the end.
                        Color.clear
                            .frame(height: 30)
                            .overlay(alignment: .top) {
                                if dropTarget == deck.slides.count {
                                    Capsule().fill(Theme.accent).frame(height: 3).padding(.horizontal, 12)
                                }
                            }
                            .dropDestination(for: SlideDrag.self) { items, _ in
                                guard let item = items.first else { return false }
                                app.moveSlide(document.id, item.slideID, to: deck.slides.count, undoManager: MainWindow.window?.undoManager)
                                return true
                            } isTargeted: { targeted in
                                if targeted { dropTarget = deck.slides.count } else if dropTarget == deck.slides.count { dropTarget = nil }
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: currentSlideID) { _, id in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            Button {
                app.addSlide(to: document.id, after: currentSlideID, undoManager: MainWindow.window?.undoManager)
            } label: {
                Label("Neue Folie", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Neue Folie nach der geöffneten (⇧⌘↩)")
        }
        .background(Theme.shade.opacity(0.18))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }
}

struct SlideStripRow: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let deck: PresentationDeck
    let slide: PresentationSlide
    let number: Int
    let isSelected: Bool
    let showsDropMark: Bool
    /// A content slide of a chapter, set in a little.
    let isIndented: Bool
    /// Places the find bar found on this slide and its card.
    var foundCount = 0
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                if slide.role != .content {
                    Image(systemName: slide.role.symbol)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                        .help(slide.role.label)
                }
                if !slide.notes.isEmpty || app.notesWriting.contains(slide.id) {
                    Image(systemName: app.notesWriting.contains(slide.id) ? "ellipsis.bubble" : "text.bubble")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .symbolEffect(.pulse, isActive: app.notesWriting.contains(slide.id))
                        .help(app.notesWriting.contains(slide.id) ? "Die KI schreibt die Moderatorenkarte …" : "Hat eine Moderatorenkarte")
                }
            }
            .frame(width: 18)
            .padding(.top, 2)
            SlideThumbnail(slide: slide, deck: deck, family: document.font)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.ink.opacity(hovering ? 0.25 : 0.1), lineWidth: isSelected ? 2 : 1)
                        .padding(isSelected ? -2 : 0)
                )
                .overlay(alignment: .topTrailing) {
                    if foundCount > 0 {
                        Text("\(foundCount)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color(nsColor: FindColors.currentText))
                            .padding(.horizontal, 5)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Capsule().fill(Color(nsColor: FindColors.current)))
                            .padding(4)
                            .help(foundCount == 1 ? "1 Treffer auf dieser Folie" : "\(foundCount) Treffer auf dieser Folie")
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .padding(.vertical, 4)
        .padding(.leading, isIndented ? 4 : 0)
        .overlay(alignment: .top) {
            if showsDropMark {
                Capsule().fill(Theme.accent).frame(height: 3).offset(y: -3).padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selectSlide(slide.id) }
        .onHover { hovering = $0 }
        .help(slide.title.isEmpty ? "Folie \(number)" : slide.title)
        .contextMenu {
            Button("Neue Folie danach", systemImage: "plus") { app.addSlide(to: document.id, after: slide.id, undoManager: MainWindow.window?.undoManager) }
            Button("Leere Folie danach", systemImage: "rectangle") { app.addSlide(to: document.id, after: slide.id, blank: true, undoManager: MainWindow.window?.undoManager) }
            if slide.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if slide.hidesPlaceholder {
                    Button("Platzhalter wieder zeigen", systemImage: "character.cursor.ibeam") {
                        app.setSlidePlaceholderHidden(document.id, slide.id, false, undoManager: NSApp.keyWindow?.undoManager)
                    }
                } else {
                    Button("Platzhalter entfernen", systemImage: "eraser") {
                        app.setSlidePlaceholderHidden(document.id, slide.id, true, undoManager: NSApp.keyWindow?.undoManager)
                    }
                }
            }
            Button("Duplizieren", systemImage: "plus.square.on.square") { app.duplicateSlide(document.id, slide.id, undoManager: MainWindow.window?.undoManager) }
            Menu("Art der Folie") {
                ForEach(SlideRole.allCases) { role in
                    Button { app.setSlideRole(document.id, slide.id, role, undoManager: MainWindow.window?.undoManager) } label: {
                        if role == slide.role { Label(role.label, systemImage: "checkmark") } else { Text(role.label) }
                    }
                }
            }
            Button("Moderatorenkarte schreiben lassen", systemImage: "sparkles") { app.writeSpeakerNotes(document.id, slides: [slide.id]) }
            if slide.background != nil {
                Button("Hintergrund der Präsentation verwenden", systemImage: "arrow.uturn.backward") { app.setSlideBackground(document.id, slide.id, nil, undoManager: MainWindow.window?.undoManager) }
            }
            Divider()
            Button("Folie löschen", systemImage: "trash", role: .destructive) { app.deleteSlide(document.id, slide.id, undoManager: MainWindow.window?.undoManager) }
                .disabled(deck.slides.count <= 1)
        }
    }
}
