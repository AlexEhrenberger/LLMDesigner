import Foundation

/// Writer Studio's two views of a document; a presentation also has the view that plays it.
enum WriterTab: String, CaseIterable, Identifiable {
    case document, play, analysis

    var id: String { rawValue }

    static let writerTabs: [WriterTab] = [.document, .analysis]
    static let presenterTabs: [WriterTab] = [.document, .play, .analysis]

    func label(presentation: Bool) -> String {
        switch self {
        case .document: presentation ? "Folien" : "Dokument"
        case .play: "Abspielen"
        case .analysis: "Inhaltsanalyse"
        }
    }

    func symbol(presentation: Bool) -> String {
        switch self {
        case .document: presentation ? "rectangle.stack" : "doc.text"
        case .play: "play.rectangle"
        case .analysis: "chart.bar.doc.horizontal"
        }
    }
}

struct ContentAnalysisProgress: Equatable {
    var current: ContentAnalysisModule?
    /// Parts still to come after the current one.
    var pending: [ContentAnalysisModule]

    func includes(_ module: ContentAnalysisModule) -> Bool {
        current == module || pending.contains(module)
    }
}

/// The content analysis of a document: the model reads the whole text and says what kind of text it is, what it
/// argues, who appears in it and what happens, or how it is divided. Each part is one request.
extension AppModel {
    func analysis(of id: WriterDocument.ID) -> ContentAnalysis? {
        documentAnalyses[id]
    }

    /// Reads a document's analysis from disk the first time it is needed.
    func loadAnalysisIfNeeded(_ id: WriterDocument.ID) {
        guard loadedAnalysisIDs.insert(id).inserted, documentAnalyses[id] == nil else { return }
        if let analysis = analysisStore.load(id) { documentAnalyses[id] = analysis }
    }

    func isAnalysisOutdated(_ document: WriterDocument) -> Bool {
        guard let analysis = documentAnalyses[document.id] else { return false }
        return analysis.sourceChecksum != DocumentOutlineBuilder.contentChecksum(document.markdown)
    }

    func isAnalyzing(_ id: WriterDocument.ID) -> Bool {
        analysisProgress[id] != nil
    }

    func showWriterTab(_ tab: WriterTab) {
        guard writerTab != tab else { return }
        writerFlush?()
        writerTab = tab
        if tab == .analysis, let id = selectedDocumentID { loadAnalysisIfNeeded(id) }
    }

    /// Makes the analysis. With a part (`adding`), a current analysis only gets that part; otherwise, or when the
    /// text changed since, everything is made anew: the overview, then the parts it calls for and those the
    /// analysis had.
    func analyzeDocument(_ id: WriterDocument.ID, adding module: ContentAnalysisModule? = nil) {
        writerFlush?()
        guard analysisTasks[id] == nil, let document = document(id) else { return }
        guard let client, let model = currentModelId else {
            analysisErrors[id] = [.overview: "Kein Modell gewählt. Wähle eines unten links in der Seitenleiste („LM Studio verbunden“)."]
            return
        }
        let markdown = document.markdown
        guard DocumentOutlineBuilder.wordCount(markdown) >= ContentAnalysisBuilder.minimumWords else {
            analysisErrors[id] = [.overview: "Der Text ist noch zu kurz für eine Inhaltsanalyse (mindestens \(ContentAnalysisBuilder.minimumWords) Wörter)."]
            return
        }
        loadAnalysisIfNeeded(id)

        let checksum = DocumentOutlineBuilder.contentChecksum(markdown)
        let existing = documentAnalyses[id]
        let paragraphs = DocumentOutlineBuilder.blocks(of: markdown).map {
            ContentAnalysisBuilder.Paragraph(index: $0.index, text: $0.text, isHeading: $0.isHeading, key: $0.key)
        }
        let contextLength = currentModel?.loadedContextLength ?? 8_192
        let source = ContentAnalysisBuilder.source(paragraphs, budget: ContentAnalysisBuilder.budget(contextLength: contextLength))

        let initialPlan: [ContentAnalysisModule]
        let choosesParts: Bool
        let start: ContentAnalysis
        if let module, let existing, existing.sourceChecksum == checksum, existing.overview != nil {
            initialPlan = [module]
            choosesParts = false
            start = existing
        } else {
            let kept = (existing?.modules ?? []) + [module].compactMap { $0 }
            initialPlan = [.overview] + ContentAnalysisModule.allCases.filter { $0 != .overview && kept.contains($0) }
            choosesParts = initialPlan.count == 1
            // The old parts stay visible until their new version arrives.
            start = existing ?? ContentAnalysis(sourceChecksum: checksum, generatedAt: Date(), model: model)
        }
        analysisErrors[id] = nil
        analysisProgress[id] = ContentAnalysisProgress(current: initialPlan.first, pending: Array(initialPlan.dropFirst()))

        let task = Task { [weak self] in
            var plan = initialPlan
            var analysis = start
            var index = 0
            while index < plan.count, !Task.isCancelled {
                let part = plan[index]
                self?.analysisProgress[id] = ContentAnalysisProgress(current: part, pending: Array(plan.dropFirst(index + 1)))
                do {
                    let answer = try await client.complete(
                        model: model,
                        messages: ContentAnalysisBuilder.messages(for: part, source: source),
                        temperature: 0.2,
                        maxTokens: ContentAnalysisBuilder.maxTokens(part),
                        orderedSchema: (ContentAnalysisBuilder.schemaName(part), ContentAnalysisBuilder.schema(part).json)
                    )
                    try ContentAnalysisBuilder.apply(answer, module: part, source: source, to: &analysis)
                    if part == .overview, choosesParts, let overview = analysis.overview {
                        plan += ContentAnalysisBuilder.modules(after: overview).filter { !plan.contains($0) }
                    }
                    analysis.sourceChecksum = checksum
                    analysis.generatedAt = Date()
                    analysis.model = model
                    analysis.isShortened = source.isShortened
                    guard let self else { return }
                    self.documentAnalyses[id] = analysis
                    if self.document(id) != nil { self.analysisStore.save(analysis, for: id) }
                } catch {
                    guard !Task.isCancelled else { break }
                    self?.analysisErrors[id, default: [:]][part] = error.localizedDescription
                    // Without an overview there is nothing to choose the parts from.
                    if part == .overview, choosesParts { break }
                }
                index += 1
            }
            self?.analysisProgress[id] = nil
            self?.analysisTasks[id] = nil
        }
        analysisTasks[id] = task
    }

    func cancelAnalysis(_ id: WriterDocument.ID) {
        analysisTasks[id]?.cancel()
        analysisTasks[id] = nil
        analysisProgress[id] = nil
    }

    /// When a document goes, so does its analysis.
    func deleteAnalysis(_ id: WriterDocument.ID) {
        cancelAnalysis(id)
        documentAnalyses[id] = nil
        analysisErrors[id] = nil
        analysisStore.delete(id)
    }
}
