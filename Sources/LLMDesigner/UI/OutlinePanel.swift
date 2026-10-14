import SwiftUI

/// Right-hand panel of the selected chat: the LLM-generated table of contents and the user's bookmarks.
struct OutlinePanel: View {
    @Environment(AppModel.self) private var app
    let chat: Chat

    var body: some View {
        @Bindable var app = app
        let isGenerating = app.outlineGeneratingIDs.contains(chat.id)

        VStack(spacing: 0) {
            HStack(spacing: 2) {
                PanelTab(title: "Inhalt", count: nil, isSelected: app.sidePanelTab == .contents) {
                    app.sidePanelTab = .contents
                }
                PanelTab(title: "Lesezeichen", count: chat.bookmarks?.count ?? 0, isSelected: app.sidePanelTab == .bookmarks) {
                    app.sidePanelTab = .bookmarks
                }
                Spacer(minLength: 0)
                if app.sidePanelTab == .bookmarks {
                    EmptyView()
                } else if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                        .help("Inhaltsverzeichnis wird erstellt …")
                } else {
                    IconButton(systemName: "arrow.clockwise", help: "Inhaltsverzeichnis neu erstellen", size: 13, frameSize: Theme.titleBarControlSize) {
                        app.refreshOutline(chat.id)
                    }
                    .disabled(app.isGenerating(chat.id))
                }
                IconButton(systemName: "sidebar.right", help: "Seitenleiste ausblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if app.sidePanelTab == .bookmarks {
                        BookmarkList(chat: chat)
                    } else {
                        content(isGenerating: isGenerating)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)

            if app.sidePanelTab == .contents, let outline = chat.outline {
                footer(outline, isGenerating: isGenerating)
            }
        }
        .background(Theme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    @ViewBuilder
    private func content(isGenerating: Bool) -> some View {
        if let outline = chat.outline {
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
                OutlineRow(title: section.title, number: index + 1, level: 0, isActive: app.highlightedTarget == section.target) {
                    app.jump(to: section.target)
                }
                .padding(.top, index == 0 ? 0 : 8)
                ForEach(section.items) { item in
                    OutlineRow(title: item.title, number: nil, level: 1, isActive: app.highlightedTarget == item.target) {
                        app.jump(to: item.target)
                    }
                }
            }
        } else if isGenerating {
            placeholder(
                icon: "list.bullet.rectangle",
                title: "Erstelle Inhaltsverzeichnis …",
                text: "Das Modell gliedert den Chat in Themen und Unterpunkte."
            )
        } else if let error = app.outlineErrors[chat.id] {
            placeholder(icon: "exclamationmark.triangle", title: "Hat nicht geklappt", text: error)
            retryButton("Erneut versuchen")
        } else {
            placeholder(
                icon: "list.bullet.rectangle",
                title: "Noch kein Inhaltsverzeichnis",
                text: "Ab \(OutlineBuilder.minimumAnswers) Antworten entsteht es automatisch."
            )
            retryButton("Jetzt erstellen")
        }
    }

    private func footer(_ outline: ChatOutline, isGenerating: Bool) -> some View {
        HStack(spacing: 6) {
            if OutlineBuilder.isOutdated(chat) && !isGenerating {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(Theme.warning)
                Text("Neue Nachrichten noch nicht enthalten")
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

    private func retryButton(_ title: String) -> some View {
        Button(title) { app.refreshOutline(chat.id) }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .disabled(app.isGenerating(chat.id))
    }
}

private struct OutlineRow: View {
    let title: String
    let number: Int?
    let level: Int
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minWidth: 12, alignment: .leading)
                }
                RichText.make(title, mathSize: level == 0 ? 14 : 13.5)
                    .font(.system(size: level == 0 ? 13 : 12.5, weight: level == 0 ? .semibold : .regular))
                    .foregroundStyle(level == 0 || hovering || isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, level == 0 ? 6 : 14)
            .padding(.trailing, 6)
            .padding(.vertical, level == 0 ? 6 : 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear))
            )
            .overlay(alignment: .leading) {
                if level > 0 {
                    Rectangle()
                        .fill(isActive ? Theme.accent : Theme.strongBorder)
                        .frame(width: 1.5)
                        .padding(.leading, 26 - 14)
                        .padding(.vertical, 2)
                }
            }
            .padding(.leading, level > 0 ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Zu dieser Stelle springen")
    }
}

private struct PanelTab: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                }
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : (hovering ? Theme.textSecondary : Theme.textTertiary))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The user's bookmarks in chat order; click to jump, right-click to rename or delete.
private struct BookmarkList: View {
    @Environment(AppModel.self) private var app
    let chat: Chat

    var body: some View {
        let bookmarks = sorted(chat.bookmarks ?? [])
        if bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 2)
                Text("Noch keine Lesezeichen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Markiere eine Stelle im Chat und wähle per Rechtsklick „Lesezeichen anlegen“.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(bookmarks) { bookmark in
                    BookmarkRow(
                        bookmark: bookmark,
                        caption: caption(for: bookmark),
                        isHighlighted: app.recentBookmarkID == bookmark.id || app.highlightedTarget == bookmark.target,
                        onOpen: { app.jump(to: bookmark.target) },
                        onRename: { app.renameBookmark(bookmark.id, to: $0) },
                        onDelete: { app.deleteBookmark(bookmark.id) }
                    )
                }
            }
        }
    }

    private func sorted(_ bookmarks: [Bookmark]) -> [Bookmark] {
        func position(_ bookmark: Bookmark) -> (Int, Int) {
            (chat.messages.firstIndex { $0.id == bookmark.target.messageID } ?? .max, bookmark.target.block ?? -1)
        }
        return bookmarks.sorted { position($0) < position($1) }
    }

    private func caption(for bookmark: Bookmark) -> String {
        let message = chat.messages.first { $0.id == bookmark.target.messageID }
        let source = message?.role == .user ? "Deine Nachricht" : "Antwort von \(LaTeXWriter.speakerName(forModel: message?.model))"
        return "\(source) · \(bookmark.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let caption: String
    let isHighlighted: Bool
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { renaming = false }
                        .task {
                            // Focus only after the context menu that started renaming has closed.
                            try? await Task.sleep(for: .milliseconds(120))
                            fieldFocused = true
                        }
                        .onChange(of: fieldFocused) { _, focused in
                            if !focused { commit() }
                        }
                } else {
                    Text(bookmark.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering && !renaming {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lesezeichen löschen")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear))
                .animation(.easeOut(duration: 0.4), value: isHighlighted)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { onOpen() } }
        .onHover { hovering = $0 }
        .help(bookmark.excerpt)
        .contextMenu {
            Button("Umbenennen", systemImage: "pencil") {
                draft = bookmark.title
                renaming = true
            }
            Divider()
            Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private func commit() {
        guard renaming else { return }
        renaming = false
        onRename(draft)
    }
}
