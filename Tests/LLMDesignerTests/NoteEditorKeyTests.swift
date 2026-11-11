import Testing
import AppKit
import SwiftUI
@testable import LLMDesigner

extension ActionSuites {
/// The real note editor in a window that is never shown, with the keys sent to its text fields as AppKit sends them.
@MainActor
@Suite("Notes: Tasten im Editor", .serialized)
struct NoteEditorKeyTests {
    let app = TestApp.model()

    private func host(_ noteID: UUID) async -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NoteEditor(noteID: noteID).environment(app).frame(width: 700, height: 900, alignment: .top))
        await settle()
        return window
    }

    /// Lets SwiftUI update the view and the editor take the keyboard. The run loop draws; the pauses free the main
    /// queue, where the editor hands the keyboard over (the test itself runs on it).
    private func settle() async {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The to-do lines from top to bottom (the title is the first line editor, so it is left out).
    private func lines(in window: NSWindow) -> [NoteLineTextView] {
        func collect(_ view: NSView) -> [NoteLineTextView] {
            ((view as? NoteLineTextView).map { [$0] } ?? []) + view.subviews.flatMap(collect)
        }
        let all = collect(window.contentView!).sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
        return Array(all.dropFirst())
    }

    private func line(_ text: String, in window: NSWindow) throws -> NoteLineTextView {
        try #require(lines(in: window).first { $0.string == text })
    }

    /// A key on the line that has the keyboard, as the person would press it there.
    private func press(_ selector: Selector, in view: NoteLineTextView) async {
        if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        view.doCommand(by: selector)
        await settle()
    }

    @Test func returnTabBacktabAndBackspace() async throws {
        var made = Note(title: "Tasten \(UUID().uuidString)")
        made.todos = [NoteTodo(text: "Konzept"), NoteTodo(text: "Design")]
        let note = app.notes.addNote(title: made.title, todos: made.todos)
        defer { app.notes.deleteNote(note.id) }
        let window = await host(note.id)
        defer { window.close() }
        #expect(lines(in: window).map(\.string) == ["Konzept", "Design"])

        // Return at the end of "Konzept": a new, empty to-do right after it, with the keyboard.
        let konzept = try line("Konzept", in: window)
        konzept.window?.makeFirstResponder(konzept)
        konzept.setSelectedRange(NSRange(location: 7, length: 0))
        await press(#selector(NSResponder.insertNewline(_:)), in: konzept)
        #expect(app.notes.note(note.id)?.todos.map(\.text) == ["Konzept", "", "Design"])
        let fresh = try line("", in: window)
        #expect(window.firstResponder === fresh, "Schreibmarke in: \((window.firstResponder as? NSTextView)?.string ?? "–")")

        // Typing goes in; Tab makes it a to-do of "Konzept", the typed text with it.
        try #require(window.firstResponder === fresh)
        fresh.insertText("Zielgruppe", replacementRange: fresh.selectedRange())
        await press(#selector(NSResponder.insertTab(_:)), in: fresh)
        #expect(app.notes.note(note.id)?.todos.map(\.text) == ["Konzept", "Design"])
        #expect(app.notes.note(note.id)?.todos[0].children.map(\.text) == ["Zielgruppe"])

        // ⇧Tab takes it out again.
        let zielgruppe = try line("Zielgruppe", in: window)
        #expect(window.firstResponder === zielgruppe, "Nach Tab bleibt die Schreibmarke im ToDo")
        await press(#selector(NSResponder.insertBacktab(_:)), in: zielgruppe)
        #expect(app.notes.note(note.id)?.todos.map(\.text) == ["Konzept", "Zielgruppe", "Design"])

        // Return in the middle splits the text.
        let design = try line("Design", in: window)
        design.window?.makeFirstResponder(design)
        design.setSelectedRange(NSRange(location: 3, length: 0))
        await press(#selector(NSResponder.insertNewline(_:)), in: design)
        #expect(app.notes.note(note.id)?.todos.map(\.text) == ["Konzept", "Zielgruppe", "Des", "ign"])

        // Backspace in an empty line removes it.
        let last = try line("ign", in: window)
        last.window?.makeFirstResponder(last)
        last.setSelectedRange(NSRange(location: 3, length: 0))
        await press(#selector(NSResponder.insertNewline(_:)), in: last)
        #expect(app.notes.note(note.id)?.todos.count == 5)
        let empty = try line("", in: window)
        #expect(window.firstResponder === empty)
        await press(#selector(NSResponder.deleteBackward(_:)), in: empty)
        #expect(app.notes.note(note.id)?.todos.map(\.text) == ["Konzept", "Zielgruppe", "Des", "ign"])
        #expect((window.firstResponder as? NoteLineTextView)?.string == "ign", "⌫ gibt die Schreibmarke an die Zeile davor")
    }

    @Test func pastingSeveralLinesMakesSeveralTodos() async throws {
        let note = app.notes.addNote(title: "Einfügen \(UUID().uuidString)", todos: [NoteTodo(text: "Einkauf")])
        defer { app.notes.deleteNote(note.id) }
        let window = await host(note.id)
        defer { window.close() }
        let first = try line("Einkauf", in: window)
        first.window?.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 7, length: 0))
        first.insertText(" Wochenende\n- Brot\n- Milch", replacementRange: first.selectedRange())
        await settle()
        #expect(app.notes.note(note.id)?.todos.map(\.text) == ["Einkauf Wochenende", "Brot", "Milch"])
    }
}
}
