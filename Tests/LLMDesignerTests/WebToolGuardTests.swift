import Testing
import Foundation
@testable import LLMDesigner

extension ActionSuites {
@Suite("Sicherheit: Regeln für open_page und web_search")
struct WebToolGuardTests {
    private func searchMessage(_ urls: String...) -> ChatMessage {
        var message = ChatMessage(role: .assistant, content: "")
        var step = ToolStep(kind: .search, argument: "wetter")
        step.status = .done
        step.sources = urls.map { WebSource(title: "Treffer", url: $0) }
        message.toolSteps = [step]
        return message
    }

    private func fileReadMessage() -> ChatMessage {
        var message = ChatMessage(role: .assistant, content: "")
        var step = ToolStep(kind: .fileRead, argument: "tagebuch.txt")
        step.status = .done
        message.toolSteps = [step]
        return message
    }

    private func verdict(open address: String, after messages: [ChatMessage]) -> WebToolGuard.Verdict {
        WebToolGuard.verdict(for: ToolStep(kind: .openPage, argument: address), evidence: .init(messages: messages))
    }

    private func isDenied(_ verdict: WebToolGuard.Verdict) -> Bool {
        if case .denied = verdict { return true }
        return false
    }

    // S.1

    @Test func inventedAddressIsRefusedWithAnExplanation() {
        let verdict = verdict(open: "https://evil.example/", after: [ChatMessage(role: .user, content: "Wie wird das Wetter?")])
        guard case .denied(let text) = verdict else { Issue.record("nicht abgelehnt"); return }
        #expect(text.contains("Suchergebnis"))
    }

    @Test func addressFromASearchResultOpens() {
        #expect(verdict(open: "https://wetter.example/berlin", after: [searchMessage("https://wetter.example/berlin")]) == .allowed)
    }

    @Test func addressFromThePersonsMessageOpens() {
        let messages = [ChatMessage(role: .user, content: "Lies bitte https://example.org/artikel?id=7, danke.")]
        #expect(verdict(open: "https://example.org/artikel?id=7", after: messages) == .allowed)
    }

    @Test func bareDomainInThePersonsMessageOpens() {
        let messages = [ChatMessage(role: .user, content: "Schau auf example.org/seite nach (oder www.tagesschau.de).")]
        #expect(verdict(open: "https://example.org/seite", after: messages) == .allowed)
        #expect(verdict(open: "https://www.tagesschau.de/", after: messages) == .allowed)
    }

    @Test func mailAddressIsNoWebAddress() {
        #expect(WebToolGuard.addresses(in: "Schreib an anna@example.org").isEmpty)
    }

    @Test func tidyingAnAddressUpIsNotPunished() {
        let messages = [searchMessage("https://www.example.org/seite/?a=1#oben")]
        #expect(verdict(open: "http://example.org/seite?a=1", after: messages) == .allowed)
        #expect(verdict(open: "example.org/seite", after: messages) == .allowed)
    }

    @Test func linkInAReadPageIsNotTrusted() {
        var message = ChatMessage(role: .assistant, content: "")
        var step = ToolStep(kind: .openPage, argument: "https://harmlos.example/")
        step.status = .done
        step.sources = [WebSource(title: "Seite", url: "https://harmlos.example/weiter")]
        message.toolSteps = [step]
        #expect(isDenied(verdict(open: "https://harmlos.example/weiter", after: [message])))
    }

    @Test func otherPathOnATrustedHostIsRefused() {
        #expect(isDenied(verdict(open: "https://wetter.example/geheim-daten", after: [searchMessage("https://wetter.example/berlin")])))
    }

    // S.2

    @Test func addedQueryIsRefused() {
        let verdict = verdict(open: "https://wetter.example/berlin?d=geheim", after: [searchMessage("https://wetter.example/berlin")])
        guard case .denied(let text) = verdict else { Issue.record("nicht abgelehnt"); return }
        #expect(text.contains("Abfrageparameter"))
    }

    @Test func changedQueryValueIsRefused() {
        #expect(isDenied(verdict(open: "https://wetter.example/s?q=geheim", after: [searchMessage("https://wetter.example/s?q=berlin")])))
    }

    @Test func droppedParameterIsFine() {
        #expect(verdict(open: "https://wetter.example/s?q=berlin", after: [searchMessage("https://wetter.example/s?q=berlin&utm=x")]) == .allowed)
    }

    // S.3

    @Test func afterReadingFilesOpeningNeedsConsent() {
        let messages = [searchMessage("https://wetter.example/berlin"), fileReadMessage()]
        guard case .needsConsent(let request) = verdict(open: "https://wetter.example/berlin", after: messages) else {
            Issue.record("keine Rückfrage"); return
        }
        #expect(request.detail == "https://wetter.example/berlin")
    }

    @Test func afterReadingFilesAnInventedAddressStaysRefused() {
        #expect(isDenied(verdict(open: "https://evil.example/", after: [fileReadMessage()])))
    }

    @Test func afterReadingFilesSearchingNeedsConsent() {
        let step = ToolStep(kind: .search, argument: "geheime Tagebuchzeile")
        guard case .needsConsent(let request) = WebToolGuard.verdict(for: step, evidence: .init(messages: [fileReadMessage()])) else {
            Issue.record("keine Rückfrage"); return
        }
        #expect(request.detail == "geheime Tagebuchzeile")
    }

    @Test func searchingWithoutFilesNeedsNoConsent() {
        let step = ToolStep(kind: .search, argument: "wetter")
        #expect(WebToolGuard.verdict(for: step, evidence: .init(messages: [])) == .allowed)
    }

    @Test func aFailedFileReadDoesNotCount() {
        var message = fileReadMessage()
        message.toolSteps?[0].status = .failed
        let step = ToolStep(kind: .search, argument: "wetter")
        #expect(WebToolGuard.verdict(for: step, evidence: .init(messages: [message])) == .allowed)
    }

    // Simulated flow through the model: files read, then the search is declined or allowed.

    @MainActor @Test func consentDecidesTheStepInAChat() async {
        let app = TestApp.model()
        let messages = [fileReadMessage()]
        let step = ToolStep(kind: .search, argument: "geheime Zeile")

        var seen: [ToolConsentRequest] = []
        app.toolConsent = { request in seen.append(request); return false }
        let refusal = await app.webToolRefusal(for: step, messages: messages)
        #expect(refusal?.contains("nicht erlaubt") == true)
        #expect(seen.count == 1)
        #expect(seen[0].detail == "geheime Zeile")

        app.toolConsent = { _ in true }
        #expect(await app.webToolRefusal(for: step, messages: messages) == nil)
    }
}
}
