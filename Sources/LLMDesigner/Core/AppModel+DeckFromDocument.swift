import SwiftUI

/// What the sheet "Präsentation aus Dokument" starts from (nil: the user chooses first).
struct DeckSourceRequest: Identifiable {
    let id = UUID()
    var material: DeckMaterial?
}

/// What goes into a presentation made from a document.
struct DeckSourceOptions: Equatable {
    /// The model writes a speaker card ("Moderatorenkarte") for every slide.
    var notes = true
    /// Formulas, code, tables and pictures of a section go onto its slide as they are.
    var carriesObjects = true
    /// Then the presentation starts at once, spoken by the model.
    var presents = false
}

/// A presentation from any document: its headings give chapters and slides (a text without them is divided by the
/// model), the model sums each section up in points, formulas, code, tables and pictures are taken over, and the
/// speaker cards and the automatic presentation follow.
extension AppModel {
    // MARK: Material

    func deckMaterial(from document: WriterDocument) -> DeckMaterial {
        // The slides get their own layout: the document's alignment and print sizes stay behind.
        DeckMaterial(title: document.displayTitle, markdown: WriterMarkdown.forOtherLayout(document.markdown), sourceName: document.displayTitle)
    }

    func deckMaterial(from url: URL) throws -> DeckMaterial {
        let markdown = try DocumentText.markdown(from: url)
        let name = url.deletingPathExtension().lastPathComponent
        // A heading at the very top is the title; otherwise the file's name is.
        let first = markdown.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let title = first.hasPrefix("# ") ? WriterHeadings.plainTitle(WriterMarkdown.headingAttributes(String(first.dropFirst(2))).text) : name
        return DeckMaterial(title: title.isEmpty ? name : title, markdown: markdown, sourceName: url.lastPathComponent)
    }

    /// Opens the sheet for the document in Writer Studio, or without a source (the sheet then asks).
    func showDeckFromDocument(_ document: WriterDocument? = nil) {
        writerFlush?()
        let source = document.flatMap { self.document($0.id) } ?? selectedDocument.flatMap { $0.isPresentation ? nil : $0 }
        deckSourceRequest = DeckSourceRequest(material: source.map(deckMaterial(from:)))
    }

    // MARK: Making it

    func createPresentation(from material: DeckMaterial, options: DeckSourceOptions) {
        guard deckGeneration?.isRunning != true else { return }
        closeDocument()
        searchText = ""
        var document = WriterDocument.newPresentation()
        document.folderID = newChatFolderID
        document.title = material.title
        document.hasCustomTitle = true
        documents.insert(document, at: 0)
        if let folderID = document.folderID { expandFolder(folderID) }
        showChats()
        writerTab = .document
        selectedSlideID = document.deck?.slides.first?.id
        selectedDocumentID = document.id
        let id = document.id
        let before = document.deck ?? .new()
        guard let client, let model = currentModelId else {
            deckGeneration = DeckGeneration(documentID: id, phase: .failed("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste."), before: before, replacedEmpty: true)
            return
        }
        deckGeneration = DeckGeneration(documentID: id, phase: .outlining, before: before, replacedEmpty: true)
        let contextLength = currentModel?.loadedContextLength ?? 8_192
        let titleSlideID = before.slides.first?.id ?? UUID()

        deckGenerationTask = Task { [weak self] in
            do {
                // The plan: from the headings, else the model divides the text.
                var plan: DeckPlan
                if let fromHeadings = DocumentDeckPlanner.plan(for: material) {
                    plan = fromHeadings
                    if plan.subtitle.isEmpty {
                        let excerpt = DeckObjects.textForModel(material.markdown, limit: 1_200)
                        if let answer = try? await client.complete(model: model, messages: PresenterPrompts.subtitleMessages(title: plan.title, text: excerpt), temperature: 0.4, maxTokens: 60) {
                            plan.subtitle = Self.slideLine(PresenterPrompts.cleanNotes(answer))
                        }
                    }
                } else {
                    plan = try await Self.planWithModel(material, client: client, model: model, contextLength: contextLength)
                }
                try Task.checkCancellation()
                guard let self else { return }

                // The skeleton: title, chapters and slides with their titles.
                var slides: [PresentationSlide] = []
                var work: [(slide: PresentationSlide, chapter: String?, plan: DeckPlan.Slide)] = []
                var chapterSources: [(id: PresentationSlide.ID, text: String)] = []
                let title = plan.title.isEmpty ? material.title : plan.title
                let titleSlide = PresentationSlide(
                    id: titleSlideID, role: .title,
                    markdown: "# \(Self.slideLine(title)) {.chapter}" + (plan.subtitle.isEmpty ? "" : "\n\n" + Self.slideLine(plan.subtitle))
                )
                for chapter in plan.chapters {
                    if let chapterTitle = chapter.title {
                        let slide = PresentationSlide(role: .chapter, markdown: "# \(Self.slideLine(chapterTitle)) {.chapter}")
                        slides.append(slide)
                        if !chapter.introduction.isEmpty { chapterSources.append((slide.id, DeckObjects.textForModel(chapter.introduction, limit: 1_500))) }
                    }
                    for item in chapter.slides {
                        let slide = PresentationSlide(role: .content, markdown: "# " + Self.slideLine(item.title))
                        slides.append(slide)
                        work.append((slide, chapter.title, item))
                    }
                }
                self.modifyDeck(id) { deck in
                    deck.slides = [titleSlide] + slides
                    return true
                }
                let created = [titleSlide.id] + slides.map(\.id)
                self.deckGeneration?.created = created
                if self.selectedDocumentID == id { self.selectedSlideID = created.first }
                self.deckSources[titleSlide.id] = DeckObjects.textForModel(material.markdown, limit: 1_500)
                for source in chapterSources { self.deckSources[source.id] = source.text }

                // The points, slide by slide.
                let titles = work.map { Self.slideLine($0.plan.title) }
                let passageLimit = min(3_000, max(1_200, (contextLength - 3_000) * 2))
                for (number, item) in work.enumerated() {
                    try Task.checkCancellation()
                    self.deckGeneration?.phase = .filling(done: number, total: work.count)
                    let objects = options.carriesObjects ? DeckObjects.extract(from: item.plan.passage) : DeckObjects()
                    let text = DeckObjects.textForModel(item.plan.passage, limit: passageLimit)
                    self.deckSources[item.slide.id] = text
                    var points: [String] = []
                    if !text.isEmpty {
                        let answer = try await client.complete(
                            model: model,
                            messages: PresenterPrompts.slideFromTextMessages(
                                presentationTitle: title, chapter: item.chapter, slideTitles: titles, slideTitle: Self.slideLine(item.plan.title),
                                passage: text, hint: item.plan.hint, carriesObjects: !objects.isEmpty
                            ),
                            temperature: 0.3,
                            maxTokens: 900,
                            orderedSchema: ("folie", PresenterPrompts.slideSchema.json)
                        )
                        try Task.checkCancellation()
                        let content = try? JSONDecoder().decode(PresenterPrompts.SlideContent.self, from: Data(ContentAnalysisBuilder.jsonObject(in: answer).utf8))
                        points = (content?.punkte ?? []).map(Self.slidePoint).compactMap(DeckObjects.removingNotes(from:))
                    }
                    // A slide with a formula, code or a table has room for fewer points.
                    var parts = ["# " + Self.slideLine(item.plan.title)]
                    let hasBlock = !objects.math.isEmpty || !objects.code.isEmpty || !objects.tables.isEmpty
                    let limited = Array(points.prefix(hasBlock ? 3 : 5))
                    if !limited.isEmpty { parts.append(limited.map { "- " + $0 }.joined(separator: "\n")) }
                    parts += objects.math + objects.code + objects.tables
                    let markdown = parts.joined(separator: "\n\n")
                    self.modifyDeck(id) { deck in
                        guard let index = deck.index(of: item.slide.id) else { return false }
                        deck.slides[index].markdown = markdown
                        if let image = objects.images.first, WriterImageStore.url(for: image.source) != nil {
                            let size = WriterImageStore.url(for: image.source).flatMap(WriterImageStore.naturalSize(of:))
                            let aspect = size.map { Double($0.width / max(1, $0.height)) } ?? 1.5
                            deck.slides[index].images = [SlideImage(source: image.source, caption: image.caption, frame: SlideImage.defaultFrame(aspect: aspect))]
                        }
                        return true
                    }
                }
                self.deckGeneration?.phase = .finished
                if options.notes { self.writeSpeakerNotes(id, slides: created) }
                if options.presents { self.presentWithAI(id) }
            } catch {
                guard let self else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                    self.deckGeneration?.phase = .stopped
                } else {
                    self.deckGeneration?.phase = .failed(error.localizedDescription)
                }
            }
            self?.deckGenerationTask = nil
        }
    }

    /// A text without usable headings: the model divides it into chapters and slides over numbered paragraphs.
    private static func planWithModel(_ material: DeckMaterial, client: LMStudioClient, model: String, contextLength: Int) async throws -> DeckPlan {
        let paragraphs = DocumentOutlineBuilder.blocks(of: material.markdown).map {
            ContentAnalysisBuilder.Paragraph(index: $0.index, text: $0.text, isHeading: $0.isHeading, key: $0.key)
        }
        guard !paragraphs.isEmpty else { throw LMStudioError.server("Im Dokument steht kein Text, aus dem sich Folien machen ließen.") }
        let source = ContentAnalysisBuilder.source(paragraphs, budget: ContentAnalysisBuilder.budget(contextLength: contextLength))
        let answer = try await client.complete(
            model: model,
            messages: PresenterPrompts.documentOutlineMessages(source: source, title: material.title),
            temperature: 0.3,
            maxTokens: 2_500,
            orderedSchema: ("gliederung", PresenterPrompts.documentOutlineSchema.json)
        )
        let outline = try JSONDecoder().decode(PresenterPrompts.DocumentOutline.self, from: Data(ContentAnalysisBuilder.jsonObject(in: answer).utf8))
        guard outline.kapitel.contains(where: { !$0.folien.isEmpty }) else { throw LMStudioError.server("Das Modell hat keine Gliederung geliefert.") }

        // The Markdown of each block, so a slide's passage keeps its formulas, code and tables.
        let blocks = MarkdownParser.parse(WriterBookmark.strip(material.markdown)).map(DeckBlockText.markdown(of:))
        func passage(from: Int, to: Int) -> String {
            let low = max(0, min(from, to)), high = min(blocks.count - 1, max(from, to))
            guard low <= high else { return "" }
            return blocks[low...high].joined(separator: "\n\n")
        }
        var chapters: [DeckPlan.Chapter] = []
        for chapter in outline.kapitel where !chapter.folien.isEmpty {
            let slides = chapter.folien.map { DeckPlan.Slide(title: $0.titel, passage: passage(from: $0.von, to: $0.bis)) }
            chapters.append(DeckPlan.Chapter(title: slideLine(chapter.titel), slides: slides))
        }
        return DeckPlan(title: slideLine(outline.titel).isEmpty ? material.title : slideLine(outline.titel), subtitle: slideLine(outline.untertitel), chapters: chapters)
    }
}

/// A Markdown block as text again (for passages of a document that was read as blocks).
enum DeckBlockText {
    static func markdown(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let text): text
        case .heading(let level, let text): String(repeating: "#", count: max(1, min(level, 3))) + " " + text
        case .code(let language, let code): "```\(language)\n\(code)\n```"
        case .list(let items):
            items.map { String(repeating: "  ", count: $0.level) + ($0.marker ?? "-") + " " + $0.text }.joined(separator: "\n")
        case .quote(let text): text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        case .table(let header, let rows, _, _):
            ([header] + rows).enumerated().flatMap { index, cells -> [String] in
                let line = "| " + cells.joined(separator: " | ") + " |"
                return index == 0 ? [line, "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"] : [line]
            }.joined(separator: "\n")
        case .math(let latex, _): "$$\n\(latex)\n$$"
        case .rule: "---"
        }
    }
}
