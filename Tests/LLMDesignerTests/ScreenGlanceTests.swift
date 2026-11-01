import Testing
import Foundation
@testable import LLMDesigner

@Suite("Bildschirm betrachten")
struct ScreenGlanceTests {
    @Test func retinaScreenShrinksToTheAttachmentSize() {
        // MacBook Pro 14": 1512 × 982 points at 2× → 3024 × 1964 pixels.
        let size = ScreenGlance.pictureSize(points: CGSize(width: 1512, height: 982), scale: 2)
        #expect(size.width == AttachmentStore.maxPixelSize)
        #expect(size.height == 1039)
    }

    @Test func smallScreenKeepsItsPixels() {
        let size = ScreenGlance.pictureSize(points: CGSize(width: 1280, height: 800), scale: 1)
        #expect(size.width == 1280)
        #expect(size.height == 800)
    }

    @Test func portraitScreenLimitsTheHeight() {
        let size = ScreenGlance.pictureSize(points: CGSize(width: 1080, height: 1920), scale: 1)
        #expect(size.height == AttachmentStore.maxPixelSize)
        #expect(size.width == 900)
    }
}
