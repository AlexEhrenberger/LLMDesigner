import SwiftUI

/// "Dokument | Inhaltsanalyse" in Writer Studio's top bar (⌥⌘A switches).
struct WriterTabSwitch: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument

    var body: some View {
        HStack(spacing: 2) {
            ForEach(document.isPresentation ? WriterTab.presenterTabs : WriterTab.writerTabs) { tab in
                TabButton(tab: tab, isPresentation: document.isPresentation, isSelected: app.writerTab == tab, badge: badge(for: tab)) {
                    withAnimation(.easeInOut(duration: 0.2)) { app.showWriterTab(tab) }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
        .background {
            Button("") {
                withAnimation(.easeInOut(duration: 0.2)) { app.showWriterTab(app.writerTab == .analysis ? .document : .analysis) }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .opacity(0)
            .allowsHitTesting(false)
        }
        .fixedSize()
    }

    private func badge(for tab: WriterTab) -> TabButton.Badge? {
        guard tab == .analysis else { return nil }
        if app.isAnalyzing(document.id) { return .running }
        if app.isAnalysisOutdated(document) { return .outdated }
        return nil
    }

    private struct TabButton: View {
        enum Badge { case running, outdated }

        let tab: WriterTab
        let isPresentation: Bool
        let isSelected: Bool
        let badge: Badge?
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: tab.symbol(presentation: isPresentation))
                        .font(.system(size: 11, weight: .medium))
                    Text(tab.label(presentation: isPresentation))
                        .font(.system(size: 12, weight: .medium))
                    switch badge {
                    case .running: ProgressView().controlSize(.mini)
                    case .outdated: Circle().fill(Theme.warning).frame(width: 5, height: 5)
                    case nil: EmptyView()
                    }
                }
                .foregroundStyle(isSelected ? Theme.textPrimary : (hovering ? Theme.textSecondary : Theme.textTertiary))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help(help)
        }

        private var help: String {
            switch tab {
            case .document: isPresentation ? "Die Folien bearbeiten (⌥⌘A wechselt zur Inhaltsanalyse)" : "Das Dokument bearbeiten (⌥⌘A wechselt)"
            case .play: "Die Präsentation abspielen – selbst oder von der KI vorgetragen"
            case .analysis:
                switch badge {
                case .running: "Inhaltsanalyse – wird gerade erstellt (⌥⌘A wechselt)"
                case .outdated: "Inhaltsanalyse – der Text hat sich seitdem geändert (⌥⌘A wechselt)"
                case nil: "Inhaltsanalyse: Thesen, Argumente, Figuren, Handlung und Gliederung mit Diagrammen (⌥⌘A wechselt)"
                }
            }
        }
    }
}

/// Takes the formatting toolbar's place while the analysis is shown: its parts (present ones scroll there, missing
/// ones are added), and starting or stopping the analysis.
struct ContentAnalysisToolbar: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @Binding var scrollTarget: ContentAnalysisModule?

    private var hasCode: Bool { !CodeSnippet.snippets(in: document.markdown).isEmpty }

    var body: some View {
        let analysis = app.analysis(of: document.id)
        let progress = app.analysisProgress[document.id]
        let isRunning = progress != nil
        HStack(spacing: 6) {
            Text("Teile")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 6)
            ForEach(ContentAnalysisModule.allCases.filter { $0.isModelWork || hasCode }) { module in
                let state: PartChip.Phase = module == .code ? .present : progress?.current == module ? .running
                    : progress?.pending.contains(module) == true ? .waiting
                    : analysis?.contains(module) == true ? .present : .missing
                PartChip(module: module, state: state, isDisabled: isRunning && state == .missing) {
                    switch state {
                    case .present, .running, .waiting: scrollTarget = module
                    case .missing: app.analyzeDocument(document.id, adding: module)
                    }
                }
            }
            Spacer(minLength: 8)
            if let progress, let current = progress.current {
                Text(current.progressText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ActionButton(title: "Stopp", symbol: "stop.fill", isProminent: false) { app.cancelAnalysis(document.id) }
            } else if analysis == nil {
                ActionButton(title: "Analysieren", symbol: "sparkles", isProminent: true) { app.analyzeDocument(document.id) }
            } else {
                let isOutdated = app.isAnalysisOutdated(document)
                if isOutdated {
                    Text("Text seitdem geändert")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                ActionButton(title: "Neu analysieren", symbol: "arrow.clockwise", isProminent: isOutdated) { app.analyzeDocument(document.id) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private struct PartChip: View {
        enum Phase { case present, running, waiting, missing }

        let module: ContentAnalysisModule
        let state: Phase
        let isDisabled: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    switch state {
                    case .running: ProgressView().controlSize(.mini)
                    case .missing: Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
                    case .present, .waiting: Image(systemName: module.symbol).font(.system(size: 10.5, weight: .medium))
                    }
                    Text(module.label)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(background))
                .overlay(Capsule().strokeBorder(state == .missing ? Theme.border : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(isDisabled)
            .onHover { hovering = $0 }
            .help(help)
        }

        private var foreground: Color {
            if isDisabled { return Theme.textTertiary.opacity(0.5) }
            switch state {
            case .present, .running: return hovering ? Theme.textPrimary : Theme.accent
            case .waiting: return Theme.textSecondary
            case .missing: return hovering ? Theme.textPrimary : Theme.textTertiary
            }
        }

        private var background: Color {
            switch state {
            case .present, .running: Theme.accent.opacity(hovering ? 0.2 : 0.13)
            case .waiting, .missing: hovering && !isDisabled ? Theme.hover : .clear
            }
        }

        private var help: String {
            switch state {
            case .present: "\(module.label): hinspringen"
            case .running: "\(module.label) wird gerade erstellt"
            case .waiting: "\(module.label) folgt"
            case .missing: "\(module.label) ergänzen – \(module.explanation)"
            }
        }
    }

    private struct ActionButton: View {
        let title: String
        let symbol: String
        let isProminent: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isProminent ? .white : (hovering ? Theme.textPrimary : Theme.textSecondary))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(isProminent ? Theme.accent.opacity(hovering ? 1 : 0.85) : (hovering ? Theme.hover : Theme.ink.opacity(0.05))))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
        }
    }
}
