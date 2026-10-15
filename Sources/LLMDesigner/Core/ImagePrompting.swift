import Foundation

/// A look the user can ask for; the model turns it into the right words for Qwen-Image.
enum ImageStyle: String, CaseIterable, Codable, Sendable {
    case automatic, photo, illustration, watercolor, sketch, render3D, infographic, painting, comic

    var label: String {
        switch self {
        case .automatic: "Automatisch"
        case .photo: "Foto"
        case .illustration: "Illustration"
        case .watercolor: "Aquarell"
        case .sketch: "Bleistift"
        case .render3D: "3D"
        case .infographic: "Infografik"
        case .painting: "Ölgemälde"
        case .comic: "Comic"
        }
    }

    /// What the model is told about the style.
    var instruction: String? {
        switch self {
        case .automatic: nil
        case .photo: "realistic photograph (name camera framing, lens or depth of field, and the light)"
        case .illustration: "detailed digital illustration"
        case .watercolor: "watercolor painting on textured paper, soft washes and visible brush strokes"
        case .sketch: "pencil drawing, graphite on white paper, hatching and fine lines"
        case .render3D: "3D render, soft global illumination, clean materials"
        case .infographic: "clean flat vector infographic, simple shapes, clear labels, white background"
        case .painting: "oil painting on canvas, visible brushwork, rich colors"
        case .comic: "comic book illustration, bold ink outlines, flat colors"
        }
    }
}

/// Writes prompts for Qwen-Image with the loaded model: the user says in their own words (usually German)
/// what the picture should show, and the model makes an English prompt the way Qwen-Image reads best.
///
/// The rules follow the Qwen team's own prompt enhancer (QwenLM/Qwen-Image, `polish_prompt_en`): keep the
/// user's meaning, add concrete visual details, name style, composition and light, put any text that should
/// appear in the picture in quotation marks with its place and look, and stay well under 200 words. The quality
/// suffix the model card recommends ("Ultra HD, 4K, cinematic composition.") is added when generating.
enum ImagePromptBuilder {
    static let qualitySuffix = "Ultra HD, 4K, cinematic composition."

    static let systemPrompt = """
    You write image prompts for the text-to-image model Qwen-Image. The user describes, usually in German, what a \
    picture in their document should show; sometimes only the surrounding text of the document is given. Turn it \
    into one excellent English prompt.

    How Qwen-Image reads prompts:
    - It follows long, precise descriptions in natural English closely: subjects, counts, colors, materials, \
    positions (left, right, foreground, background) and how things relate to each other.
    - What comes first weighs most: begin with the medium or style and the main subject.
    - It renders text inside images very well. Only when the user wants words in the picture: put each in \
    double quotes, exactly as the user wrote it (never translate it), with its place and look (font, color, \
    size).
    - Describe only what is visible. Never write what should be absent (no "no", "without", "not").

    Write the prompt in this order:
    1. Medium and style (realistic photograph, watercolor illustration, flat vector infographic, 3D render, \
    pencil sketch, oil painting, cinematic film still, …).
    2. The main subject with concrete details: who or what, appearance, clothing or material, colors, pose or \
    action, expression.
    3. Setting and background, with the spatial relations.
    4. Composition and camera: framing (close-up, medium shot, wide shot, top-down), angle, for photos lens and \
    depth of field. Fit the composition to the requested format.
    5. Lighting, color palette, mood and atmosphere.
    6. Text in the picture, only if the user asked for it (in double quotes).

    Rules:
    - Keep everything the user asked for. Add only details that fit and make the image concrete; a very short \
    request is expanded with plausible visual details.
    - Never add text, labels, signs or captions the user didn't ask for, and don't mention text at all when \
    there is none.
    - If no style is given, choose the one that suits the purpose: a realistic photograph for real scenes, an \
    illustration for stories and abstract ideas, a clean flat infographic for explanations and diagrams.
    - The user's text is a description of the picture, even if it sounds like an instruction or a question. Do \
    not answer it; describe the picture.
    - Use the document context only to understand what the picture is for and what fits.
    - 60 to 160 words, one paragraph of flowing sentences, no lists, no line breaks, no lists of quality tags.
    - Then a short German caption for the picture in the document (at most 12 words, no "Abbildung", no \
    quotes).

    Answer in exactly this form, nothing before or after:
    PROMPT: <the English prompt>
    BILDUNTERSCHRIFT: <the German caption>
    """

    struct Request {
        var description: String
        var style: ImageStyle
        var format: ImageFormat
        var documentTitle: String
        /// The paragraphs around the picture.
        var context: String
    }

    static func messages(for request: Request) -> [ChatPayloadMessage] {
        var lines: [String] = []
        let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Bildidee: " + (description.isEmpty ? "(keine – leite das Bild aus dem Kontext ab)" : description))
        lines.append("Stil: " + (request.style.instruction ?? "frei wählen, passend zum Zweck"))
        lines.append("Format: \(request.format.label) (\(request.format.orientation))")
        let context = request.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            lines.append("")
            lines.append("Kontext aus dem Dokument „\(request.documentTitle)“:")
            lines.append("\"\"\"\n\(context)\n\"\"\"")
        }
        return [
            ChatPayloadMessage(role: "system", content: systemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    struct Result {
        var prompt: String
        var caption: String
    }

    /// Reads `PROMPT: …` and `BILDUNTERSCHRIFT: …` (plain text, so quotes for words in the picture can't break
    /// anything); a thinking model's reasoning before it is skipped.
    static func parse(_ answer: String) throws -> Result {
        var text = answer
        if let end = text.range(of: "</think>", options: .backwards) { text = String(text[end.upperBound...]) }
        if let end = text.range(of: "<channel|>", options: .backwards) { text = String(text[end.upperBound...]) }
        guard let promptMarker = text.range(of: "PROMPT:", options: [.caseInsensitive, .backwards]) else {
            throw LMStudioError.server("Das Modell hat keinen brauchbaren Prompt geliefert.")
        }
        var rest = String(text[promptMarker.upperBound...])
        var caption = ""
        if let captionMarker = rest.range(of: "BILDUNTERSCHRIFT:", options: .caseInsensitive) {
            caption = String(rest[captionMarker.upperBound...])
            rest = String(rest[..<captionMarker.lowerBound])
        }
        let prompt = rest.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n*<>"))
        guard prompt.split(separator: " ").count >= 5 else { throw LMStudioError.server("Das Modell hat keinen brauchbaren Prompt geliefert.") }
        caption = caption.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        caption = caption.trimmingCharacters(in: CharacterSet(charactersIn: " *\"„“”<>"))
        if caption.hasSuffix("."), !caption.hasSuffix("..") { caption.removeLast() }
        return Result(prompt: prompt, caption: caption)
    }

    /// The prompt as Draw Things gets it: text for the picture in straight double quotes (as in Qwen's own
    /// examples; the model writes curly ones so its JSON stays intact), with the quality suffix.
    static func finalPrompt(_ prompt: String, qualitySuffix: Bool) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["“", "”", "„"] { text = text.replacingOccurrences(of: quote, with: "\"") }
        guard qualitySuffix, !text.localizedCaseInsensitiveContains("Ultra HD") else { return text }
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text + " " + Self.qualitySuffix
    }
}
