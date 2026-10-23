import SwiftUI

/// "Code-Ablauf" in the content analysis: for every Python and SQL block of the document the flow charts of what the
/// code does, drawn from the code itself. A chart can go into the document (below its code) or onto a slide.
struct CodeFlowSection: View {
    let document: WriterDocument
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void
    @State private var charts: [(snippet: CodeSnippet, graphs: [FlowGraph])] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(charts, id: \.snippet.id) { entry in
                SnippetCharts(document: document, snippet: entry.snippet, graphs: entry.graphs, colors: colors, onJump: onJump)
            }
        }
        .task(id: document.markdown) {
            charts = CodeSnippet.snippets(in: document.markdown).map { ($0, $0.flowcharts()) }
        }
    }
}

private struct SnippetCharts: View {
    let document: WriterDocument
    let snippet: CodeSnippet
    let graphs: [FlowGraph]
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(snippet.language.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(colors.accentSoft))
                Text(snippet.firstLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    onJump(snippet.anchor)
                } label: {
                    Label("Zum Code", systemImage: "arrow.up.forward")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(colors.accent)
                .help("Zum Code-Block im Dokument springen")
            }
            if graphs.isEmpty || graphs.allSatisfy(\.isEmpty) {
                Text(snippet.language == .python
                     ? "In diesem Code gibt es keine Schritte, die sich als Ablauf zeigen ließen (nur Importe oder Definitionen)."
                     : "Dieser Code ließ sich nicht als Ablauf lesen.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.tertiaryText)
            }
            ForEach(graphs.filter { !$0.isEmpty }) { graph in
                FlowCard(document: document, snippet: snippet, graph: graph, colors: colors)
            }
        }
    }
}

/// One chart: title, the drawing, and what can be done with it.
private struct FlowCard: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let snippet: CodeSnippet
    let graph: FlowGraph
    let colors: AnalysisColors
    @State private var isEnlarged = false

    var body: some View {
        let key = AppModel.flowchartKey(document.id, graph, snippet)
        let diagram = MermaidDiagram(id: graph.id.uuidString, title: graph.title, caption: nil, code: graph.mermaid(palette: colors.mermaid), links: [:])
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(graph.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                adoptButton(key: key)
                CardIconButton(symbol: "doc.on.doc", help: "Mermaid-Code kopieren", colors: colors) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(graph.mermaid(palette: .light), forType: .string)
                }
                CardIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Vergrößern – mit Zoom (Trackpad) und Scrollen", colors: colors) {
                    isEnlarged = true
                }
            }
            MermaidDiagramView(diagram: diagram, palette: colors.mermaid, onNode: { _ in })
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(colors.border))
        .sheet(isPresented: $isEnlarged) {
            EnlargedDiagram(diagram: diagram, colors: colors) { _ in isEnlarged = false }
        }
    }

    @ViewBuilder
    private func adoptButton(key: String) -> some View {
        let isBusy = app.adoptingFlowcharts.contains(key)
        let isDone = app.adoptedFlowcharts.contains(key)
        Button {
            app.adoptFlowchart(graph, of: snippet, in: document.id)
        } label: {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isDone ? "checkmark" : (document.isPresentation ? "rectangle.badge.plus" : "square.and.arrow.down.on.square"))
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(isDone ? (document.isPresentation ? "Folie neu anlegen" : "Erneut übernehmen")
                            : (document.isPresentation ? "Als Folie übernehmen" : "Ins Dokument übernehmen"))
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isDone ? colors.success : colors.accent)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(isDone ? colors.success.opacity(0.12) : colors.accentSoft))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(document.isPresentation
              ? "Das Diagramm kommt auf eine neue Folie hinter der Folie mit dem Code"
              : "Das Diagramm kommt als Bild unter den Code-Block; im LaTeX-Druck erscheint es als Vektorgrafik")
    }
}
