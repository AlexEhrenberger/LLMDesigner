import SwiftUI

/// Colours of the analysis page; they follow the sheet (dark or white paper) like the document.
struct AnalysisColors {
    let windowBackground: Color
    let page: Color
    let pageBorder: Color
    let card: Color
    let border: Color
    let hover: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let accentSoft: Color
    let success: Color
    let danger: Color
    let warning: Color
    let mermaid: MermaidPalette

    static func make(lightPaper: Bool) -> AnalysisColors {
        let palette = lightPaper ? WriterPalette.light : WriterPalette.dark
        return AnalysisColors(
            windowBackground: Color(nsColor: palette.windowBackground),
            page: Color(nsColor: palette.page),
            pageBorder: Color(nsColor: palette.pageBorder),
            card: lightPaper ? Color(hex: 0xFAFAFC) : Color(hex: 0x18181C),
            border: lightPaper ? Color.black.opacity(0.08) : Color.white.opacity(0.07),
            hover: lightPaper ? Color.black.opacity(0.05) : Color.white.opacity(0.06),
            text: Color(nsColor: palette.text),
            secondaryText: Color(nsColor: palette.secondaryText),
            tertiaryText: Color(nsColor: palette.tertiaryText),
            accent: Color(nsColor: palette.accent),
            accentSoft: Color(nsColor: palette.accent).opacity(lightPaper ? 0.09 : 0.13),
            success: lightPaper ? Color(hex: 0x1E9E61) : Theme.success,
            danger: lightPaper ? Color(hex: 0xD64545) : Theme.danger,
            warning: lightPaper ? Color(hex: 0xC27C0E) : Theme.warning,
            mermaid: lightPaper ? .light : .dark
        )
    }
}

/// Writer Studio's second tab: what the document says, with diagrams. The overview at the top, then the parts
/// that fit the text (argumentation, characters and plot, structure).
struct ContentAnalysisView: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let colors: AnalysisColors
    @Binding var scrollTarget: ContentAnalysisModule?
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        let analysis = app.analysis(of: document.id)
        let progress = app.analysisProgress[document.id]
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if analysis == nil, progress == nil {
                        AnalysisStart(document: document, colors: colors)
                    } else {
                        notes(analysis, isRunning: progress != nil)
                        OverviewSection(analysis: analysis?.overview, progress: progress, error: errors[.overview], colors: colors, document: document)
                            .id(ContentAnalysisModule.overview)
                        ForEach(sections(analysis, progress)) { module in
                            section(module, analysis: analysis, progress: progress)
                                .id(module)
                        }
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 38)
                .frame(maxWidth: 1000, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.page))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.pageBorder))
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 60)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
        .background(colors.windowBackground)
    }

    private var errors: [ContentAnalysisModule: String] {
        app.analysisErrors[document.id] ?? [:]
    }

    /// The parts after the overview: those the analysis has and those being made.
    private func sections(_ analysis: ContentAnalysis?, _ progress: ContentAnalysisProgress?) -> [ContentAnalysisModule] {
        ContentAnalysisModule.allCases.filter { module in
            module != .overview && (analysis?.contains(module) == true || progress?.includes(module) == true || errors[module] != nil)
        }
    }

    @ViewBuilder
    private func notes(_ analysis: ContentAnalysis?, isRunning: Bool) -> some View {
        if !isRunning, app.isAnalysisOutdated(document) {
            NoteBanner(
                symbol: "clock.arrow.circlepath",
                text: "Der Text hat sich seit der Analyse geändert.",
                action: "Neu analysieren",
                tint: colors.warning,
                colors: colors
            ) { app.analyzeDocument(document.id) }
        }
        if analysis?.isShortened == true {
            NoteBanner(
                symbol: "scissors",
                text: "Das Dokument ist länger, als das Modell auf einmal lesen kann. Die Absätze wurden für die Analyse gekürzt – mehr Kontext (16K oder 32K) liest mehr davon.",
                action: nil,
                tint: colors.secondaryText,
                colors: colors
            ) {}
        }
    }

    @ViewBuilder
    private func section(_ module: ContentAnalysisModule, analysis: ContentAnalysis?, progress: ContentAnalysisProgress?) -> some View {
        let isRunning = progress?.current == module
        let isWaiting = progress?.pending.contains(module) == true
        VStack(alignment: .leading, spacing: 16) {
            // While the part has no content yet, its placeholder card says what is happening.
            SectionHeader(module: module, isRunning: isRunning && analysisHas(module, analysis), isWaiting: isWaiting && analysisHas(module, analysis), colors: colors)
            if let error = errors[module], !isRunning {
                ErrorCard(text: error, colors: colors) { app.analyzeDocument(document.id, adding: module) }
            }
            switch module {
            case .overview:
                EmptyView()
            case .argumentation:
                if let argumentation = analysis?.argumentation {
                    ArgumentationSection(argumentation: argumentation, colors: colors, onJump: onJump)
                } else {
                    PendingCard(module: module, isRunning: isRunning, colors: colors)
                }
            case .narrative:
                if let narrative = analysis?.narrative {
                    NarrativeSection(narrative: narrative, colors: colors, onJump: onJump)
                } else {
                    PendingCard(module: module, isRunning: isRunning, colors: colors)
                }
            case .structure:
                if let structure = analysis?.structure {
                    StructureSection(structure: structure, colors: colors, onJump: onJump)
                } else {
                    PendingCard(module: module, isRunning: isRunning, colors: colors)
                }
            }
        }
        .opacity(isRunning && analysisHas(module, analysis) ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: isRunning)
    }

    private func analysisHas(_ module: ContentAnalysisModule, _ analysis: ContentAnalysis?) -> Bool {
        analysis?.contains(module) == true
    }
}

// MARK: Start

/// Before the first analysis: what it does, and a button to start it (or one part only).
private struct AnalysisStart: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let colors: AnalysisColors

    var body: some View {
        let words = DocumentOutlineBuilder.wordCount(document.markdown)
        let isLongEnough = words >= ContentAnalysisBuilder.minimumWords
        VStack(spacing: 18) {
            Image(systemName: WriterTab.analysis.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(colors.accent)
                .padding(.top, 30)
            Text("Inhaltsanalyse")
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(colors.text)
            Text("Das Modell liest das ganze Dokument und zeigt, was darin steht – je nach Art des Textes: bei einer Argumentation die Hauptthese, die Argumente mit Prämissen und Konklusion und die Einwände als Argumentkarte; bei einer Erzählung die Figuren, ihre Beziehungen und den Verlauf der Handlung; bei einer Beschreibung die Bereiche, Aufzählungen und Abläufe als Diagramm.")
                .font(.system(size: 14))
                .foregroundStyle(colors.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
            if let error = app.analysisErrors[document.id]?[.overview] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                app.analyzeDocument(document.id)
            } label: {
                Label("Analyse starten", systemImage: "sparkles")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.accent.opacity(isLongEnough ? 0.9 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!isLongEnough)
            if isLongEnough {
                VStack(spacing: 8) {
                    Text("Oder gezielt:")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.tertiaryText)
                    HStack(spacing: 8) {
                        ForEach([ContentAnalysisModule.argumentation, .narrative, .structure]) { module in
                            ModuleStartButton(module: module, colors: colors) { app.analyzeDocument(document.id, adding: module) }
                        }
                    }
                }
            } else {
                Text("Dafür braucht es etwas mehr Text: mindestens \(ContentAnalysisBuilder.minimumWords) Wörter (bisher \(words)).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.tertiaryText)
            }
            Text("Analysiert wird mit dem Modell, das in LM Studio gewählt ist (unten links in der Seitenleiste). Je nach Länge dauert das eine bis zwei Minuten; die Teile erscheinen, sobald sie fertig sind.")
                .font(.system(size: 11.5))
                .foregroundStyle(colors.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ModuleStartButton: View {
    let module: ContentAnalysisModule
    let colors: AnalysisColors
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(module.label, systemImage: module.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? colors.text : colors.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(hovering ? colors.hover : .clear))
                .overlay(Capsule().strokeBorder(colors.border))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(module.explanation)
    }
}

// MARK: Overview

private struct OverviewSection: View {
    let analysis: AnalysisOverview?
    let progress: ContentAnalysisProgress?
    let error: String?
    let colors: AnalysisColors
    let document: WriterDocument
    @Environment(AppModel.self) private var app

    var body: some View {
        if let overview = analysis {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Label(overview.kind.rawValue, systemImage: overview.kind.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(colors.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(colors.accentSoft))
                    if progress?.current == .overview {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    if let meta = meta { Text(meta).font(.system(size: 11)).foregroundStyle(colors.tertiaryText) }
                }
                Text(overview.topic)
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                    .foregroundStyle(colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(overview.summary)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(colors.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !overview.keyStatements.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SmallHeading("Kernaussagen", colors: colors)
                        ForEach(Array(overview.keyStatements.enumerated()), id: \.offset) { index, statement in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                                    .foregroundStyle(colors.accent)
                                    .frame(width: 16, alignment: .trailing)
                                Text(statement)
                                    .font(.system(size: 14))
                                    .foregroundStyle(colors.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if !overview.keywords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SmallHeading("Schlüsselbegriffe", colors: colors)
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(overview.keywords, id: \.self) { Chip(text: $0, colors: colors) }
                        }
                    }
                }
            }
        } else if let error {
            ErrorCard(text: error, colors: colors) { app.analyzeDocument(document.id) }
        } else {
            PendingCard(module: .overview, isRunning: progress?.current == .overview, colors: colors)
        }
    }

    private var meta: String? {
        guard let analysis = app.analysis(of: document.id) else { return nil }
        let model = analysis.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let date = analysis.generatedAt.formatted(.relative(presentation: .named))
        return [model, date].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: Argumentation

private struct ArgumentationSection: View {
    let argumentation: ArgumentAnalysis
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !argumentation.thesis.isEmpty {
                JumpArea(anchor: argumentation.thesisAnchor, colors: colors, onJump: onJump) {
                    VStack(alignment: .leading, spacing: 6) {
                        SmallHeading("Hauptthese", colors: colors, tint: colors.accent)
                        Text(argumentation.thesis)
                            .font(.system(size: 16, weight: .medium, design: .serif))
                            .foregroundStyle(colors.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.accentSoft))
                    .overlay(alignment: .leading) {
                        UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                            .fill(colors.accent)
                            .frame(width: 3)
                    }
                }
            }
            ForEach(ContentAnalysisDiagrams.diagrams(for: .argumentation, in: wrapped, palette: colors.mermaid)) { diagram in
                DiagramCard(diagram: diagram, colors: colors, onJump: onJump)
            }
            if !argumentation.arguments.isEmpty {
                SmallHeading("Die Argumente in Standardform", colors: colors)
                    .padding(.top, 4)
                VStack(spacing: 12) {
                    ForEach(Array(argumentation.arguments.enumerated()), id: \.offset) { index, argument in
                        ArgumentCard(number: index + 1, argument: argument, supports: argumentation.supportedArgument(of: index), colors: colors, onJump: onJump)
                    }
                }
            }
            if !argumentation.objections.isEmpty {
                SmallHeading("Einwände und Erwiderungen", colors: colors)
                    .padding(.top, 4)
                VStack(spacing: 10) {
                    ForEach(Array(argumentation.objections.enumerated()), id: \.offset) { _, objection in
                        ObjectionCard(objection: objection, arguments: argumentation.arguments, colors: colors, onJump: onJump)
                    }
                }
            }
            if !argumentation.strengths.isEmpty || !argumentation.weaknesses.isEmpty {
                SmallHeading("Einschätzung des Modells", colors: colors)
                    .padding(.top, 4)
                HStack(alignment: .top, spacing: 12) {
                    AssessmentList(title: "Stärken", symbol: "checkmark.circle.fill", items: argumentation.strengths, tint: colors.success, colors: colors)
                    AssessmentList(title: "Schwächen", symbol: "exclamationmark.circle.fill", items: argumentation.weaknesses, tint: colors.warning, colors: colors)
                }
            }
        }
    }

    private var wrapped: ContentAnalysis {
        var analysis = ContentAnalysis(sourceChecksum: 0, generatedAt: .distantPast)
        analysis.argumentation = argumentation
        return analysis
    }
}

/// P1, P2 … over a line, the conclusion under it: the classic way to write down an argument.
private struct ArgumentCard: View {
    let number: Int
    let argument: ArgumentAnalysis.Argument
    let supports: Int?
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(colors.accent)
                Text(argument.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.text)
                Spacer(minLength: 8)
                if !argument.inference.isEmpty {
                    Text(argument.inference)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(Capsule().strokeBorder(colors.border))
                        .help("Schlussart: wie aus den Prämissen auf die Konklusion geschlossen wird")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(argument.premises.enumerated()), id: \.offset) { index, premise in
                    JumpArea(anchor: premise.anchor, colors: colors, onJump: onJump) {
                        StatementRow(
                            label: "P\(index + 1)",
                            text: premise.text,
                            note: premise.isImplicit ? "implizit – vom Modell ergänzt" : nil,
                            isQuiet: premise.isImplicit,
                            colors: colors
                        )
                    }
                }
                Rectangle()
                    .fill(colors.secondaryText.opacity(0.5))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                JumpArea(anchor: argument.anchor, colors: colors, onJump: onJump) {
                    StatementRow(label: "∴ K", text: argument.conclusion, note: nil, isQuiet: false, isStrong: true, colors: colors)
                }
            }
            Text(supports.map { "stützt Argument \($0 + 1)" } ?? "stützt die Hauptthese")
                .font(.system(size: 11))
                .foregroundStyle(colors.tertiaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.border))
    }
}

private struct StatementRow: View {
    let label: String
    let text: String
    let note: String?
    let isQuiet: Bool
    var isStrong = false
    let colors: AnalysisColors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isStrong ? colors.accent : colors.tertiaryText)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 13.5, weight: isStrong ? .medium : .regular))
                    .italic(isQuiet)
                    .foregroundStyle(isQuiet ? colors.secondaryText : colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(colors.tertiaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ObjectionCard: View {
    let objection: ArgumentAnalysis.Objection
    let arguments: [ArgumentAnalysis.Argument]
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        JumpArea(anchor: objection.anchor, colors: colors, onJump: onJump) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(colors.danger)
                        Text(objection.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(colors.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !objection.rebuttal.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colors.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erwiderung im Text")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(colors.success)
                            Text(objection.rebuttal)
                                .font(.system(size: 13.5))
                                .foregroundStyle(colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Der Text geht auf diesen Einwand nicht ein.")
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundStyle(colors.tertiaryText)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.border))
        }
    }

    private var target: String {
        guard let index = objection.target, arguments.indices.contains(index) else { return "EINWAND GEGEN DIE HAUPTTHESE" }
        return "EINWAND GEGEN ARGUMENT \(index + 1)"
    }
}

private struct AssessmentList: View {
    let title: String
    let symbol: String
    let items: [String]
    let tint: Color
    let colors: AnalysisColors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            if items.isEmpty {
                Text("—").foregroundStyle(colors.tertiaryText)
            }
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.border))
    }
}

// MARK: Narrative

private struct NarrativeSection: View {
    let narrative: NarrativeAnalysis
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        let diagrams = ContentAnalysisDiagrams.diagrams(for: .narrative, in: wrapped, palette: colors.mermaid)
        VStack(alignment: .leading, spacing: 18) {
            let facts = [("Erzählperspektive", narrative.perspective), ("Zeit", narrative.time), ("Konflikt", narrative.conflict)]
                .filter { !$0.1.isEmpty }
            if !facts.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(facts, id: \.0) { fact in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(fact.0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(colors.tertiaryText)
                            Text(fact.1)
                                .font(.system(size: 13.5))
                                .foregroundStyle(colors.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let map = diagrams.first(where: { $0.id == "figuren" }) {
                DiagramCard(diagram: map, colors: colors, onJump: onJump)
            }
            if !narrative.characters.isEmpty {
                SmallHeading("Figuren", colors: colors)
                    .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(narrative.characters, id: \.name) { character in
                        CharacterCard(character: character, colors: colors, onJump: onJump)
                    }
                }
            }
            if let plot = diagrams.first(where: { $0.id == "handlung" }) {
                DiagramCard(diagram: plot, colors: colors, onJump: onJump)
            } else if !narrative.events.isEmpty {
                SmallHeading("Handlung", colors: colors)
                ForEach(Array(narrative.events.enumerated()), id: \.offset) { _, event in
                    JumpArea(anchor: event.anchor, colors: colors, onJump: onJump) {
                        Text(event.text).font(.system(size: 13.5)).foregroundStyle(colors.text)
                    }
                }
            }
            if !narrative.places.isEmpty {
                SmallHeading("Schauplätze", colors: colors)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(narrative.places, id: \.name) { place in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11))
                                .foregroundStyle(colors.accent)
                            Text(place.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(colors.text)
                            if !place.description.isEmpty {
                                Text(place.description)
                                    .font(.system(size: 13))
                                    .foregroundStyle(colors.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !narrative.motifs.isEmpty {
                SmallHeading("Motive und Themen", colors: colors)
                    .padding(.top, 4)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(narrative.motifs, id: \.self) { Chip(text: $0, colors: colors) }
                }
            }
        }
    }

    private var wrapped: ContentAnalysis {
        var analysis = ContentAnalysis(sourceChecksum: 0, generatedAt: .distantPast)
        analysis.narrative = narrative
        return analysis
    }
}

private struct CharacterCard: View {
    let character: NarrativeAnalysis.Character
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        JumpArea(anchor: character.anchor, colors: colors, onJump: onJump) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(character.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.text)
                    Spacer(minLength: 4)
                    Text(character.role.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(roleTint)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(roleTint.opacity(0.13)))
                }
                if !character.description.isEmpty {
                    Text(character.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.border))
        }
    }

    private var roleTint: Color {
        switch character.role {
        case .protagonist: colors.accent
        case .antagonist: colors.danger
        case .supporting: colors.secondaryText
        case .mentioned: colors.tertiaryText
        }
    }
}

// MARK: Structure

private struct StructureSection: View {
    let structure: StructureAnalysis
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void

    var body: some View {
        let diagrams = ContentAnalysisDiagrams.diagrams(for: .structure, in: wrapped, palette: colors.mermaid)
        VStack(alignment: .leading, spacing: 18) {
            if diagrams.isEmpty {
                Text("Das Modell hat keine Gliederung gefunden.")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.tertiaryText)
            }
            ForEach(diagrams) { diagram in
                DiagramCard(diagram: diagram, colors: colors, onJump: onJump)
            }
        }
    }

    private var wrapped: ContentAnalysis {
        var analysis = ContentAnalysis(sourceChecksum: 0, generatedAt: .distantPast)
        analysis.structure = structure
        return analysis
    }
}

// MARK: Pieces

private struct SectionHeader: View {
    let module: ContentAnalysisModule
    let isRunning: Bool
    let isWaiting: Bool
    let colors: AnalysisColors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(colors.border).frame(height: 1)
            HStack(spacing: 9) {
                Image(systemName: module.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.accent)
                Text(module.label)
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .foregroundStyle(colors.text)
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text(module.progressText)
                        .font(.system(size: 12))
                        .foregroundStyle(colors.tertiaryText)
                } else if isWaiting {
                    Text("wird erneuert …")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
    }
}

/// Where a part will appear: a spinner while the model works on it, otherwise a note that it comes next.
private struct PendingCard: View {
    let module: ContentAnalysisModule
    let isRunning: Bool
    let colors: AnalysisColors

    var body: some View {
        HStack(spacing: 12) {
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "hourglass")
                    .foregroundStyle(colors.tertiaryText)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isRunning ? module.progressText : "\(module.label) folgt …")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondaryText)
                Text(module.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct ErrorCard: View {
    let text: String
    let colors: AnalysisColors
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colors.warning)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Erneut versuchen", action: retry)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.warning.opacity(0.1)))
    }
}

private struct NoteBanner: View {
    let symbol: String
    let text: String
    let action: String?
    let tint: Color
    let colors: AnalysisColors
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.1)))
    }
}

private struct SmallHeading: View {
    let title: String
    let colors: AnalysisColors
    var tint: Color?

    init(_ title: String, colors: AnalysisColors, tint: Color? = nil) {
        self.title = title
        self.colors = colors
        self.tint = tint
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(tint ?? colors.tertiaryText)
    }
}

private struct Chip: View {
    let text: String
    let colors: AnalysisColors

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(colors.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(Capsule().fill(colors.hover))
            .overlay(Capsule().strokeBorder(colors.border))
    }
}

/// Content that leads to its place in the document: highlighted on hover, a click switches to the document.
private struct JumpArea<Content: View>: View {
    let anchor: DocumentAnchor?
    let colors: AnalysisColors
    let onJump: (DocumentAnchor) -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        if let anchor {
            content()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(colors.accent)
                        .padding(5)
                        .opacity(hovering ? 1 : 0)
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? colors.hover : .clear).padding(-3))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { onJump(anchor) }
                .help("Zur Stelle im Text springen")
        } else {
            content()
        }
    }
}
