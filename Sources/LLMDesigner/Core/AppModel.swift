import SwiftUI
import Observation
import UniformTypeIdentifiers

enum ConnectionState: Equatable {
    case connecting
    case connected
    case failed(String)
}

enum SidePanelTab: Hashable {
    case contents, bookmarks
    /// Writer Studio only: Citation Studio's sources and quotes, ready to insert.
    case sources
    /// Writer Studio only: the comments on the document.
    case comments
}

/// What the sidebar lists, and with it what the main area shows: chats, the skill library or the personas.
enum SidebarMode: Hashable {
    case chats, skills, personas
}

/// Request to scroll the message list to a place; the token makes repeated jumps to the same place count.
struct ScrollRequest: Equatable {
    let target: OutlineTarget
    let token = UUID()
}

/// The text of an answer while it is being written. It changes many times a second, so it lives apart from `chats`:
/// only the answer's own view follows it, not everything that shows the chats (sidebar, menus, settings), which
/// otherwise kept the main thread so busy that the answer fell minutes behind the model. The chat gets the text at the
/// end of each round.
@MainActor
@Observable
final class LiveAnswer {
    var content = ""
    var reasoning = ""
}

struct ChatGroup: Identifiable {
    let id: String
    let entries: [SidebarEntry]
}

/// A line in the chat list: a chat or a Writer Studio document.
enum SidebarEntry: Identifiable {
    case chat(Chat)
    case document(WriterDocument)

    var id: UUID {
        switch self {
        case .chat(let chat): chat.id
        case .document(let document): document.id
        }
    }

    var updatedAt: Date {
        switch self {
        case .chat(let chat): chat.updatedAt
        case .document(let document): document.updatedAt
        }
    }

    var folderID: Folder.ID? {
        switch self {
        case .chat(let chat): chat.folderID
        case .document(let document): document.folderID
        }
    }
}

/// A folder with the chats or skills in it, as the sidebar lists it.
struct FolderSection<Item>: Identifiable {
    let folder: Folder
    let items: [Item]
    var id: Folder.ID { folder.id }
}

@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let provider = "provider"
        static let appearance = "appearance"
        static let systemPrompt = "systemPrompt"
        static let temperature = "temperature"
        static let useCustomTemperature = "useCustomTemperature"
        static let sidebarVisible = "sidebarVisible"
        static let pdfPaperSize = "pdfPaperSize"
        static let pdfSpeakerLineEnabled = "pdfSpeakerLineEnabled"
        static let pdfSpeakerTemplate = "pdfSpeakerTemplate"
        static let pdfOpenAfterExport = "pdfOpenAfterExport"
        static let outlinePanelVisible = "outlinePanelVisible"
        static let suggestFollowUps = "suggestFollowUps"
        static let dictationMode = "dictationMode"
        static let speechEngine = "speechEngine"
        static let qwenVoice = "qwenVoice"
        static let speechRate = "speechRate"
        static let webReaderFallback = "webReaderFallback"
        static let thinkingDefault = "thinkingDefault"
        static let conversationPause = "conversationPause"
        static let memoryDefault = "memoryDefault"
        static let contextDefault = "contextDefault"
        static let writerLightPaper = "writerLightPaper"
        static let writerPageTemplates = "writerPageTemplates"
        static let writerReadsAnswers = "writerReadsAnswers"
        static let presenterNotesVisible = "presenterNotesVisible"

        /// Each source keeps its own address, token and chosen model; LM Studio's keys are the ones from before Kapitsa.
        static func endpoint(of provider: LLMProvider) -> String {
            provider == .lmStudio ? "endpoint" : "\(provider.rawValue)Endpoint"
        }
        static func apiKey(of provider: LLMProvider) -> String {
            provider == .lmStudio ? "apiKey" : "\(provider.rawValue)ApiKey"
        }
        static func preferredModel(of provider: LLMProvider) -> String {
            provider == .lmStudio ? "preferredModel" : "\(provider.rawValue)PreferredModel"
        }
    }

    static let defaultSpeakerTemplate = "{Modell} sagt:"
    static let defaultConversationPause = 1.2

    // MARK: Settings

    /// The settings live in the open library (`Einstellungen.plist`), not in the system preferences.
    @ObservationIgnored let settings: LibrarySettings = AppLibrary.current.settings

    /// Chats a chat's action is waiting on; they can't be asked again (see `ActionContext.checkNoRecursion`).
    @ObservationIgnored var chatsBeingAskedByActions: Set<Chat.ID> = []

    /// Set in tests; the app uses the hub's registry.
    @ObservationIgnored var actionRegistryOverride: ActionRegistry?

    /// Something other than the person just changed the open document.
    var actionFlash: ActionFlash?

    /// Decides tool calls that need the person's consent. A property so tests can answer without a dialog.
    @ObservationIgnored var toolConsent: @MainActor (ToolConsentRequest) async -> Bool = AppModel.askForToolConsent

    /// Light, dark or like the system.
    var appearance: AppAppearance {
        didSet {
            settings.set(appearance.rawValue, forKey: Keys.appearance)
            appearance.apply()
        }
    }

    /// Where the models run. Switching loads that source's address, token and chosen model.
    var provider: LLMProvider {
        didSet {
            guard provider != oldValue else { return }
            settings.set(provider.rawValue, forKey: Keys.provider)
            models = []
            explicitModelChoice = false
            endpoint = settings.string(forKey: Keys.endpoint(of: provider)) ?? provider.defaultEndpoint
            apiKey = settings.string(forKey: Keys.apiKey(of: provider)) ?? ""
            preferredModelId = settings.string(forKey: Keys.preferredModel(of: provider))
            setConnection(.connecting)
            scheduleRefresh()
        }
    }
    var endpoint: String {
        didSet {
            settings.set(endpoint, forKey: Keys.endpoint(of: provider))
            scheduleRefresh()
        }
    }
    var apiKey: String {
        didSet {
            settings.set(apiKey, forKey: Keys.apiKey(of: provider))
            scheduleRefresh()
        }
    }
    var systemPrompt: String {
        didSet { settings.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    var temperature: Double {
        didSet { settings.set(temperature, forKey: Keys.temperature) }
    }
    var useCustomTemperature: Bool {
        didSet { settings.set(useCustomTemperature, forKey: Keys.useCustomTemperature) }
    }
    var sidebarVisible: Bool {
        didSet { settings.set(sidebarVisible, forKey: Keys.sidebarVisible) }
    }

    // MARK: Narrow windows

    /// The window is too narrow for the sidebar (or the right-hand panel) beside the content: it is folded away and
    /// opens over the content instead (`RootView` sets this from the window's width). The preferences stay as they are.
    var sidebarCollapsed = false
    var panelCollapsed = false
    /// The folded sidebar (or panel) lies open over the content.
    var sidebarOverlay = false
    var panelOverlay = false

    /// The sidebar stands beside the content.
    var isSidebarDocked: Bool { sidebarVisible && !sidebarCollapsed }
    /// The sidebar is to be seen, beside the content or over it.
    var isSidebarShown: Bool { sidebarCollapsed ? sidebarOverlay : sidebarVisible }
    var isPanelDocked: Bool { outlinePanelVisible && !panelCollapsed }
    var isPanelShown: Bool { panelCollapsed ? panelOverlay : outlinePanelVisible }

    /// Closes what lies over the content.
    func closeOverlays() {
        guard sidebarOverlay || panelOverlay else { return }
        withAnimation(.smooth(duration: 0.24)) {
            sidebarOverlay = false
            panelOverlay = false
        }
    }

    /// Shows the right-hand panel because something new is in it (a bookmark); a folded panel stays closed, so it doesn't
    /// cover the text being written.
    func revealSidePanel() {
        guard !panelCollapsed, !outlinePanelVisible else { return }
        withAnimation(.smooth(duration: 0.28)) { outlinePanelVisible = true }
    }

    // MARK: PDF export settings

    var pdfPaperSize: PaperSize {
        didSet { settings.set(pdfPaperSize.rawValue, forKey: Keys.pdfPaperSize) }
    }
    /// Starts an exported answer with a line such as "Gemma sagt:".
    var pdfSpeakerLineEnabled: Bool {
        didSet { settings.set(pdfSpeakerLineEnabled, forKey: Keys.pdfSpeakerLineEnabled) }
    }
    var pdfSpeakerTemplate: String {
        didSet { settings.set(pdfSpeakerTemplate, forKey: Keys.pdfSpeakerTemplate) }
    }
    var pdfOpenAfterExport: Bool {
        didSet { settings.set(pdfOpenAfterExport, forKey: Keys.pdfOpenAfterExport) }
    }

    /// Suggest follow-up questions under each new answer.
    var suggestFollowUps: Bool {
        didSet { settings.set(suggestFollowUps, forKey: Keys.suggestFollowUps) }
    }
    @ObservationIgnored private var followUpTasks: [Chat.ID: Task<Void, Never>] = [:]

    // MARK: Web search

    /// Pages without readable text (JavaScript apps) or with bot protection are read through Jina Reader.
    var webReaderFallback: Bool {
        didSet { settings.set(webReaderFallback, forKey: Keys.webReaderFallback) }
    }
    /// Globe and W buttons in the composer of a chat that doesn't exist yet.
    private var newChatWebSearch = false
    private var newChatActionGroups: [String] = []
    private var newChatActionApproval: ChatToolApproval?
    private var newChatWikipedia = false
    /// Thinking button in the composer of a chat that doesn't exist yet; starts with the last choice.
    private var newChatThinking: Bool

    // MARK: Memory & context (see AppModel+Context.swift)

    /// Memory and context length of the chat that is being started; both start with the last choice.
    var newChatMemory: MemoryLevel {
        didSet { settings.set(newChatMemory.rawValue, forKey: Keys.memoryDefault) }
    }
    var newChatContextLength: Int {
        didSet { settings.set(newChatContextLength, forKey: Keys.contextDefault) }
    }
    /// A model that is being reloaded with another context length before a chat can go on.
    var contextReload: ContextReload?

    // MARK: Images

    /// Pictures in the composer, per chat like the drafts.
    private var draftImageLists: [UUID: [ImageAttachment]] = [:]
    /// Pictures for the composer that are still being read and scaled, per chat.
    private var draftImports: [UUID: Int] = [:]

    // MARK: Editing

    /// Question that is being edited in place; sending it branches the chat.
    private(set) var editingMessageID: ChatMessage.ID?

    // MARK: Speech (dictation and reading aloud, see AppModel+Speech.swift)

    var dictationMode: DictationMode {
        didSet { settings.set(dictationMode.rawValue, forKey: Keys.dictationMode) }
    }
    var speechEngine: SpeechEngine {
        didSet { settings.set(speechEngine.rawValue, forKey: Keys.speechEngine) }
    }
    var qwenVoice: String {
        didSet { settings.set(qwenVoice, forKey: Keys.qwenVoice) }
    }
    /// macOS speech rate 0.3…0.7 (0.5 = normal); also the tempo of Qwen playback.
    var speechRate: Double {
        didSet { settings.set(speechRate, forKey: Keys.speechRate) }
    }
    var dictationStatus: DictationStatus = .idle
    var dictationLevel: Float = 0
    /// Words the recogniser is still unsure about, shown in grey in the composer.
    var dictationPreview = ""
    var dictationError: String?
    var speakingMessageID: ChatMessage.ID?
    var speechState: SpeechReader.State = .stopped
    /// Short hint under the composer, e.g. when Qwen TTS is not reachable.
    var notice: String?
    @ObservationIgnored var dictationEngine: AnyObject?
    @ObservationIgnored let speechReader = SpeechReader()
    @ObservationIgnored var noticeTask: Task<Void, Never>?

    // MARK: Conversation mode (see AppModel+Conversation.swift)

    /// The running conversation; the window then shows only the wave.
    var conversation: ConversationSession?
    /// Seconds of silence after which a spoken turn counts as finished.
    var conversationPause: Double {
        didSet { settings.set(conversationPause, forKey: Keys.conversationPause) }
    }

    // MARK: Outline (table of contents)

    /// User preference; the panel only appears for chats that are long enough or already have an outline.
    var outlinePanelVisible: Bool {
        didSet { settings.set(outlinePanelVisible, forKey: Keys.outlinePanelVisible) }
    }
    private(set) var outlineGeneratingIDs: Set<Chat.ID> = []
    private(set) var outlineErrors: [Chat.ID: String] = [:]
    private(set) var scrollRequest: ScrollRequest?
    private(set) var highlightedTarget: OutlineTarget?
    var sidePanelTab: SidePanelTab = .contents
    /// Bookmark that was just created; the panel shows it highlighted for a moment.
    private(set) var recentBookmarkID: Bookmark.ID?
    @ObservationIgnored private var outlineTasks: [Chat.ID: Task<Void, Never>] = [:]

    // MARK: Folders & skills (see AppModel+Library.swift)

    var sidebarMode: SidebarMode = .chats
    var chatFolders: [Folder] = []
    var skills: [Skill] = []
    var skillFolders: [Folder] = []
    var selectedSkillID: Skill.ID?
    var skillSearchText = ""
    /// Skills in the composer of a chat that doesn't exist yet.
    var newChatSkillIDs: [Skill.ID] = []
    /// Folder the chat that is being started goes into ("Neuer Chat in diesem Ordner").
    var newChatFolderID: Folder.ID?
    /// Folder, chat or skill whose name is being edited in the sidebar.
    var renamingID: UUID?
    /// The skill library popover in the composer.
    var isSkillPickerShown = false
    /// Skill that was just created; its editor puts the cursor into the name.
    var newSkillID: Skill.ID?
    @ObservationIgnored let library = LibraryStore()
    @ObservationIgnored var skillSaveTask: Task<Void, Never>?

    // MARK: Personas (see AppModel+Personas.swift)

    var personas: [Persona] = []
    var selectedPersonaID: Persona.ID?
    var personaSearchText = ""
    /// Persona of the chat that is being started; it can't be changed once the chat has begun.
    var newChatPersonaID: Persona.ID?
    /// The persona list in the composer.
    var isPersonaPickerShown = false
    /// Persona that was just created; its editor puts the cursor into the name.
    var newPersonaID: Persona.ID?
    /// Files per persona that are still being read.
    var importingPersonaFiles: [Persona.ID: Int] = [:]
    @ObservationIgnored var personaSaveTasks: [Persona.ID: Task<Void, Never>] = [:]

    // MARK: Memory (see AppModel+Thalamus.swift)

    /// The memory's database of each persona.
    var thalamus: [Persona.ID: ThalamusLibrary] = [:]
    /// The consolidation that is running, and the result of the last one per persona.
    var thalamusConsolidation: ThalamusConsolidationState?
    var thalamusNotes: [Persona.ID: String] = [:]
    @ObservationIgnored var thalamusQueue: [(Persona.ID, Chat.ID)] = []
    @ObservationIgnored var thalamusWorker: Task<Void, Never>?
    @ObservationIgnored var thalamusQuietTasks: [Chat.ID: Task<Void, Never>] = [:]

    /// Where each message and the visible part of the message list sit in the window (SwiftUI global
    /// coordinates). The right-click menu (`MessageContextMenu`) uses this to find the clicked message.
    @ObservationIgnored private var messageFrames: [ChatMessage.ID: CGRect] = [:]
    @ObservationIgnored private var messageViewport: CGRect = .zero

    /// Message or chat IDs whose PDF is currently being typeset.
    var exportingIDs: Set<UUID> = []
    /// Flow charts being put into a document (see `adoptFlowchart`), by document and chart.
    var adoptingFlowcharts: Set<String> = []
    /// Flow charts that went into the document or presentation in this session, to show "übernommen".
    var adoptedFlowcharts: Set<String> = []
    var exportError: String?

    // MARK: Models

    private(set) var models: [LMModel] = []
    private(set) var connection: ConnectionState = .connecting
    private(set) var preferredModelId: String? {
        didSet { settings.set(preferredModelId, forKey: Keys.preferredModel(of: provider)) }
    }

    // MARK: Chats

    private(set) var chats: [Chat] = []
    var selectedChatID: Chat.ID?
    var searchText = ""
    private(set) var streamingMessageIDs: [Chat.ID: ChatMessage.ID] = [:]
    /// The text of the answers being written (see `LiveAnswer`); set and removed together with `streamingMessageIDs`.
    @ObservationIgnored private var liveAnswers: [ChatMessage.ID: LiveAnswer] = [:]
    private var drafts: [UUID: String] = [:]

    @ObservationIgnored private let newChatDraftKey = UUID()
    @ObservationIgnored private var explicitModelChoice = false
    @ObservationIgnored private var generationTasks: [Chat.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?
    @ObservationIgnored private let store = ChatStore()

    // MARK: Mini chat (see AppModel+MiniChat.swift)

    /// The narrow window with a chat of its own, beside the main window.
    let miniChat = MiniChat()

    // MARK: Writer Studio (see AppModel+Writer.swift)

    var documents: [WriterDocument] = []
    /// The document open in Writer Studio; while it is set, the main area shows Writer Studio instead of the chat.
    var selectedDocumentID: WriterDocument.ID?
    /// Citation Studio is shown in the main area.
    var citationStudioOpen = false
    /// A source Citation Studio should show when it opens.
    var citationStudioRequest: UUID?
    /// Stories Studio is shown in the main area.
    var storiesStudioOpen = false
    /// Writer Studio shows a white sheet instead of the dark one (the user's choice in the dark design).
    var writerLightPaper: Bool {
        didSet { settings.set(writerLightPaper, forKey: Keys.writerLightPaper) }
    }

    /// The sheet is always white in the light design; in the dark one it is the user's choice.
    func writerUsesLightPaper(_ colorScheme: ColorScheme) -> Bool {
        writerLightPaper || colorScheme == .light
    }
    /// The sheet for the open document's pages (its own format, or its head and foot lines).
    var writerPageSheet: WriterPageSheet?
    /// Page formats of the user's own, kept in the library so any document can be set in them.
    var writerPageTemplates: [WriterPageSetup] = [] {
        didSet {
            let json = (try? JSONEncoder().encode(writerPageTemplates)).flatMap { String(data: $0, encoding: .utf8) }
            settings.set(json, forKey: Keys.writerPageTemplates)
        }
    }
    @ObservationIgnored let documentStore = WriterDocumentStore()
    @ObservationIgnored var documentSaveTasks: [WriterDocument.ID: Task<Void, Never>] = [:]
    /// Set by the open editor: hands over edits it hasn't reported yet.
    @ObservationIgnored var writerFlush: (() -> Void)?
    /// The find bar of the open document or presentation (⌘F).
    @ObservationIgnored weak var documentFind: DocumentFind?
    /// The document the running dictation writes into instead of the composer.
    var dictationDocumentID: WriterDocument.ID?
    var dictationIntoDocument: Bool { dictationDocumentID != nil }
    /// Set by the open editor: receives dictated text for a document (and ignores other documents).
    @ObservationIgnored var writerDictation: ((WriterDictationEvent, WriterDocument.ID) -> Void)?
    /// The document being read aloud.
    var speakingDocumentID: WriterDocument.ID?
    /// Called once reading the document ends (finished or stopped), so the editor can remove its highlight.
    @ObservationIgnored var writerSpeechEnded: (() -> Void)?
    /// The tab of a document's side panel (contents or bookmarks); the panel itself follows `outlinePanelVisible`.
    var documentPanelTab: SidePanelTab = .contents
    /// Documents whose dynamic table of contents is being made, and why it failed.
    var documentOutlineGeneratingIDs: Set<WriterDocument.ID> = []
    var documentOutlineErrors: [WriterDocument.ID: String] = [:]
    @ObservationIgnored var documentOutlineTasks: [WriterDocument.ID: Task<Void, Never>] = [:]
    /// Writer Studio shows the open document or its content analysis (see AppModel+Analysis.swift).
    var writerTab: WriterTab = .document
    /// Content analyses, read from disk when a document's analysis is first shown.
    var documentAnalyses: [WriterDocument.ID: ContentAnalysis] = [:]
    /// Analyses being made: the part the model is working on and the parts still to come.
    var analysisProgress: [WriterDocument.ID: ContentAnalysisProgress] = [:]
    var analysisErrors: [WriterDocument.ID: [ContentAnalysisModule: String]] = [:]
    @ObservationIgnored var analysisTasks: [WriterDocument.ID: Task<Void, Never>] = [:]
    @ObservationIgnored var loadedAnalysisIDs: Set<WriterDocument.ID> = []
    @ObservationIgnored let analysisStore = ContentAnalysisStore()
    /// Pictures made with Draw Things, one after the other in the background.
    @ObservationIgnored let imageGeneration = ImageGenerationCenter(settings: AppLibrary.current.settings)
    /// Citation Studio: sources and quotes of the library (read when first needed).
    @ObservationIgnored let citations = CitationLibrary(store: .library())
    /// Stories Studio: the novel worlds of the library (read when first needed).
    @ObservationIgnored let stories = StoryLibrary(store: .library())
    /// The instruction being written in Writer Studio's assistant bar.
    var writerInstruction = ""
    /// The assistant bar has the keyboard focus (⌘D then dictates into it).
    var isWriterInstructionFocused = false
    /// The running dictation writes into the assistant bar.
    var dictationIntoInstruction = false
    /// Answers of the Writer Studio assistant are read aloud as soon as they are complete.
    var writerReadsAnswers: Bool {
        didSet { settings.set(writerReadsAnswers, forKey: Keys.writerReadsAnswers) }
    }

    // MARK: Presenter Studio (see AppModel+Presenter.swift)

    /// The slide open in the editor of the open presentation.
    var selectedSlideID: PresentationSlide.ID?
    /// The free picture selected on the open slide (moved with the mouse, deleted with ⌫).
    var selectedSlideImageID: SlideImage.ID?
    /// The text field of the open slide whose text is in the editor; nil: the slide's own text.
    var editingSlideFieldID: SlideImage.ID?
    /// The slide's own text area shows its frame, to be moved and resized.
    var editingSlideTextArea = false
    /// The small versions of the applications in the right-hand panel.
    let power = PowerAccess()
    /// A slide that was just deleted and can still be brought back.
    var deletedSlide: DeletedSlide?
    @ObservationIgnored var deletedSlideTask: Task<Void, Never>?
    /// Slides whose speaker notes the model is writing, and why it failed.
    var notesWriting: Set<PresentationSlide.ID> = []
    var notesErrors: [PresentationSlide.ID: String] = [:]
    @ObservationIgnored var notesTask: Task<Void, Never>?
    /// The speaker notes show below the slide.
    var presenterNotesVisible: Bool {
        didSet { settings.set(presenterNotesVisible, forKey: Keys.presenterNotesVisible) }
    }
    /// Plays the open presentation (tab "Abspielen" and full screen).
    @ObservationIgnored let presentationPlayer = PresentationPlayer()
    /// The model making a whole presentation from the assistant bar (see AppModel+PresenterGeneration.swift).
    var deckGeneration: DeckGeneration?
    /// For slides made from a document: the passage each was made from, which the speaker card draws on.
    @ObservationIgnored var deckSources: [UUID: String] = [:]
    /// The sheet that makes a presentation from a document (see `DeckFromDocumentSheet`).
    var deckSourceRequest: DeckSourceRequest?
    @ObservationIgnored var deckGenerationTask: Task<Void, Never>?
    /// The model writing out a handout made from a presentation (see AppModel+PresenterExport.swift).
    var handoutGeneration: HandoutGeneration?
    @ObservationIgnored var handoutTask: Task<Void, Never>?

    init() {
        let defaults = settings
        // Before there was a choice the app was always dark.
        let appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .dark
        self.appearance = appearance
        appearance.apply()
        let provider = defaults.string(forKey: Keys.provider).flatMap(LLMProvider.init(rawValue:)) ?? .lmStudio
        self.provider = provider
        endpoint = defaults.string(forKey: Keys.endpoint(of: provider)) ?? provider.defaultEndpoint
        apiKey = defaults.string(forKey: Keys.apiKey(of: provider)) ?? ""
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""
        temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.7
        useCustomTemperature = defaults.bool(forKey: Keys.useCustomTemperature)
        sidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? true
        pdfPaperSize = defaults.string(forKey: Keys.pdfPaperSize).flatMap(PaperSize.init(rawValue:)) ?? .a4
        pdfSpeakerLineEnabled = defaults.bool(forKey: Keys.pdfSpeakerLineEnabled)
        pdfSpeakerTemplate = defaults.string(forKey: Keys.pdfSpeakerTemplate) ?? Self.defaultSpeakerTemplate
        pdfOpenAfterExport = defaults.object(forKey: Keys.pdfOpenAfterExport) as? Bool ?? true
        outlinePanelVisible = defaults.object(forKey: Keys.outlinePanelVisible) as? Bool ?? true
        suggestFollowUps = defaults.object(forKey: Keys.suggestFollowUps) as? Bool ?? true
        dictationMode = defaults.string(forKey: Keys.dictationMode).flatMap(DictationMode.init(rawValue:)) ?? .accurate
        speechEngine = defaults.string(forKey: Keys.speechEngine).flatMap(SpeechEngine.init(rawValue:)) ?? .qwenSmall
        qwenVoice = defaults.string(forKey: Keys.qwenVoice) ?? "serena"
        speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? 0.5
        conversationPause = defaults.object(forKey: Keys.conversationPause) as? Double ?? Self.defaultConversationPause
        webReaderFallback = defaults.object(forKey: Keys.webReaderFallback) as? Bool ?? true
        preferredModelId = defaults.string(forKey: Keys.preferredModel(of: provider))
        newChatThinking = defaults.bool(forKey: Keys.thinkingDefault)
        newChatMemory = defaults.string(forKey: Keys.memoryDefault).map(MemoryLevel.init(stored:)) ?? .off
        newChatContextLength = (defaults.object(forKey: Keys.contextDefault) as? Int).flatMap { ContextChoice.lengths.contains($0) ? $0 : nil }
            ?? ContextChoice.defaultLength
        writerLightPaper = defaults.bool(forKey: Keys.writerLightPaper)
        writerPageTemplates = defaults.string(forKey: Keys.writerPageTemplates)
            .flatMap { try? JSONDecoder().decode([WriterPageSetup].self, from: Data($0.utf8)) } ?? []
        writerReadsAnswers = defaults.bool(forKey: Keys.writerReadsAnswers)
        presenterNotesVisible = defaults.object(forKey: Keys.presenterNotesVisible) as? Bool ?? true
        chats = store.loadAll()
        documents = documentStore.loadAll()
        chatFolders = library.loadChatFolders()
        let skillLibrary = library.loadSkills()
        skills = skillLibrary.skills
        skillFolders = skillLibrary.folders
        personas = PersonaStore.loadAll()
        for persona in personas {
            thalamus[persona.id] = PersonaStore.loadThalamus(of: persona.id)
        }
        saveSkillsOnQuit()
        // Impressions of chats that went quiet while the app was closed; the model server needs a moment first.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.catchUpThalamus()
        }
        startPolling()
        setUpSpeechReader()
        removeUnusedAttachments()
    }

    // MARK: Closing

    /// Before another library opens: writes what is still waiting to be saved and stops everything that runs
    /// (answers, outlines, memory work, voice, polling), so nothing of this library goes on in the next one.
    func close() async {
        if conversation != nil { endConversation() }
        if isDictating { await stopDictation() }
        stopReadingDocument()
        speechReader.stop()
        imageGeneration.cancelAll()
        citations.saveAll()
        stories.saveAll()
        writerFlush?()
        if skillSaveTask != nil { saveSkillLibrary() }
        savePendingPersonas()
        savePendingDocuments()
        pollTask?.cancel()
        refreshDebounce?.cancel()
        noticeTask?.cancel()
        let running = Array(generationTasks.values) + Array(outlineTasks.values) + Array(followUpTasks.values)
            + Array(documentOutlineTasks.values) + Array(analysisTasks.values) + Array(thalamusQuietTasks.values)
            + [thalamusWorker].compactMap { $0 }
        running.forEach { $0.cancel() }
        // Cancelled work ends quickly (an answer is saved as far as it got); it gets a few seconds at most.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in running { await task.value } }
            group.addTask { try? await Task.sleep(for: .seconds(4)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Derived state

    var client: LLMClient? { try? LLMClient(provider: provider, endpoint: endpoint, apiKey: apiKey) }
    var hostDescription: String { client?.hostDescription ?? endpoint }

    var chatModels: [LMModel] { models.filter(\.isChatCapable) }
    var loadedModels: [LMModel] { chatModels.filter(\.isLoaded) }
    var availableModels: [LMModel] { chatModels.filter { !$0.isLoaded } }

    var selectedChat: Chat? {
        guard let selectedChatID else { return nil }
        return chats.first { $0.id == selectedChatID }
    }
    /// Writer Studio uses the model chosen last, not the one of the chat that was open before.
    var currentModelId: String? {
        selectedDocumentID != nil ? preferredModelId : selectedChat.flatMap(modelId(for:)) ?? preferredModelId
    }

    /// The model that answers in a chat: its own, as long as the current source offers it. A chat begun with the other
    /// source, or with a model that is gone, goes on with the chosen one (Kapitsa serves only the model it runs).
    func modelId(for chat: Chat) -> String? {
        guard let id = chat.modelId else { return preferredModelId }
        if models.isEmpty || chatModels.contains(where: { $0.id == id }) { return id }
        return preferredModelId ?? id
    }
    var currentModel: LMModel? {
        guard let currentModelId else { return nil }
        return models.first { $0.id == currentModelId }
    }

    var draft: String {
        get { drafts[selectedChatID ?? newChatDraftKey] ?? "" }
        set {
            drafts[selectedChatID ?? newChatDraftKey] = newValue
            // Writing on frees the model: a consolidation that is running gives way and follows later.
            if !newValue.isEmpty { cancelThalamusConsolidation() }
        }
    }

    /// Whether the user has started a message in this chat's composer.
    func hasDraft(in chatID: Chat.ID) -> Bool {
        !(drafts[chatID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var draftImages: [ImageAttachment] {
        get { draftImageLists[selectedChatID ?? newChatDraftKey] ?? [] }
        set { draftImageLists[selectedChatID ?? newChatDraftKey] = newValue }
    }
    var importingDraftImages: Int { draftImports[selectedChatID ?? newChatDraftKey] ?? 0 }

    var isGenerating: Bool { selectedChatID.map(isGenerating) ?? false }
    func isGenerating(_ chatID: Chat.ID) -> Bool { streamingMessageIDs[chatID] != nil }
    func liveAnswer(_ messageID: ChatMessage.ID) -> LiveAnswer? { liveAnswers[messageID] }

    /// Whether the web search is switched on for the selected chat (or the new one being written).
    var isWebSearchOn: Bool {
        selectedChat.map { $0.webSearch == true } ?? newChatWebSearch
    }

    var isWikipediaOn: Bool {
        selectedChat.map { $0.wikipediaSearch == true } ?? newChatWikipedia
    }

    var isThinkingOn: Bool {
        selectedChat.map { $0.thinking == true } ?? newChatThinking
    }

    /// Web and Wikipedia search need a model that can call tools.
    var canUseLookupTools: Bool { currentModel?.acceptsTools ?? false }

    func toggleWebSearch() {
        guard selectedIndex != nil else { return newChatWebSearch.toggle() }
        toggleChatFlag(\.webSearch)
    }

    // The composer's menu of tool groups: for the selected chat, or the next one.

    var activeActionGroups: [String] { selectedChat.map { $0.actionGroups ?? [] } ?? newChatActionGroups }
    var activeActionApproval: ChatToolApproval { selectedChat.map { $0.actionApproval ?? .ask } ?? newChatActionApproval ?? .ask }

    func toggleActionGroup(_ group: String) {
        var groups = activeActionGroups
        if let position = groups.firstIndex(of: group) { groups.remove(at: position) } else { groups.append(group) }
        guard let id = selectedChatID else { return newChatActionGroups = groups }
        updateChat(id) { $0.actionGroups = groups.isEmpty ? nil : groups }
    }

    func setActionApproval(_ approval: ChatToolApproval) {
        guard let id = selectedChatID else { return newChatActionApproval = approval == .ask ? nil : approval }
        updateChat(id) { $0.actionApproval = approval == .ask ? nil : approval }
    }

    /// Changes a chat's settings and saves it.
    func updateChat(_ id: Chat.ID, _ change: (inout Chat) -> Void) {
        guard let index = index(of: id) else { return }
        change(&chats[index])
        store.save(chats[index])
    }

    func toggleWikipedia() {
        guard selectedIndex != nil else { return newChatWikipedia.toggle() }
        toggleChatFlag(\.wikipediaSearch)
    }

    /// The thinking switch new chats start with: the last choice, in the main window or the mini chat.
    var thinkingDefault: Bool {
        get { settings.bool(forKey: Keys.thinkingDefault) }
        set { settings.set(newValue, forKey: Keys.thinkingDefault) }
    }

    /// Switches thinking for this chat; new chats start with the last choice.
    func toggleThinking() {
        settings.set(!isThinkingOn, forKey: Keys.thinkingDefault)
        guard selectedIndex != nil else { return newChatThinking.toggle() }
        toggleChatFlag(\.thinking)
    }

    private func toggleChatFlag(_ flag: WritableKeyPath<Chat, Bool?>) {
        guard let index = selectedIndex else { return }
        chats[index][keyPath: flag] = chats[index][keyPath: flag] == true ? nil : true
        store.save(chats[index])
    }

    /// Lookup tools the user switched on for a chat.
    func lookupSources(of chat: Chat) -> WebTools.Sources {
        var sources: WebTools.Sources = []
        if chat.webSearch == true { sources.insert(.web) }
        if chat.wikipediaSearch == true { sources.insert(.wikipedia) }
        return sources
    }

    var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !draftImages.isEmpty) && importingDraftImages == 0 && currentModelId != nil && !isGenerating
    }

    var chatSearchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    func chatMatchesSearch(_ chat: Chat) -> Bool {
        let query = chatSearchQuery
        return query.isEmpty || chat.title.localizedStandardContains(query)
            || chat.messages.contains { $0.content.localizedStandardContains(query) }
    }

    /// Chats and documents of the sidebar matching the search, newest first.
    var sidebarEntries: [SidebarEntry] {
        let entries = chats.filter(chatMatchesSearch).map(SidebarEntry.chat)
            + documents.filter { $0.matches(chatSearchQuery) }.map(SidebarEntry.document)
        return entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Chats and documents outside any folder, grouped by date.
    var chatGroups: [ChatGroup] {
        let folderIDs = Set(chatFolders.map(\.id))
        let filtered = sidebarEntries.filter { !($0.folderID.map(folderIDs.contains) ?? false) }

        let calendar = Calendar.current
        let now = Date()
        var buckets: [(title: String, entries: [SidebarEntry])] = [
            ("Heute", []), ("Gestern", []), ("Letzte 7 Tage", []), ("Letzte 30 Tage", []), ("Älter", []),
        ]
        for entry in filtered {
            let date = entry.updatedAt
            let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
            let bucket: Int
            if calendar.isDateInToday(date) { bucket = 0 }
            else if calendar.isDateInYesterday(date) { bucket = 1 }
            else if days < 7 { bucket = 2 }
            else if days < 30 { bucket = 3 }
            else { bucket = 4 }
            buckets[bucket].entries.append(entry)
        }
        return buckets.filter { !$0.entries.isEmpty }.map { ChatGroup(id: $0.title, entries: $0.entries) }
    }

    // MARK: Model server

    func refreshModels() async {
        guard let client else {
            setConnection(.failed("Ungültiger Endpoint: \(endpoint)"))
            return
        }
        do {
            let list = try await client.fetchModels()
            // The source was switched while the list was on its way.
            guard client.provider == provider else { return }
            if list != models { models = list }
            setConnection(.connected)
            ensureModelSelection()
        } catch {
            guard client.provider == provider else { return }
            if !models.isEmpty { models = [] }
            setConnection(.failed(error.localizedDescription))
        }
    }

    func selectModel(_ id: String) {
        explicitModelChoice = true
        preferredModelId = id
        if selectedDocumentID == nil, let index = selectedIndex {
            chats[index].modelId = id
            store.save(chats[index])
        }
    }

    private func setConnection(_ state: ConnectionState) {
        if connection != state { connection = state }
    }

    /// Falls back to a loaded model unless the user deliberately picked one that LM Studio loads on demand.
    /// Kapitsa lists only the model it runs, so the choice follows it.
    private func ensureModelSelection() {
        let preferred = preferredModelId.flatMap { id in chatModels.first { $0.id == id } }
        if let preferred, preferred.isLoaded || explicitModelChoice { return }
        if let firstLoaded = loadedModels.first { preferredModelId = firstLoaded.id }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshModels()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.setConnection(.connecting)
            await self?.refreshModels()
        }
    }

    // MARK: Chat management

    func toggleSidebar() {
        withAnimation(.smooth(duration: 0.28)) {
            if sidebarCollapsed {
                sidebarOverlay.toggle()
                if sidebarOverlay { panelOverlay = false }
            } else {
                sidebarVisible.toggle()
            }
        }
    }

    func newChat() {
        let previous = selectedChatID
        selectedChatID = nil
        editingMessageID = nil
        newChatWebSearch = false
        newChatWikipedia = false
        newChatActionGroups = []
        newChatActionApproval = nil
        newChatThinking = settings.bool(forKey: Keys.thinkingDefault)
        newChatSkillIDs = []
        newChatPersonaID = nil
        newChatFolderID = nil
        closeDocument()
        showChats()
        if let previous { consolidateThalamus(previous) }
    }

    func selectChat(_ id: Chat.ID) {
        let previous = selectedChatID
        closeDocument()
        showChats()
        selectedChatID = id
        editingMessageID = nil
        if isPanelShown { refreshOutlineIfNeeded(id) }
        // Leaving a chat catches up on a memory that gave way to typing.
        // Leaving a chat makes it quiet: its impressions are consolidated.
        if let previous, previous != id { consolidateThalamus(previous) }
    }

    func renameChat(_ id: Chat.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: id) else { return }
        chats[index].title = trimmed
        chats[index].hasCustomTitle = true
        store.save(chats[index])
    }

    /// Hands the title back to the outline, which names the chat after its content.
    func useAutomaticTitle(_ id: Chat.ID) {
        guard let index = index(of: id) else { return }
        chats[index].hasCustomTitle = false
        if let title = chats[index].outline?.title {
            chats[index].title = title
        } else {
            refreshOutline(id)
        }
        store.save(chats[index])
    }

    func deleteChat(_ id: Chat.ID) {
        generationTasks[id]?.cancel()
        thalamusQuietTasks[id]?.cancel()
        thalamusQuietTasks[id] = nil
        outlineTasks[id]?.cancel()
        chats.removeAll { $0.id == id }
        drafts[id] = nil
        draftImageLists[id] = nil
        store.delete(id)
        if selectedChatID == id { selectedChatID = nil }
        if miniChat.chatID == id { miniChat.chatID = nil }
        removeUnusedAttachments()
    }

    // MARK: Generation

    func send() {
        // Sending while dictating: wait for the last words first, then send everything.
        if isDictating {
            Task {
                await stopDictation()
                send()
            }
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftImages
        guard !text.isEmpty || !images.isEmpty, importingDraftImages == 0, currentModelId != nil, !isGenerating else { return }
        draft = ""
        draftImages = []
        send(text: text, images: images)
    }

    /// Sends a suggested follow-up question as the next message.
    func sendFollowUp(_ question: String) {
        guard selectedChatID != nil, !isGenerating else { return }
        send(text: question)
    }

    /// Sends a message in the selected chat, or starts a new chat with it. `spoken` marks a turn of conversation mode.
    @discardableResult
    func send(text: String, images: [ImageAttachment] = [], spoken: Bool = false) -> Chat.ID? {
        guard let modelId = currentModelId else { return nil }

        let chatID: Chat.ID
        if let selectedIndex {
            chatID = chats[selectedIndex].id
        } else {
            var chat = Chat(title: Self.title(for: text), modelId: modelId)
            chat.hasCustomTitle = false
            if newChatWebSearch { chat.webSearch = true }
            if newChatWikipedia { chat.wikipediaSearch = true }
            if !newChatActionGroups.isEmpty { chat.actionGroups = newChatActionGroups }
            chat.actionApproval = newChatActionApproval
            newChatActionGroups = []
            newChatActionApproval = nil
            if newChatThinking { chat.thinking = true }
            if let personaID = newChatPersonaID, persona(personaID) != nil {
                chat.personaID = personaID
            } else if !newChatSkillIDs.isEmpty {
                chat.skillIDs = newChatSkillIDs
            }
            if let folderID = newChatFolderID, chatFolders.contains(where: { $0.id == folderID }) { chat.folderID = folderID }
            // The memory belongs to a persona; chats without one have none.
            if chat.personaID != nil { chat.memory = newChatMemory }
            // With Kapitsa the chat runs in the context Kapitsa was started with; back in LM Studio it takes the loaded one.
            chat.contextLength = provider.loadsModels ? newChatContextLength : nil
            newChatWebSearch = false
            newChatWikipedia = false
            newChatSkillIDs = []
            newChatPersonaID = nil
            newChatFolderID = nil
            chats.insert(chat, at: 0)
            selectedChatID = chat.id
            chatID = chat.id
        }

        guard index(of: chatID) != nil else { return nil }
        ask(text, images: images, in: chatID, model: modelId, spoken: spoken)
        return chatID
    }

    /// Adds the question to a chat (the main window's or the mini chat's) and lets the model answer it.
    func ask(_ text: String, images: [ImageAttachment], in chatID: Chat.ID, model modelId: String, spoken: Bool = false) {
        guard let index = index(of: chatID) else { return }
        // The chat model has priority; outline and suggestions are rebuilt once the answer is complete.
        outlineTasks[chatID]?.cancel()
        followUpTasks[chatID]?.cancel()
        chats[index].messages.append(ChatMessage(role: .user, content: text, images: images.isEmpty ? nil : images))
        chats[index].modelId = modelId
        chats[index].updatedAt = Date()
        chats.sort { $0.updatedAt > $1.updatedAt }
        if let index = self.index(of: chatID) { store.save(chats[index]) }

        generate(in: chatID, spoken: spoken)
    }

    /// Puts a chat that was started outside the main window (in the mini chat) at the top of the list.
    func insert(_ chat: Chat) {
        chats.insert(chat, at: 0)
    }

    /// A chat an action made: it is saved right away and not opened, so an agent doesn't take the screen.
    func addChatFromAction(_ chat: Chat) {
        guard index(of: chat.id) == nil else { return }
        chats.insert(chat, at: 0)
        store.save(chat)
    }

    func stop() {
        guard let selectedChatID else { return }
        stopGeneration(in: selectedChatID)
    }

    func stopGeneration(in chatID: Chat.ID) {
        generationTasks[chatID]?.cancel()
    }

    func regenerate() {
        guard let id = selectedChatID else { return }
        regenerate(id)
    }

    func regenerate(_ id: Chat.ID) {
        guard !isGenerating(id), let index = index(of: id) else { return }
        if chats[index].messages.last?.role == .assistant {
            let removed = chats[index].messages.removeLast()
            chats[index].bookmarks?.removeAll { $0.target.messageID == removed.id }
        }
        guard chats[index].messages.last?.role == .user else { return }
        if chats[index].modelId == nil { chats[index].modelId = preferredModelId }
        outlineTasks[id]?.cancel()
        generate(in: id)
    }

    private func generate(in chatID: Chat.ID, spoken: Bool = false) {
        guard let client, let index = index(of: chatID),
              let modelId = self.modelId(for: chats[index]) else { return }

        let model = models.first { $0.id == modelId }
        // A chat with a chosen context length needs the model loaded with exactly that length. Kapitsa keeps the
        // context it was started with; there the choice only sets the budget.
        let wantedContext = chats[index].contextLength
        // Plain OpenAI-compatible servers (no state reported) can't be reloaded.
        let canReload = client.provider.loadsModels && (model.map { $0.state != nil } ?? true)
        let reloadContext = wantedContext.flatMap { canReload && $0 != model?.loadedContextLength ? $0 : nil }
        let canCallTools = model?.acceptsTools == true
        let sources: WebTools.Sources = canCallTools ? lookupSources(of: chats[index]) : []
        // A persona with files may look into them whenever it needs to.
        let fileTools = canCallTools ? persona(of: chats[index]).flatMap(PersonaFileTools.init(persona:)) : nil
        // A turn that an action started runs without action tools (see `startTurn` in ChatActions).
        let actionTools = canCallTools && !chatsBeingAskedByActions.contains(chatID)
            ? actionRegistry.flatMap { ChatActionTools(registry: $0, chat: chats[index]) } : nil
        if actionTools != nil { prepareActionRun(for: chats[index]) }
        let offeredTools = WebTools.definitions(for: sources) + (fileTools?.definitions ?? []) + (actionTools?.definitions ?? [])
        let tools = offeredTools.isEmpty ? nil : offeredTools
        let maxRounds = actionTools == nil ? WebTools.maxRounds : ChatActionTools.maxRounds
        let maxCalls = actionTools == nil ? WebTools.maxCallsPerRound : ChatActionTools.maxCallsPerRound
        // The strong memory sorts the question first; the moments it recalls join the system prompt.
        let thalamusJob = thalamusJob(for: chats[index], model: modelId)
        var payload: [ChatPayloadMessage] = []
        var system = systemPrompt(for: chats[index])
        for hint in [sources.isEmpty ? nil : WebTools.systemHint(for: sources), fileTools?.systemHint, actionTools?.systemHint].compactMap({ $0 }) {
            system = system.isEmpty ? hint : system + "\n\n" + hint
        }
        // The answer will be read aloud: short, spoken sentences without Markdown.
        if spoken {
            system = system.isEmpty ? ConversationSession.systemHint : system + "\n\n" + ConversationSession.systemHint
        }
        // Kapitsa switches thinking per request. In LM Studio, Gemma 4 thinks only with its token at the very start of
        // the system prompt; Qwen 3.5 always thinks there.
        let thinking = chats[index].thinking == true
        if thinking, !client.provider.switchesThinking, (model ?? LMModel(id: modelId)).thinksOnThinkToken {
            system = "<|think|>" + system
        }
        if !system.isEmpty { payload.append(ChatPayloadMessage(role: "system", content: system)) }
        for message in chats[index].messages where message.error == nil && message.hasContent {
            var entry = ChatPayloadMessage(role: message.role.rawValue, content: WebTools.historyContent(of: message))
            if message.role == .user, let images = message.images {
                entry.images = images.compactMap(AttachmentStore.dataURL)
            }
            payload.append(entry)
        }

        // Search results must leave room for the chat and the answer (roughly 3–4 characters per token).
        let contextTokens = contextLength(of: chats[index])
        let resultLimit = min(12_000, max(3_000, contextTokens / 2))
        var resultBudget = max(6_000, contextTokens * 4 / 3)

        let assistant = ChatMessage(role: .assistant, content: "", model: modelId)
        let messageID = assistant.id
        chats[index].messages.append(assistant)
        if actionTools != nil { actionRegistry?.runState(id: chatID.uuidString, channel: .chat).currentTurn = messageID }
        let live = LiveAnswer()
        liveAnswers[messageID] = live
        streamingMessageIDs[chatID] = messageID

        let temperature = useCustomTemperature ? temperature : nil
        let readerFallback = webReaderFallback

        generationTasks[chatID] = Task { [weak self] in
            var conversation = payload
            let started = Date()
            var firstToken: Date?
            // Text of finished rounds; a round ends when the model calls tools.
            var earlierContent = ""
            var earlierReasoning = ""
            // The round that is streaming right now.
            var raw = ""
            var reasoningField = ""
            var roundStart: Date?
            var roundFirstContent: Date?
            var roundEvents = 0
            var roundCompletion: Int?
            var promptTokens: Int?
            var completionTokens = 0
            var timedTokens = 0
            var streamingSeconds = 0.0
            var reasoningSeconds = 0.0
            var lastFlush = Date.distantPast
            var failure: String?

            // Shows the accumulated stream in the answer; called at most ~20×/s to keep the UI smooth.
            @MainActor func flush() {
                let parts = ThinkingSplitter.split(raw)
                if roundFirstContent == nil, !parts.content.isEmpty { roundFirstContent = Date() }
                let content = Self.joined(earlierContent, parts.content)
                let reasoning = Self.joined(earlierReasoning, reasoningField + parts.reasoning)
                live.content = content
                live.reasoning = reasoning
                if spoken {
                    self?.conversation?.answerChanged(messageID, content: content, isThinking: content.isEmpty && !reasoning.isEmpty)
                }
            }

            /// Books the round's text and timing and starts a fresh one. Returns the round's answer text.
            @MainActor func closeRound() -> String {
                flush()
                let end = Date()
                let parts = ThinkingSplitter.split(raw)
                let tokens = roundCompletion ?? roundEvents
                completionTokens += tokens
                if let roundStart {
                    if firstToken == nil { firstToken = roundStart }
                    streamingSeconds += end.timeIntervalSince(roundStart)
                    timedTokens += tokens
                    if !(reasoningField + parts.reasoning).isEmpty {
                        reasoningSeconds += (roundFirstContent ?? end).timeIntervalSince(roundStart)
                    }
                }
                earlierContent = Self.joined(earlierContent, parts.content)
                earlierReasoning = Self.joined(earlierReasoning, reasoningField + parts.reasoning)
                let (content, reasoning) = (earlierContent, earlierReasoning)
                self?.updateMessage(chatID, messageID) { message in
                    message.content = content
                    message.reasoning = reasoning.isEmpty ? nil : reasoning
                }
                raw = ""
                reasoningField = ""
                roundStart = nil
                roundFirstContent = nil
                roundEvents = 0
                roundCompletion = nil
                return parts.content
            }

            do {
                if let reloadContext {
                    try await self?.loadModel(modelId, contextLength: reloadContext)
                }
                if let thalamusJob, let recall = await self?.runThalamus(thalamusJob, answerID: messageID) {
                    conversation = Self.adding(recall, toSystemOf: conversation)
                }
                try Task.checkCancellation()
                for round in 0... {
                    // The last round goes without tools, so the model answers with what it found so far.
                    let offered = round < maxRounds ? tools : nil
                    let stream = client.streamChat(
                        model: modelId, messages: conversation, temperature: temperature, tools: offered, thinking: thinking
                    )
                    var calls: [ToolCall] = []

                    for try await event in stream {
                        let now = Date()
                        switch event {
                        case .content(let text):
                            if roundStart == nil { roundStart = now }
                            raw += text
                            roundEvents += 1
                        case .reasoning(let text):
                            if roundStart == nil { roundStart = now }
                            reasoningField += text
                            roundEvents += 1
                        case .usage(let prompt, let completion):
                            promptTokens = prompt
                            roundCompletion = completion
                        case .model(let answering):
                            self?.updateMessage(chatID, messageID) { $0.model = answering }
                        case .toolCalls(let requested):
                            calls = requested
                        }
                        if now.timeIntervalSince(lastFlush) >= 0.05 {
                            lastFlush = now
                            flush()
                        }
                    }

                    let roundText = closeRound()
                    guard offered != nil, !calls.isEmpty else { break }

                    // Every call needs an answer, otherwise the chat template rejects the conversation.
                    conversation.append(ChatPayloadMessage(role: "assistant", content: roundText, toolCalls: calls))
                    for (position, call) in calls.enumerated() {
                        try Task.checkCancellation()
                        let output: String
                        if position >= maxCalls {
                            output = WebTools.skippedOutput
                        } else if resultBudget < 800 {
                            output = WebTools.budgetExhaustedOutput
                        } else {
                            output = await self?.runTool(
                                call, chatID: chatID, messageID: messageID, sources: sources, fileTools: fileTools, actionTools: actionTools,
                                offered: offeredTools, limit: min(resultLimit, resultBudget), readerFallback: readerFallback
                            ) ?? ""
                            resultBudget -= output.count
                        }
                        conversation.append(ChatPayloadMessage(role: "tool", content: output, toolCallID: call.id))
                    }
                    try Task.checkCancellation()
                }
            } catch {
                _ = closeRound()
                if !Task.isCancelled && !(error is CancellationError) {
                    failure = error.localizedDescription
                }
            }

            let cancelled = Task.isCancelled
            self?.updateMessage(chatID, messageID) { message in
                if let firstToken {
                    var stats = GenerationStats()
                    stats.promptTokens = promptTokens
                    stats.completionTokens = completionTokens
                    stats.timeToFirstToken = firstToken.timeIntervalSince(started)
                    if streamingSeconds > 0.05 { stats.tokensPerSecond = Double(timedTokens) / streamingSeconds }
                    if message.reasoning != nil { stats.reasoningSeconds = reasoningSeconds }
                    message.stats = stats
                }
                message.error = failure
                if cancelled { message.stopped = true }
                if message.thalamus?.status == .running {
                    message.thalamus?.status = .failed
                    message.thalamus?.error = "Abgebrochen"
                }
                // A step still running was interrupted by the stop button.
                if let steps = message.toolSteps, steps.contains(where: { $0.status == .running }) {
                    message.toolSteps = steps.map { step in
                        guard step.status == .running else { return step }
                        var interrupted = step
                        interrupted.status = .failed
                        interrupted.error = "Abgebrochen"
                        return interrupted
                    }
                }
            }
            self?.finishGeneration(chatID, answerID: messageID, completed: !cancelled && failure == nil)
        }
    }

    /// Shows a tool call as a step of the answer, runs it and returns the text for the model.
    private func runTool(
        _ call: ToolCall, chatID: Chat.ID, messageID: ChatMessage.ID, sources: WebTools.Sources, fileTools: PersonaFileTools?,
        actionTools: ChatActionTools?, offered: [ToolDefinition], limit: Int, readerFallback: Bool
    ) async -> String {
        if let actionTools, let action = actionTools.action(forTool: call.function.name) {
            let running = ToolStep(kind: .action, argument: action.id)
            updateMessage(chatID, messageID) { $0.toolSteps = ($0.toolSteps ?? []) + [running] }
            var (finished, output) = await actionTools.execute(call, action: action, app: self, limit: limit)
            finished.id = running.id
            updateMessage(chatID, messageID) { message in
                if let position = message.toolSteps?.firstIndex(where: { $0.id == running.id }) { message.toolSteps?[position] = finished }
            }
            return output
        }
        let fileStep = fileTools?.step(for: call)
        guard let step = fileStep ?? WebTools.step(for: call, allowed: sources) else {
            return WebTools.unknownToolOutput(call, available: offered)
        }
        let run = actionTools == nil ? nil : actionRegistry?.runState(id: chatID.uuidString, channel: .chat)
        if let refusal = await webToolRefusal(for: step, messages: index(of: chatID).map { chats[$0].messages } ?? [], runHasSensitive: run?.hasReadSensitive == true) {
            var refused = step
            refused.status = .failed
            refused.error = "Nicht erlaubt"
            updateMessage(chatID, messageID) { $0.toolSteps = ($0.toolSteps ?? []) + [refused] }
            return refusal
        }
        updateMessage(chatID, messageID) { $0.toolSteps = ($0.toolSteps ?? []) + [step] }
        let (finished, output) = if let fileTools, fileStep != nil {
            await fileTools.execute(step, limit: limit)
        } else {
            await WebTools.execute(step, limit: limit, readerFallback: readerFallback)
        }
        updateMessage(chatID, messageID) { message in
            if let position = message.toolSteps?.firstIndex(where: { $0.id == step.id }) {
                message.toolSteps?[position] = finished
            }
        }
        // In a chat with action tools, what the lookups bring counts for the safety rule, and a foreign text is framed.
        guard let run else { return output }
        if finished.status == .done {
            if finished.kind.isFile { run.markSensitive() } else { run.markUntrusted() }
        }
        return finished.kind.isFile ? output : ForeignFrame.wrap(output)
    }

    /// Applies `WebToolGuard` to a step in a chat with these messages. Returns the text for the model when the step may not run.
    func webToolRefusal(for step: ToolStep, messages: [ChatMessage], runHasSensitive: Bool = false) async -> String? {
        var evidence = WebToolGuard.ChatEvidence(messages: messages)
        if runHasSensitive { evidence.hasReadPersonaFiles = true }
        switch WebToolGuard.verdict(for: step, evidence: evidence) {
        case .allowed:
            return nil
        case .denied(let text):
            return text
        case .needsConsent(let request):
            if await toolConsent(request) { return nil }
            return "Nicht ausgeführt: Die Person hat „\(request.action)“ nicht erlaubt. Antworte mit dem, was du hast."
        }
    }

    /// Asks the person whether a tool call may reach the outside. They see the unabridged address or search terms.
    static func askForToolConsent(_ request: ToolConsentRequest) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(request.action) erlauben?"
        alert.informativeText = "\(request.detail)\n\n\(request.reason)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Nicht erlauben")
        alert.addButton(withTitle: "Erlauben")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The messages with `text` added to the end of the system prompt (or as one, if there is none).
    private nonisolated static func adding(_ text: String, toSystemOf messages: [ChatPayloadMessage]) -> [ChatPayloadMessage] {
        var messages = messages
        if let first = messages.first, first.role == "system" {
            messages[0] = ChatPayloadMessage(role: "system", content: first.content + "\n\n" + text)
        } else {
            messages.insert(ChatPayloadMessage(role: "system", content: text), at: 0)
        }
        return messages
    }

    private nonisolated static func joined(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + "\n\n" + second
    }

    // MARK: Branches & editing

    /// Copies the chat up to and including this message into a new chat and opens it. The original stays as it is.
    /// A branch of the mini chat opens in the mini chat.
    func branchChat(at messageID: ChatMessage.ID, inMiniChat: Bool = false) {
        guard let source = inMiniChat ? currentMiniChat : selectedChat, streamingMessageIDs[source.id] != messageID,
              let position = source.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let branch = makeBranch(of: source, keeping: position + 1, from: messageID, editedQuestion: false)
        guard inMiniChat else { return open(branch) }
        chats.insert(branch, at: 0)
        store.save(branch)
        miniChat.chatID = branch.id
    }

    func startEditing(_ messageID: ChatMessage.ID) {
        guard message(messageID)?.role == .user else { return }
        editingMessageID = messageID
    }

    func cancelEditing() {
        editingMessageID = nil
    }

    /// Asks the edited question in a new branch: the messages before it are copied, the original chat stays as it is.
    func submitEdit(of messageID: ChatMessage.ID, text: String, images: [ImageAttachment]) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty, let source = selectedChat,
              let position = source.messages.firstIndex(where: { $0.id == messageID }) else { return }
        var chat = makeBranch(of: source, keeping: position, from: messageID, editedQuestion: true)
        // The first question names the chat, unless the user chose the title.
        if position == 0 && !source.isTitleCustom { chat.title = Self.title(for: text) }
        chat.messages.append(ChatMessage(role: .user, content: text, images: images.isEmpty ? nil : images))
        open(chat)
        generate(in: chat.id)
    }

    /// Opens the chat a branch was made from, at the message it branched off.
    func openBranchSource(_ branch: ChatBranch) {
        guard index(of: branch.sourceChatID) != nil else { return }
        selectChat(branch.sourceChatID)
        Task {
            // The other chat's message list has to be on screen before it can scroll.
            try? await Task.sleep(for: .milliseconds(250))
            guard selectedChatID == branch.sourceChatID else { return }
            jump(to: OutlineTarget(messageID: branch.sourceMessageID, block: nil))
        }
    }

    func chatTitle(_ id: Chat.ID) -> String? {
        chat(id)?.title
    }

    /// A new chat with the first `count` messages of `source`. Messages get new IDs, so bookmarks are carried over
    /// with them; the table of contents is rebuilt for the branch.
    private func makeBranch(of source: Chat, keeping count: Int, from messageID: ChatMessage.ID, editedQuestion: Bool) -> Chat {
        var newIDs: [ChatMessage.ID: ChatMessage.ID] = [:]
        let messages = source.messages.prefix(count).map { message in
            var copy = message
            copy.id = UUID()
            newIDs[message.id] = copy.id
            return copy
        }
        var chat = Chat(title: source.title, modelId: source.modelId ?? preferredModelId, messages: messages)
        chat.hasCustomTitle = source.isTitleCustom
        chat.webSearch = source.webSearch
        chat.wikipediaSearch = source.wikipediaSearch
        chat.actionGroups = source.actionGroups
        chat.actionApproval = source.actionApproval
        chat.thinking = source.thinking
        chat.folderID = source.folderID
        chat.skillIDs = source.skillIDs
        chat.personaID = source.personaID
        chat.memory = source.memory
        chat.contextLength = source.contextLength
        let bookmarks = (source.bookmarks ?? []).compactMap { bookmark -> Bookmark? in
            guard let newID = newIDs[bookmark.target.messageID] else { return nil }
            var copy = bookmark
            copy.id = UUID()
            copy.target.messageID = newID
            return copy
        }
        chat.bookmarks = bookmarks.isEmpty ? nil : bookmarks
        chat.branch = ChatBranch(
            sourceChatID: source.id,
            sourceTitle: source.title,
            sourceMessageID: messageID,
            lastCopiedMessageID: messages.last?.id,
            editedQuestion: editedQuestion ? true : nil
        )
        return chat
    }

    private func open(_ chat: Chat) {
        chats.insert(chat, at: 0)
        store.save(chat)
        selectChat(chat.id)
    }

    static func title(for text: String) -> String {
        text.isEmpty ? "Bild" : Chat.makeTitle(from: text)
    }

    // MARK: Images

    /// Reads and scales pictures for a message. Files that are not pictures end up as a notice under the composer.
    func importImages(_ sources: [AttachmentStore.Source]) async -> [ImageAttachment] {
        var imported: [ImageAttachment] = []
        for source in sources {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AttachmentStore.importImage(source) }
            }.value
            switch result {
            case .success(let attachment): imported.append(attachment)
            case .failure(let error): showNotice(error.localizedDescription)
            }
        }
        return imported
    }

    /// Adds pictures to the composer of the chat that is open now.
    func attachImages(_ sources: [AttachmentStore.Source]) {
        let key = selectedChatID ?? newChatDraftKey
        draftImports[key, default: 0] += sources.count
        Task {
            let images = await importImages(sources)
            draftImports[key, default: 0] -= sources.count
            draftImageLists[key, default: []] += images
        }
    }

    func removeDraftImage(_ id: ImageAttachment.ID) {
        draftImages.removeAll { $0.id == id }
    }

    /// Pictures for the main window's composer, or for the mini chat's.
    func chooseImages(forMiniChat: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Anhängen"
        panel.message = "Bilder für die nächste Nachricht auswählen"
        Task {
            let chosen: Bool
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                chosen = await panel.beginSheetModal(for: window) == .OK
            } else {
                chosen = panel.runModal() == .OK
            }
            guard chosen else { return }
            let sources: [AttachmentStore.Source] = panel.urls.map { .file($0) }
            if forMiniChat { attachMiniChatImages(sources) } else { attachImages(sources) }
        }
    }

    /// Deletes picture files that no chat and no draft refers to any more.
    private func removeUnusedAttachments() {
        var used = Set(chats.flatMap { $0.messages.flatMap { ($0.images ?? []).map(\.fileName) } })
        used.formUnion(draftImageLists.values.flatMap { $0.map(\.fileName) })
        used.formUnion(miniChat.images.map(\.fileName))
        Task.detached(priority: .utility) { AttachmentStore.removeUnused(keeping: used) }
    }

    // MARK: Copy & export

    func setMessageFrame(_ frame: CGRect, for messageID: ChatMessage.ID) {
        messageFrames[messageID] = frame
    }

    func setMessageViewport(_ frame: CGRect) {
        messageViewport = frame
    }

    /// The message of the selected chat at `point`, if the point lies in the visible part of the message list.
    func messageID(at point: CGPoint) -> ChatMessage.ID? {
        // The skill library and the studios replace the message list; its last frames are stale then, and a
        // right-click into a document must open the document's menu, not the chat's.
        guard sidebarMode == .chats, activeApplication == nil, conversation == nil,
              messageViewport.contains(point), let chat = selectedChat else { return nil }
        return chat.messages.first { message in
            message.hasContent && messageFrames[message.id]?.contains(point) == true
        }?.id
    }

    func message(_ messageID: ChatMessage.ID) -> ChatMessage? {
        chat(holding: messageID)?.messages.first { $0.id == messageID }
    }

    /// The chat a message on screen belongs to: the main window's, or the mini chat's.
    func chat(holding messageID: ChatMessage.ID) -> Chat? {
        [selectedChat, miniChat.chatID.flatMap { chat($0) }].compactMap { $0 }.first { $0.messages.contains { $0.id == messageID } }
    }

    func copyAnswer(_ messageID: ChatMessage.ID) {
        guard let message = selectedChat?.messages.first(where: { $0.id == messageID }) else { return }
        copyToPasteboard(message.content)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The whole chat as Markdown, with a speaker label before every message.
    func transcript(of chat: Chat) -> String {
        let personaName = persona(of: chat)?.displayName
        return chat.messages
            .filter { $0.hasContent && $0.role != .system }
            .map { message in
                let speaker = message.role == .user ? "Du" : (personaName ?? LaTeXWriter.speakerName(forModel: message.model))
                let images = message.images?.count ?? 0
                let note = images == 0 ? nil : (images == 1 ? "[Bild]" : "[\(images) Bilder]")
                let text = [note, message.content.isEmpty ? nil : message.content].compactMap { $0 }.joined(separator: "\n\n")
                return "**\(speaker):**\n\n\(text)"
            }
            .joined(separator: "\n\n---\n\n")
    }

    func exportAnswer(_ messageID: ChatMessage.ID) {
        guard let chat = chat(holding: messageID), let message = chat.messages.first(where: { $0.id == messageID }),
              !message.content.isEmpty else { return }
        let label = pdfSpeakerLineEnabled
            ? LaTeXWriter.speakerLine(template: pdfSpeakerTemplate, model: message.model, name: persona(of: chat)?.displayName)
            : nil
        runExport(
            id: messageID,
            parts: [LaTeXWriter.Part(label: label, text: message.content)],
            fileName: "\(chat.title) – Antwort"
        )
    }

    func exportChat(withOutline: Bool) {
        guard let chat = selectedChat, !exportingIDs.contains(chat.id) else { return }
        guard withOutline else {
            runExport(id: chat.id, parts: exportParts(of: chat, outline: nil).parts, fileName: chat.title)
            return
        }

        // An outdated outline is rebuilt first, so the table of contents covers the whole chat.
        exportingIDs.insert(chat.id)
        Task {
            if OutlineBuilder.isOutdated(chat) {
                await refreshOutline(chat.id)?.value
            }
            exportingIDs.remove(chat.id)
            guard let current = self.chat(chat.id), let outline = current.outline else {
                exportError = outlineErrors[chat.id] ?? "Das Inhaltsverzeichnis konnte nicht erstellt werden."
                return
            }
            let export = exportParts(of: current, outline: outline)
            runExport(id: chat.id, parts: export.parts, outline: export.outline, fileName: "\(current.title) – mit Inhaltsverzeichnis")
        }
    }

    /// Message parts for the PDF; with an outline, every jump target gets a LaTeX label for the table of contents.
    private func exportParts(of chat: Chat, outline: ChatOutline?) -> (parts: [LaTeXWriter.Part], outline: LaTeXWriter.Outline?) {
        var labels: [OutlineTarget: String] = [:]
        func label(for target: OutlineTarget) -> String {
            if let existing = labels[target] { return existing }
            let new = "llmd:\(labels.count + 1)"
            labels[target] = new
            return new
        }

        var latexOutline: LaTeXWriter.Outline?
        if let outline {
            var entries: [LaTeXWriter.OutlineEntry] = []
            for section in outline.sections {
                entries.append(.init(title: section.title, level: 0, label: label(for: section.target)))
                for item in section.items {
                    entries.append(.init(title: item.title, level: 1, label: label(for: item.target)))
                }
            }
            latexOutline = LaTeXWriter.Outline(summary: outline.summary, entries: entries)
        }

        let personaName = persona(of: chat)?.displayName
        let parts = chat.messages
            .filter { $0.hasContent && $0.role != .system }
            .map { message in
                var part = message.role == .user
                    ? LaTeXWriter.Part(label: "Du:", text: message.content, isPlainText: true)
                    : LaTeXWriter.Part(
                        label: LaTeXWriter.speakerLine(template: pdfSpeakerTemplate, model: message.model, name: personaName),
                        text: message.content
                    )
                part.images = (message.images ?? []).map(AttachmentStore.url(for:))
                part.anchor = labels[OutlineTarget(messageID: message.id, block: nil)]
                for (target, name) in labels where target.messageID == message.id {
                    if let block = target.block { part.blockAnchors[block] = name }
                }
                return part
            }
        return (parts, latexOutline)
    }

    private func runExport(id: UUID, parts: [LaTeXWriter.Part], outline: LaTeXWriter.Outline? = nil, fileName: String) {
        guard !exportingIDs.contains(id) else { return }
        guard let engine = LaTeXEngine.locate() else {
            exportError = PDFExportError.noEngine.localizedDescription
            return
        }
        exportingIDs.insert(id)
        let paper = pdfPaperSize
        Task {
            do {
                let pdf = try await engine.makePDF(parts: parts, outline: outline, paper: paper)
                exportingIDs.remove(id)
                guard let url = await askForDestination(fileName: fileName, type: .pdf) else { return }
                try pdf.write(to: url, options: .atomic)
                if pdfOpenAfterExport { NSWorkspace.shared.open(url) }
            } catch {
                exportingIDs.remove(id)
                exportError = error.localizedDescription
            }
        }
    }

    /// Asks where to save an export; the name is cleaned of characters a file name can't have.
    func askForDestination(fileName: String, type: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let cleaned = fileName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = String((cleaned.isEmpty ? "Export" : cleaned).prefix(80)) + "." + (type.preferredFilenameExtension ?? "pdf")

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Outline

    /// The side panel is offered once there is something to show: an outline (or a chat long enough for one) or bookmarks.
    func showsSidePanel(for chat: Chat) -> Bool {
        chat.outline != nil || OutlineBuilder.isLongEnough(chat) || !(chat.bookmarks ?? []).isEmpty
    }

    var isOutlinePanelShown: Bool {
        isPanelShown && selectedChat.map(showsSidePanel) == true
    }

    func toggleOutlinePanel() {
        withAnimation(.smooth(duration: 0.28)) {
            if panelCollapsed {
                panelOverlay.toggle()
                if panelOverlay { sidebarOverlay = false }
            } else {
                outlinePanelVisible.toggle()
            }
        }
        // In Writer Studio the panel makes its own table of contents when it needs one.
        if isPanelShown, selectedDocumentID == nil, let id = selectedChatID { refreshOutlineIfNeeded(id) }
    }

    @discardableResult
    func refreshOutlineIfNeeded(_ chatID: Chat.ID) -> Task<Void, Never>? {
        guard let chat = chat(chatID), OutlineBuilder.isLongEnough(chat), OutlineBuilder.isOutdated(chat),
              outlineErrors[chatID] == nil else { return nil }
        return refreshOutline(chatID)
    }

    /// Asks the chat's model for a fresh outline. Returns the running task, e.g. to await it before an export.
    @discardableResult
    func refreshOutline(_ chatID: Chat.ID) -> Task<Void, Never>? {
        if let running = outlineTasks[chatID] { return running }
        guard !isGenerating(chatID), let client, let snapshot = chat(chatID),
              let model = modelId(for: snapshot) else { return nil }

        outlineGeneratingIDs.insert(chatID)
        outlineErrors[chatID] = nil
        let request = OutlineBuilder.requestMessages(for: snapshot)
        let task = Task { [weak self] in
            do {
                let answer = try await client.complete(
                    model: model, messages: request, temperature: 0.1, maxTokens: 1_500,
                    jsonSchema: (OutlineBuilder.schemaName, OutlineBuilder.schema)
                )
                let outline = try OutlineBuilder.parse(answer, chat: snapshot, model: model)
                self?.storeOutline(outline, in: chatID)
            } catch {
                if !Task.isCancelled { self?.outlineErrors[chatID] = error.localizedDescription }
            }
            self?.outlineGeneratingIDs.remove(chatID)
            self?.outlineTasks[chatID] = nil
        }
        outlineTasks[chatID] = task
        return task
    }

    private func storeOutline(_ outline: ChatOutline, in chatID: Chat.ID) {
        guard let index = index(of: chatID) else { return }
        chats[index].outline = outline
        if !chats[index].isTitleCustom, let title = outline.title {
            chats[index].title = title
        }
        store.save(chats[index])
    }

    // MARK: Bookmarks

    /// The marked text if it belongs to this message; a selection left over in another message doesn't count.
    func selection(_ text: String?, in messageID: ChatMessage.ID) -> String? {
        guard let text, let message = message(messageID),
              BookmarkLocator.target(for: text, in: message) != nil else { return nil }
        return text
    }

    /// Bookmarks the marked passage of a message, or the whole message when nothing in it is marked.
    func addBookmark(selectedText: String?, near messageID: ChatMessage.ID) {
        guard let index = selectedIndex,
              let message = chats[index].messages.first(where: { $0.id == messageID }) else { return }
        let selection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let excerpt = selection.isEmpty ? message.content : selection
        let target = BookmarkLocator.target(for: selection, in: message) ?? OutlineTarget(messageID: messageID, block: nil)

        let bookmark = Bookmark(title: BookmarkLocator.title(from: excerpt), excerpt: String(excerpt.prefix(500)), target: target)
        chats[index].bookmarks = (chats[index].bookmarks ?? []) + [bookmark]
        store.save(chats[index])

        sidePanelTab = .bookmarks
        revealSidePanel()
        recentBookmarkID = bookmark.id
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if recentBookmarkID == bookmark.id { recentBookmarkID = nil }
        }
    }

    func renameBookmark(_ id: Bookmark.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = selectedIndex,
              let position = chats[index].bookmarks?.firstIndex(where: { $0.id == id }) else { return }
        chats[index].bookmarks?[position].title = trimmed
        store.save(chats[index])
    }

    func deleteBookmark(_ id: Bookmark.ID) {
        guard let index = selectedIndex else { return }
        chats[index].bookmarks?.removeAll { $0.id == id }
        store.save(chats[index])
    }

    /// Scrolls the message list to `target` and highlights it briefly.
    func jump(to target: OutlineTarget) {
        scrollRequest = ScrollRequest(target: target)
        highlightedTarget = target
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if highlightedTarget == target { highlightedTarget = nil }
        }
    }

    func chat(_ id: Chat.ID) -> Chat? {
        index(of: id).map { chats[$0] }
    }

    /// Changes a chat and saves it.
    func modifyChat(_ id: Chat.ID, _ change: (inout Chat) -> Void) {
        guard let index = index(of: id) else { return }
        change(&chats[index])
        store.save(chats[index])
    }

    private func message(_ messageID: ChatMessage.ID, in chatID: Chat.ID) -> ChatMessage? {
        chat(chatID)?.messages.last { $0.id == messageID }
    }

    func updateMessage(_ chatID: Chat.ID, _ messageID: ChatMessage.ID, _ change: (inout ChatMessage) -> Void) {
        guard let chatIndex = index(of: chatID),
              let messageIndex = chats[chatIndex].messages.lastIndex(where: { $0.id == messageID }) else { return }
        change(&chats[chatIndex].messages[messageIndex])
    }

    private func finishGeneration(_ chatID: Chat.ID, answerID: ChatMessage.ID, completed: Bool) {
        chatsBeingAskedByActions.remove(chatID)
        actionRegistry?.runState(id: chatID.uuidString, channel: .chat).currentTurn = nil
        streamingMessageIDs[chatID] = nil
        liveAnswers[answerID] = nil
        generationTasks[chatID] = nil
        if let index = index(of: chatID) { store.save(chats[index]) }
        outlineErrors[chatID] = nil
        if let answer = message(answerID, in: chatID) { conversation?.answerFinished(answer) }
        scheduleThalamusQuiet(chatID)
        // In a conversation the model's time goes to the next answer; the outline follows when it ends.
        guard conversation?.chatID != chatID else { return }
        Task {
            // Suggestions first: they appear right under the answer the user is reading.
            if completed && suggestFollowUps { await generateFollowUps(chatID, answerID: answerID) }
            guard isPanelShown, !isGenerating(chatID) else { return }
            try? await Task.sleep(for: .milliseconds(500))
            refreshOutlineIfNeeded(chatID)
        }
    }

    private func generateFollowUps(_ chatID: Chat.ID, answerID: ChatMessage.ID) async {
        guard let client, let snapshot = chat(chatID),
              let answer = snapshot.messages.first(where: { $0.id == answerID }), !answer.content.isEmpty,
              let model = answer.model ?? modelId(for: snapshot) else { return }
        let request = FollowUpBuilder.requestMessages(for: snapshot, answer: answer)
        let task = Task { [weak self] in
            guard let reply = try? await client.complete(
                model: model, messages: request, temperature: 0.5, maxTokens: 400,
                jsonSchema: (FollowUpBuilder.schemaName, FollowUpBuilder.schema)
            ), !Task.isCancelled else { return }
            let questions = FollowUpBuilder.parse(reply)
            guard !questions.isEmpty, let self else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.updateMessage(chatID, answerID) { $0.followUps = questions }
            }
            if let index = self.index(of: chatID) { self.store.save(self.chats[index]) }
        }
        followUpTasks[chatID] = task
        await task.value
        if followUpTasks[chatID] == task { followUpTasks[chatID] = nil }
    }

    private var selectedIndex: Int? { selectedChatID.flatMap(index(of:)) }

    private func index(of id: Chat.ID) -> Int? {
        chats.firstIndex { $0.id == id }
    }
}
