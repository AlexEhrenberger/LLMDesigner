import AVFoundation
import Foundation
import Testing
@testable import LLMDesigner

@Suite("PodcastStudio: Format, Skript, Audio")
struct PodcastTests {
    private func cast() -> [PodcastParticipant] {
        [
            PodcastParticipant(role: .moderator, name: "Lena", description: "Journalistin", voice: "serena", position: "fragt nach"),
            PodcastParticipant(role: .discussant, name: "Jonas", description: "Neurowissenschaftler", voice: "aiden", position: "dafür"),
            PodcastParticipant(role: .discussant, name: "Mira", description: "Philosophin", voice: "sohee", position: "skeptisch"),
        ]
    }

    // MARK: Format

    @Test func roundTripWithGermanKeys() throws {
        var podcast = Podcast(title: "Predictive Coding", question: "Was ist Predictive Coding?")
        podcast.minutes = 15
        podcast.participants = cast()
        podcast.references = [.document(UUID()), .chat(UUID()), .story(world: UUID(), part: UUID()), .story(world: UUID(), part: nil)]
        podcast.research = PodcastResearch(notes: "## Kernaussagen\n- Das Gehirn sagt voraus.", sources: [PodcastSource(title: "Wikipedia", url: "https://de.wikipedia.org/wiki/Predictive_Coding")])
        podcast.outline = [PodcastSection(title: "Einstieg", points: ["Begrüßung"])]
        podcast.script = [PodcastLine(speaker: podcast.participants[0].id, text: "Herzlich willkommen zu unserer Sendung über das Gehirn.", duration: 3.456)]
        podcast.phase = .finished
        podcast.duration = 612.44
        podcast.thinking = false
        podcast.tone = .heated
        podcast.ownSources = PodcastOwnSources(onlyThese: true, entries: [.url("https://example.org/a"), .pdf(title: "Studie", file: "Quellen/studie.pdf")])

        let data = try PodcastStore.encoder.encode(PodcastStore.Record(podcast: podcast))
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["\"titel\"", "\"frage\"", "\"laenge\" : 15", "\"sprachmodell\" : \"klein\"", "\"teilnehmer\"", "\"rolle\" : \"moderator\"", "\"beschreibung\"",
                    "\"stimme\" : \"serena\"", "\"referenzen\"", "\"art\" : \"romanwelt\"", "\"recherche\"", "\"notizen\"", "\"quellen\"", "\"gliederung\"",
                    "\"punkte\"", "\"skript\"", "\"sprecher\"", "\"dauer\" : 3.46", "\"phase\" : \"fertig\"", "\"denkmodus\" : false", "\"ton\" : \"hitzig\"", "\"eigeneQuellen\"", "\"nurDiese\" : true",
                    "\"art\" : \"pdf\"", "\"datei\" : \"Quellen/studie.pdf\"", "\"erstellt\"", "\"geaendert\"", "\"format\" : 1"] {
            #expect(json.contains(key), "fehlt: \(key)")
        }
        let decoded = try PodcastStore.decoder.decode(PodcastStore.Record.self, from: data).podcast
        #expect(decoded.participants == podcast.participants)
        #expect(decoded.references == podcast.references)
        #expect(decoded.research == podcast.research)
        #expect(decoded.script.first?.duration == 3.46)
        #expect(decoded.duration == 612.4)
        #expect(decoded.phase == .finished)
        #expect(decoded.thinking == false)
        #expect(decoded.tone == .heated)
        #expect(decoded.ownSources == podcast.ownSources)
    }

    @Test func readsLeniently() throws {
        let id = UUID()
        let json = """
        {"format": 1, "podcast": {"id": "\(id)", "frage": "Warum?", "laenge": 7, "sprachmodell": "riesig", "phase": "unbekannt",
          "teilnehmer": [{"rolle": "moderatorin", "name": "Ada"}, {"name": "Bo", "stimme": "eric"}],
          "referenzen": [{"art": "video", "id": "\(UUID())"}, {"art": "dokument", "id": "\(id)"}],
          "skript": [{"text": "ohne Sprecher"}, {"sprecher": "\(id)", "text": "Hallo"}]}}
        """
        let podcast = try PodcastStore.decoder.decode(PodcastStore.Record.self, from: Data(json.utf8)).podcast
        #expect(podcast.minutes == 10)
        #expect(podcast.speechModel == .small)
        #expect(podcast.phase == .draft)
        #expect(podcast.participants.map(\.role) == [.moderator, .discussant])
        #expect(podcast.participants[1].voice == "eric")
        #expect(podcast.references == [.document(id)])
        #expect(podcast.script.count == 1)
        // Files from before the new keys: thinking on, factual, no sources of their own.
        #expect(podcast.thinking)
        #expect(podcast.tone == .factual)
        #expect(podcast.ownSources.isEmpty)
    }

    @Test func startNeedsQuestionModeratorAndNames() {
        var podcast = Podcast()
        podcast.participants = cast()
        #expect(podcast.startProblem == "Gib eine Frage oder ein Thema ein.")
        podcast.question = "Was ist Bewusstsein?"
        #expect(podcast.startProblem == nil)
        podcast.participants[0].role = .discussant
        #expect(podcast.startProblem == "Es fehlt eine Moderation.")
        podcast.participants[0].role = .moderator
        podcast.participants[2].name = "lena"
        #expect(podcast.startProblem == "Zwei Teilnehmer:innen heißen gleich.")
        podcast.participants = [podcast.participants[0]]
        #expect(podcast.startProblem?.contains("Diskutant") == true)
    }

    @Test func lengthGivesWordsAndSections() {
        #expect(PodcastLength.targetWords(minutes: 5) == 700)
        #expect(PodcastLength.targetWords(minutes: 15) == 2_100)
        #expect(PodcastLength.choices.map(PodcastLength.sectionCount) == [3, 5, 7])
        var podcast = Podcast(question: "x")
        podcast.minutes = 10
        #expect(PodcastPrompts.wordBudget(podcast, sections: 5) == 280)
        #expect(PodcastLength.clock(612.4) == "10:12")
        #expect(Podcast(question: "Was ist Predictive Coding, und ist das ein zeitgemäßes Paradigma?").displayTitle == "Was ist Predictive Coding, und ist das ein zeitgemäßes …")
        #expect(PodcastLength.words(in: "Das ist – ein Test, 2026!") == 5)
    }

    // MARK: Reading the model's answers

    @Test func scriptLinesAreReadByName() {
        let people = cast()
        let answer = """
        Hier ist der Abschnitt:
        **Lena:** Willkommen zurück, Jonas, wie siehst du das mit den Vorhersagen im Gehirn?
        Jonas (Neurowissenschaftler): Ich sehe darin ein starkes Modell [lacht], das viele Befunde erklärt.
        Es verbindet Wahrnehmung und Lernen.
        - Mira: Da muss ich widersprechen, Jonas, weil die Belege oft nur indirekt sind. *seufzt*
        Mira: Und die Theorie ist sehr flexibel.
        ## Nächster Abschnitt
        """
        let lines = PodcastPrompts.lines(from: answer, participants: people)
        #expect(lines.map(\.speaker) == [people[0].id, people[1].id, people[2].id])
        #expect(lines[1].text == "Ich sehe darin ein starkes Modell, das viele Befunde erklärt. Es verbindet Wahrnehmung und Lernen.")
        // A short line of the same speaker goes with the one before.
        #expect(lines[2].text == "Da muss ich widersprechen, Jonas, weil die Belege oft nur indirekt sind. Und die Theorie ist sehr flexibel.")
        let doubled = PodcastPrompts.lines(from: "Lena: Lena: Lassen Sie mich diese hitzige Debatte kurz zusammenfassen, bitte.", participants: people)
        #expect(doubled.first?.text == "Lassen Sie mich diese hitzige Debatte kurz zusammenfassen, bitte.")
        // A name that isn't in the cast doesn't start a line of its own: the text goes on the line before.
        let unknown = PodcastPrompts.lines(from: "Lena: Wir beginnen jetzt mit der ersten Frage an unsere Gäste heute.\nMax: Ich bin nicht eingeladen.", participants: people)
        #expect(unknown.count == 1)
        #expect(unknown[0].text.hasSuffix("heute. Ich bin nicht eingeladen."))
    }

    @Test func spokenTextLosesLinksAndDirections() {
        #expect(PodcastPrompts.spoken("Laut [Wikipedia](https://de.wikipedia.org) (lacht) stimmt das.") == "Laut Wikipedia stimmt das.")
        #expect(PodcastPrompts.spoken("„Ein *flüstert* Zitat“") == "Ein Zitat")
        #expect(PodcastPrompts.spoken("Das ist *nicht* richtig (lacht leise).") == "Das ist nicht richtig.")
    }

    @Test func outlineIsReadFromHeadings() {
        let plan = """
        # Das vorhersagende Gehirn
        ## Einstieg
        - Begrüßung
        - Die Frage
        ## Was ist Predictive Coding?
        1. Fehlersignale
        2) Hierarchie
        ### Fazit
        * Zusammenfassung
        """
        let (title, sections) = PodcastPrompts.outline(from: plan)
        #expect(title == "Das vorhersagende Gehirn")
        #expect(sections.map(\.title) == ["Einstieg", "Was ist Predictive Coding?", "Fazit"])
        #expect(sections[1].points == ["Fehlersignale", "Hierarchie"])
        #expect(PodcastPrompts.fallbackOutline(minutes: 15).count == 7)
        #expect(PodcastPrompts.outline(from: "## Abschnitt 1: Der falsche Feind\n## 2. Fazit").sections.map(\.title) == ["Der falsche Feind", "Fazit"])
    }

    @Test func castGetsOneModeratorAndOwnVoices() {
        let cast = PodcastPrompts.Cast(fachgebiet: "Biologie", teilnehmer: [
            .init(rolle: "diskutant", name: "Anna", beschreibung: "Biologin", position: "dafür", geschlecht: "weiblich"),
            .init(rolle: "moderator", name: "Ben", beschreibung: "Moderator", position: "neutral", geschlecht: "männlich"),
            .init(rolle: "moderator", name: "Cem", beschreibung: "Taxifahrer", position: "dagegen", geschlecht: "männlich"),
            .init(rolle: "diskutant", name: "anna", beschreibung: "doppelt", position: "", geschlecht: nil),
        ])
        let people = PodcastPrompts.participants(from: cast, voices: ["serena", "sohee", "aiden", "eric"])
        #expect(people.map(\.name) == ["Ben", "Anna", "Cem"])
        #expect(people.map(\.role) == [.moderator, .discussant, .discussant])
        #expect(Set(people.map(\.voice)).count == 3)
        #expect(people[1].voice == "serena")
        #expect(PodcastParticipant.freeVoice(female: false, taken: ["aiden"], available: []) == "eric")
    }

    @Test func tooLongSectionsAreCut() {
        let a = UUID(), b = UUID()
        let long = String(repeating: "Wort ", count: 40)
        let lines = (0..<10).map { PodcastLine(speaker: $0 % 2 == 0 ? a : b, text: long + "\($0)") }
        let middle = PodcastPrompts.fitting(lines, budget: 100, isLast: false)
        #expect(middle.count == 3)
        let last = PodcastPrompts.fitting(lines, budget: 100, isLast: true)
        #expect(last.map(\.id) == [lines[0].id, lines[8].id, lines[9].id])
        #expect(PodcastPrompts.fitting(Array(lines.prefix(2)), budget: 100, isLast: true).count == 2)
        #expect(PodcastPrompts.contributions(233) == 7)
        #expect(PodcastTone.at(9) == .heated)
        #expect(PodcastPrompts.toneInstruction(.heated).contains("beleidigen"))
    }

    @Test func lineStartsCountPauses() {
        let people = cast()
        var podcast = Podcast(question: "x")
        podcast.participants = people
        podcast.script = [
            PodcastLine(speaker: people[0].id, text: "a", duration: 2),
            PodcastLine(speaker: people[0].id, text: "b", duration: 3),
            PodcastLine(speaker: people[1].id, text: "c", duration: 1),
        ]
        let starts = podcast.lineStarts
        #expect(starts[podcast.script[1].id] == 2 + PodcastAudio.pauseSameSpeaker)
        #expect(abs((starts[podcast.script[2].id] ?? 0) - (5 + PodcastAudio.pauseSameSpeaker + PodcastAudio.pauseNewSpeaker)) < 0.0001)
    }

    // MARK: Audio

    /// A tone as Qwen TTS sends it: 16-bit mono WAV at 24 kHz.
    private func tone(_ seconds: Double) -> Data {
        let rate = 24_000
        let frames = Int(seconds * Double(rate))
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for frame in 0..<frames { append(Int16(sin(Double(frame) * 0.1) * 2_000)) }
        return data
    }

    @Test func snippetsJoinIntoOneM4A() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("Schnipsel/a.wav")
        let second = folder.appendingPathComponent("Schnipsel/b.wav")
        let one = try PodcastAudio.writeSnippet([tone(1.0), tone(0.5)], to: first)
        #expect(abs(one - (1.5 + PodcastAudio.pauseWithinLine)) < 0.01)
        #expect(abs(try PodcastAudio.duration(of: first) - one) < 0.01)
        let two = try PodcastAudio.writeSnippet([tone(2.0)], to: second)

        let a = UUID(), b = UUID()
        let output = folder.appendingPathComponent("Podcast.m4a")
        let total = try PodcastAudio.joinPodcast([(first, a), (first, a), (second, b)], to: output)
        let expected = one * 2 + two + PodcastAudio.pauseSameSpeaker + PodcastAudio.pauseNewSpeaker
        #expect(abs(total - expected) < 0.05)
        let file = try AVAudioFile(forReading: output)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - expected) < 0.15)
        // Joined again over the old file: replaced, no leftovers next to it.
        _ = try PodcastAudio.joinPodcast([(second, b)], to: output)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Podcast.m4a", "Schnipsel"])
        #expect(throws: PodcastAudio.Failure.self) { try PodcastAudio.joinPodcast([], to: output) }
    }

    // MARK: Library

    @MainActor
    @Test func changedLinesLoseTheirSnippets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = PodcastLibrary(store: PodcastStore(directory: folder))
        var podcast = Podcast(question: "x")
        podcast.participants = cast()
        let kept = PodcastLine(speaker: podcast.participants[0].id, text: "bleibt", duration: 1)
        let changed = PodcastLine(speaker: podcast.participants[1].id, text: "alt", duration: 1)
        let gone = PodcastLine(speaker: podcast.participants[2].id, text: "weg", duration: 1)
        podcast.script = [kept, changed, gone]
        library.add(podcast)
        for line in podcast.script {
            let url = library.store.snippetURL(of: podcast.id, line: line.id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try tone(0.1).write(to: url)
        }
        library.update(podcast.id) { podcast in
            podcast.script[1].text = "neu"
            podcast.script.removeLast()
        }
        let after = try #require(library.podcast(podcast.id))
        #expect(after.script[0].duration == 1)
        #expect(after.script[1].duration == nil)
        #expect(library.store.hasSnippet(of: podcast.id, line: kept.id))
        #expect(!library.store.hasSnippet(of: podcast.id, line: changed.id))
        #expect(!library.store.hasSnippet(of: podcast.id, line: gone.id))

        // A podcast that was being made when the app quit is stopped after loading.
        library.update(podcast.id) { $0.phase = .speaking }
        library.saveAll()
        let reloaded = PodcastLibrary(store: PodcastStore(directory: folder))
        reloaded.loadIfNeeded()
        #expect(reloaded.podcast(podcast.id)?.phase == .stopped)
        #expect(reloaded.podcast(podcast.id)?.script.count == 2)
        reloaded.saveAll()
    }
}
