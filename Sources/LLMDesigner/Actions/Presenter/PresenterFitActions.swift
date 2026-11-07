import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerPresenterFitActions() {
        register(PresenterSlidesCheckFitAction.self)
        register(PresenterSlideSplitAction.self)
    }
}

// MARK: - Light or dark backgrounds

extension SlideDesign {
    /// How the background looks: a design with light text has a dark background.
    var backgroundBrightness: String { tone(for: .content) == .light ? "dunkel" : "hell" }
}

/// The wish for a background as agents give it: a design by name, or just "hell" or "dunkel".
enum PresenterBackgroundWish {
    static let brightnessProperty: JSONSchema = .choice(["hell", "dunkel"], "Heller oder dunkler Hintergrund; ohne design wählt die App ein passendes Design")
    static let designProperty: JSONSchema = .string("Design, z. B. papier oder aurora; presenter.designs.list zeigt alle mit Helligkeit")

    /// The design to use, or nil when neither is given. A design wins over the brightness; with only a brightness
    /// the default design is kept if it fits, else the first of the app's designs that does.
    @MainActor
    static func design(named name: String?, brightness: String?) throws -> String? {
        let library = SlideDesignLibrary.shared
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let design = library.design(name) ?? library.design(name.lowercased()) ?? library.all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return design.id
            }
            throw RPCError.notFound("Design „\(name)“ gibt es nicht. Vorhanden: \(library.all.map(\.id).joined(separator: ", ")).")
        }
        guard let brightness = brightness?.lowercased(), !brightness.isEmpty else { return nil }
        let wanted = ["hell", "light", "weiß", "weiss"].contains(brightness) ? "hell" : "dunkel"
        if let preferred = library.design(SlideDesign.defaultID), preferred.backgroundBrightness == wanted { return preferred.id }
        let fitting = library.all.filter { $0.backgroundBrightness == wanted }
        // Calm designs first: a moving background distracts from text the agent wrote.
        return (fitting.first { $0.isBuiltIn && !$0.isAnimated } ?? fitting.first)?.id
    }
}

// MARK: - Fit

struct PresenterSlidesCheckFitAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
    }
    struct Item: Encodable, Sendable {
        var id: String
        var index: Int
        var title: String
        var fit: SlideFitReport
    }
    struct Output: Encodable, Sendable {
        var allFit: Bool
        var overflowing: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slides.checkFit", summary: "Prüft, auf welchen Folien der Text über den Rand läuft", kind: .read, security: .plainRead,
        input: .object(["deck": presenterDeckProperty], required: ["deck"]), output: .freeObject(),
        example: "llmd presenter slides check-fit Vortrag --json", groups: ["presenter.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: try context.app.actionDocument(args.deck, presentation: true).isForeign)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        guard let deck = document.deck else { throw RPCError.invalidTarget("Das ist keine Präsentation.") }
        let items = deck.slides.enumerated().compactMap { index, slide -> Item? in
            let fit = SlideFit.report(slide, in: deck, family: document.font)
            guard !fit.fits else { return nil }
            let title = slide.markdown.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
            return Item(id: slide.id.uuidString, index: index + 1, title: title, fit: fit)
        }
        return Output(allFit: items.isEmpty, overflowing: items)
    }
}

struct PresenterSlideSplitAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var deck: String
        var slide: String?
        var slideIndex: Int?
    }
    struct Output: Encodable, Sendable {
        var slides: [String]
        var fit: SlideFitReport?
    }
    static let descriptor = ActionDescriptor(
        id: "presenter.slide.split", summary: "Verteilt die Punkte einer zu vollen Folie auf Folgefolien „(Forts.)“", kind: .write, security: .localWrite,
        input: .object(presenterSlideProperties, required: ["deck"]), output: .freeObject(),
        example: "llmd presenter slide split Vortrag --slide-index 3"
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let document = try context.app.actionDocument(args.deck, presentation: true)
        guard let slide = try document.deck?.actionSlide(id: args.slide, index: args.slideIndex) else { throw RPCError.invalidTarget("Diese Präsentation hat keine Folien.") }
        let (fit, continuations) = try fitOrSplit(slide.id, deck: args.deck, split: true, context: context)
        if fit?.fits == false, continuations == nil {
            throw RPCError.invalidTarget("Die Folie lässt sich nicht teilen: Sie hat keine Stichpunkte oder schon der erste ist zu lang. Bitte den Text kürzen.")
        }
        return Output(slides: [slide.id.uuidString] + (continuations ?? []), fit: fit)
    }
}
