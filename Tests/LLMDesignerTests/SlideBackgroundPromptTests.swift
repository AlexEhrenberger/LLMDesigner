import Testing
@testable import LLMDesigner

@Suite("Folienhintergrund ohne Schrift")
struct SlideBackgroundPromptTests {
    private func mentionsWriting(_ prompt: String) -> Bool {
        let body = prompt.replacingOccurrences(of: PresenterPrompts.backgroundClosing, with: "")
        return body.range(of: #"\b(text|title|heading|words|letters|slide|presentation|typography)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test func purposeClauseGoes() {
        let prompt = PresenterPrompts.textFreeBackgroundPrompt(
            "Cinematic digital painting of a misty pine forest at dawn, soft teal and gold light. A wide empty band of smooth fog across the middle, perfect for a centered title. Tall pine silhouettes frame the left and right edges, fading into deep shadow along the lower third."
        )
        #expect(!mentionsWriting(prompt))
        #expect(prompt.contains("A wide empty band of smooth fog across the middle."))
        #expect(prompt.contains("Tall pine silhouettes"))
        #expect(prompt.hasSuffix(PresenterPrompts.backgroundClosing))
    }

    @Test func quotesAndSlideWordsGo() {
        let prompt = PresenterPrompts.textFreeBackgroundPrompt(
            "A presentation slide background with the words \u{201C}Predictive Coding\u{201D} glowing in neon. Deep blue gradient with soft bokeh lights drifting along the bottom edge, calm and atmospheric, with deep shadows and a gentle glow around the outer frame of the picture."
        )
        #expect(!prompt.contains("Predictive"))
        #expect(!mentionsWriting(prompt))
        #expect(prompt.hasPrefix("Deep blue gradient"))
    }

    @Test func leavingRoomForText() {
        let prompt = PresenterPrompts.textFreeBackgroundPrompt(
            "Soft watercolor wash in pale peach and lavender spreading across textured paper, leaving room for the slide text on the left side. Delicate petals drift in from the right edge, painted with loose, translucent strokes and gentle light."
        )
        #expect(!mentionsWriting(prompt))
        #expect(prompt.contains("textured paper."))
        #expect(prompt.contains("Delicate petals"))
    }

    @Test func shortPromptKeepsItsSentences() {
        // Dropping the sentence would leave almost nothing, so only the words go.
        let prompt = PresenterPrompts.textFreeBackgroundPrompt(
            "Minimal dark gradient from navy to black with a faint glow, calm area for text."
        )
        #expect(!mentionsWriting(prompt))
        #expect(prompt.contains("navy to black"))
    }

    @Test func ordinaryWordsStay() {
        let source = "Oil painting of rolling hills under a vast evening sky, rich texture in the brushwork, mist sliding down the valley toward a quiet river. The sky stays an empty, smooth gradient of rose and violet across the middle, while the hills and a few trees sit in the lower third."
        let prompt = PresenterPrompts.textFreeBackgroundPrompt(source)
        #expect(prompt == source + " " + PresenterPrompts.backgroundClosing)
    }

    @Test func infographicStyleHasNoLabels() {
        let messages = PresenterPrompts.backgroundMessages(description: "Wasser", presentationTitle: "Klima", role: .content, tone: .dark, style: .infographic)
        #expect(!(messages.last?.content.contains("labels") ?? true))
    }
}
