import SwiftUI

/// The comments of the open document in the side panel: each thread with its passage, its entries by the user and
/// the model, a field to answer, the model answering, done and delete. Done threads sit folded at the end.
struct CommentsPanel: View {
    let controller: WriterEditorController
    let assistant: WriterAssistant
    @State private var showsDone = false

    var body: some View {
        let open = controller.comments.filter { !$0.comment.isResolved }
        let done = controller.comments.filter(\.comment.isResolved)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Button {
                            controller.addComment()
                        } label: {
                            Label("Kommentar", systemImage: "text.bubble")
                        }
                        .help("Kommentar zur Markierung (⌥⌘M) – ohne Markierung zum Wort am Cursor")
                        Button {
                            assistant.handle(.comment)
                        } label: {
                            Label(controller.state.hasSelection ? "KI: Markierung" : "KI kommentiert", systemImage: "sparkles")
                        }
                        .disabled(assistant.isBusy)
                        .help("Die KI liest wie eine Lektorin und schreibt Kommentare an die Stellen – zur Markierung oder zum ganzen Dokument")
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)

                    if case .commenting(let done, let total) = assistant.activity {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(done), total: Double(max(total, 1)))
                                .progressViewStyle(.linear)
                                .tint(Theme.accent)
                                .frame(width: 90)
                            Text("Abschnitt \(min(done + 1, total)) von \(total)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    if open.isEmpty && done.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.textTertiary)
                            Text("Noch keine Kommentare")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Markiere eine Stelle und drücke ⌥⌘M, oder lass die KI den Text kommentieren. Kommentare stehen am Rand und kommen nicht in den Druck.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }

                    ForEach(open) { entry in
                        CommentThreadCard(entry: entry, controller: controller, assistant: assistant,
                                          isActive: controller.activeCommentID == entry.id, isFocused: controller.focusedCommentID == entry.id)
                            .id(entry.id)
                    }

                    if !done.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showsDone.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showsDone ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                                Text("Erledigt (\(done.count))")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        if showsDone {
                            ForEach(done) { entry in
                                CommentThreadCard(entry: entry, controller: controller, assistant: assistant, isActive: false, isFocused: false)
                                    .opacity(0.6)
                                    .id(entry.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.focusedCommentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: controller.activeCommentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// One comment thread.
private struct CommentThreadCard: View {
    let entry: WriterCommentEntry
    let controller: WriterEditorController
    let assistant: WriterAssistant
    let isActive: Bool
    let isFocused: Bool
    @State private var reply = ""
    @FocusState private var replyFocused: Bool
    @State private var hovering = false

    private var comment: WriterComment { entry.comment }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                controller.jumpToComment(entry.id)
            } label: {
                Text("„\(entry.excerpt)“")
                    .font(.system(size: 11.5).italic())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zur Stelle springen")

            ForEach(Array(comment.entries.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if item.isAI {
                            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        Text(item.author)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(item.isAI ? Theme.accent : Theme.textPrimary)
                        Text(item.date, format: .relative(presentation: .named))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(item.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !comment.isResolved {
                TextField(comment.entries.isEmpty ? "Kommentar schreiben …" : "Antworten …", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(replyFocused ? Theme.accent.opacity(0.5) : Theme.border))
                    .focused($replyFocused)
                    .onSubmit(send)
                    .onKeyPress(.escape) {
                        replyFocused = false
                        // A comment nobody wrote anything into goes again.
                        if comment.isEmpty, reply.isEmpty { controller.deleteComment(entry.id) }
                        return .handled
                    }
            }

            HStack(spacing: 2) {
                if !comment.isResolved {
                    if assistant.commentReplyID == entry.id {
                        ProgressView().controlSize(.small).frame(width: 26, height: 22)
                        Text("KI antwortet …").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    } else {
                        smallButton("sparkles", comment.entries.isEmpty ? "KI kommentieren lassen" : "KI antwortet auf den Faden") {
                            assistant.replyToComment(entry.id)
                        }
                        .disabled(assistant.isBusy)
                    }
                }
                Spacer(minLength: 0)
                if !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    smallButton("arrow.up.circle.fill", "Senden (↩)", action: send)
                }
                smallButton(comment.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle",
                            comment.isResolved ? "Wieder öffnen" : "Erledigt – der Kommentar bleibt in der Liste, die Stelle ist nicht mehr markiert") {
                    controller.resolveComment(entry.id, !comment.isResolved)
                }
                smallButton("trash", "Kommentar löschen") { controller.deleteComment(entry.id) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isActive ? Color(hex: 0xF2C14C).opacity(0.1) : Color.white.opacity(hovering ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isActive ? Color(hex: 0xF2C14C).opacity(0.45) : Theme.border))
        .onHover { hovering = $0 }
        .onAppear { if isFocused { replyFocused = true } }
        .onChange(of: isFocused) { _, focused in if focused { replyFocused = true } }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.replyToComment(entry.id, text: text)
        reply = ""
    }

    private func smallButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
