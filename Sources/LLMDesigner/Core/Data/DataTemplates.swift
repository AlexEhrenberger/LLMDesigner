import Foundation

// Templates in Data Studio: a Writer document to start from (a letter, a CV) or a master for presentations (design,
// logo, header, footer). A template names roles ("Absender", "Empfänger"); when it is used, each role gets one of
// the person's data blocks and the template's `{{absender.strasse}}` becomes `{{user1.strasse}}`.

/// Ready-made sets of fields for a new block. Their field keys are what the built-in templates expect.
enum DataStructure: String, CaseIterable, Identifiable, Codable, Sendable {
    case person, organisation, anschrift, kontakt, bank, frei

    var id: String { rawValue }

    var label: String {
        switch self {
        case .person: "Person"
        case .organisation: "Firma / Behörde"
        case .anschrift: "Anschrift"
        case .kontakt: "Kontakt"
        case .bank: "Bankverbindung"
        case .frei: "Frei"
        }
    }

    var symbol: String {
        switch self {
        case .person: "person.crop.rectangle"
        case .organisation: "building.2"
        case .anschrift: "house"
        case .kontakt: "phone.bubble"
        case .bank: "creditcard"
        case .frei: "square.dashed"
        }
    }

    var group: String {
        switch self {
        case .person: "Personen"
        case .organisation: "Firmen und Behörden"
        case .anschrift: "Anschriften"
        case .kontakt: "Kontakte"
        case .bank: "Bank"
        case .frei: ""
        }
    }

    var fields: [DataField] {
        func f(_ key: String, _ name: String, _ kind: DataFieldKind = .text) -> DataField { DataField(key: key, name: name, kind: kind) }
        switch self {
        case .person:
            return [f("anrede", "Anrede"), f("titel", "Titel"), f("vorname", "Vorname"), f("nachname", "Nachname"),
                    f("strasse", "Straße und Hausnummer"), f("plz", "PLZ"), f("ort", "Ort"), f("land", "Land"),
                    f("telefon", "Telefon", .telefon), f("email", "E-Mail", .email), f("geburtsdatum", "Geburtsdatum", .datum),
                    f("geburtsort", "Geburtsort"), f("staatsangehoerigkeit", "Staatsangehörigkeit")]
        case .organisation:
            return [f("firma", "Firma / Behörde"), f("abteilung", "Abteilung"), f("anrede", "Anrede"), f("ansprechpartner", "Ansprechpartner"),
                    f("strasse", "Straße und Hausnummer"), f("plz", "PLZ"), f("ort", "Ort"), f("land", "Land"),
                    f("telefon", "Telefon", .telefon), f("email", "E-Mail", .email), f("web", "Internet", .link)]
        case .anschrift:
            return [f("name", "Name"), f("strasse", "Straße und Hausnummer"), f("plz", "PLZ"), f("ort", "Ort"), f("land", "Land")]
        case .kontakt:
            return [f("telefon", "Telefon", .telefon), f("mobil", "Mobil", .telefon), f("email", "E-Mail", .email), f("web", "Internet", .link)]
        case .bank:
            return [f("inhaber", "Kontoinhaber"), f("iban", "IBAN"), f("bic", "BIC"), f("bank", "Bank")]
        case .frei:
            return [f("text", "Text", .mehrzeilig)]
        }
    }

    /// How `{{block}}` shows the whole block: an address field for people and firms.
    var display: String {
        switch self {
        case .person: "{anrede}\n{titel} {vorname} {nachname}\n{strasse}\n{plz} {ort}"
        case .organisation: "{firma}\n{abteilung}\n{ansprechpartner}\n{strasse}\n{plz} {ort}"
        case .anschrift: "{name}\n{strasse}\n{plz} {ort}\n{land}"
        case .kontakt: "{telefon}\n{email}"
        case .bank: "{inhaber}\nIBAN {iban}\nBIC {bic}\n{bank}"
        case .frei: ""
        }
    }

    var defaultSymbol: String { symbol }
}

/// A role in a template that one data block fills.
struct TemplateSlot: Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var name: String
    var structure: DataStructure = .person
}

extension TemplateSlot: Codable {
    private enum CodingKeys: String, CodingKey { case kuerzel, name, struktur }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.soft(.kuerzel, "daten")
        name = c.soft(.name, key)
        structure = c.soft(.struktur, DataStructure.person)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .kuerzel)
        try c.encode(name, forKey: .name)
        try c.encode(structure, forKey: .struktur)
    }
}

/// What a presentation master puts on every slide: a logo at a fixed place, a header and a footer, page numbers.
struct SlideMaster: Hashable, Sendable {
    enum Corner: String, Codable, CaseIterable, Identifiable, Sendable {
        case obenLinks, obenRechts, untenLinks, untenRechts

        var id: String { rawValue }

        var label: String {
            switch self {
            case .obenLinks: "Oben links"
            case .obenRechts: "Oben rechts"
            case .untenLinks: "Unten links"
            case .untenRechts: "Unten rechts"
            }
        }

        var isTop: Bool { self == .obenLinks || self == .obenRechts }
        var isLeft: Bool { self == .obenLinks || self == .untenLinks }
    }

    /// The logo's file in the template's folder (`logo.png`); nil: none.
    var logo: String?
    var logoCorner: Corner = .obenRechts
    /// The logo's width as a share of the slide's width.
    var logoSize = 0.12
    var header = ""
    var footer = ""
    var pageNumbers = true
    /// The title slide shows the master too (usually it stays clean).
    var onTitle = false
    /// A thin line above the footer.
    var rule = true

    var isEmpty: Bool {
        logo == nil && header.trimmingCharacters(in: .whitespaces).isEmpty && footer.trimmingCharacters(in: .whitespaces).isEmpty && !pageNumbers
    }
}

extension SlideMaster: Codable {
    private enum CodingKeys: String, CodingKey { case logo, logoEcke, logoGroesse, kopfzeile, fusszeile, seitenzahlen, aufTitelfolie, linie }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logo = c.soft(.logo, String?.none)
        logoCorner = c.soft(.logoEcke, Corner.obenRechts)
        logoSize = c.soft(.logoGroesse, 0.12)
        header = c.soft(.kopfzeile, "")
        footer = c.soft(.fusszeile, "")
        pageNumbers = c.soft(.seitenzahlen, true)
        onTitle = c.soft(.aufTitelfolie, false)
        rule = c.soft(.linie, true)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encode(logoCorner, forKey: .logoEcke)
        try c.encode(logoSize, forKey: .logoGroesse)
        try c.encode(header, forKey: .kopfzeile)
        try c.encode(footer, forKey: .fusszeile)
        try c.encode(pageNumbers, forKey: .seitenzahlen)
        try c.encode(onTitle, forKey: .aufTitelfolie)
        try c.encode(rule, forKey: .linie)
    }
}

/// A template for Writer or Presenter.
struct DataTemplate: StoredRecord {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case writer, presenter

        var id: String { rawValue }
        var label: String { self == .writer ? "Writer-Vorlage" : "Masterfolie" }
        var plural: String { self == .writer ? "Dokumentvorlagen" : "Masterfolien" }
        var symbol: String { self == .writer ? StudioApplication.writer.symbol : StudioApplication.presenter.symbol }
    }

    var id = UUID()
    var name = ""
    var kind: Kind = .writer
    var summary = ""
    var symbol = "doc.text"
    var slots: [TemplateSlot] = []
    // Writer
    var markdown = ""
    var font: String?
    var pageFormat: String?
    // Presenter
    var master = SlideMaster()
    var backgrounds: RoleBackgrounds?
    /// Slides to start with, as the deck stores them; empty: a title slide.
    var slides = ""
    /// Set for the templates that come with the app; they are shown but never written.
    var builtIn: String?
    var createdAt = Date()
    var updatedAt = Date()

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Ohne Namen" : trimmed
    }

    var isBuiltIn: Bool { builtIn != nil }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [name, summary, markdown, master.header, master.footer].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The text with the roles replaced by the chosen blocks' keys; roles left open keep their names.
    func markdown(filling choices: [String: String]) -> String {
        Self.fill(markdown, choices)
    }

    static func fill(_ text: String, _ choices: [String: String]) -> String {
        DataTokens.replace(in: text) { ref in
            guard let key = choices[ref.block.lowercased()] else { return nil }
            return DataRef(block: key, field: ref.field).token
        }
    }

    /// The keys of blocks the template refers to that are not its roles (fixed blocks like `heute`).
    var referencedKeys: [String] {
        var keys: [String] = []
        for (_, ref) in DataTokens.find(in: markdown + "\n" + master.header + "\n" + master.footer) where !keys.contains(ref.block.lowercased()) {
            keys.append(ref.block.lowercased())
        }
        return keys
    }
}

extension DataTemplate: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, art, beschreibung, symbol, rollen, text, schrift, seitenformat, master, hintergruende, folien, eingebaut, erstellt, geaendert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.soft(.id, UUID())
        name = c.soft(.name, "")
        kind = c.soft(.art, Kind.writer)
        summary = c.soft(.beschreibung, "")
        symbol = c.soft(.symbol, kind == .writer ? "doc.text" : "rectangle.on.rectangle")
        slots = c.soft(.rollen, [TemplateSlot]())
        markdown = c.soft(.text, "")
        font = c.soft(.schrift, String?.none)
        pageFormat = c.soft(.seitenformat, String?.none)
        master = c.soft(.master, SlideMaster())
        backgrounds = c.soft(.hintergruende, RoleBackgrounds?.none)
        slides = c.soft(.folien, "")
        builtIn = c.soft(.eingebaut, String?.none)
        createdAt = c.soft(.erstellt, Date())
        updatedAt = c.soft(.geaendert, createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .art)
        try c.encode(summary, forKey: .beschreibung)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(slots, forKey: .rollen)
        if kind == .writer {
            try c.encode(markdown, forKey: .text)
            try c.encodeIfPresent(font, forKey: .schrift)
            try c.encodeIfPresent(pageFormat, forKey: .seitenformat)
        } else {
            try c.encode(master, forKey: .master)
            try c.encodeIfPresent(backgrounds, forKey: .hintergruende)
            if !slides.isEmpty { try c.encode(slides, forKey: .folien) }
        }
        try c.encodeIfPresent(builtIn, forKey: .eingebaut)
        try c.encode(createdAt, forKey: .erstellt)
        try c.encode(updatedAt, forKey: .geaendert)
    }
}

// MARK: - Built-in templates

extension DataTemplate {
    /// Fixed ids, so a document can say which template it came from across launches.
    static let letterID = UUID(uuidString: "5D0C4B9E-0B1A-4E55-9A51-2B7D0C0D5001")!
    static let cvID = UUID(uuidString: "5D0C4B9E-0B1A-4E55-9A51-2B7D0C0D5002")!
    static let masterID = UUID(uuidString: "5D0C4B9E-0B1A-4E55-9A51-2B7D0C0D5003")!

    static let builtIns: [DataTemplate] = [letter, cv, plainMaster]

    /// A business letter as DIN 5008 sets it: sender, return line, address field, date on the right, subject in bold,
    /// salutation, text, closing, name. On DIN A4.
    static var letter: DataTemplate {
        var template = DataTemplate(name: "Brief (DIN 5008)", kind: .writer)
        template.id = letterID
        template.builtIn = "brief-din5008"
        template.symbol = "envelope"
        template.summary = "Geschäftsbrief nach DIN 5008: Absender, Rücksendeangabe, Anschriftfeld, Datum, Betreff, Anrede, Gruß."
        template.slots = [TemplateSlot(key: "absender", name: "Absender", structure: .person),
                          TemplateSlot(key: "empfaenger", name: "Empfänger", structure: .organisation)]
        template.pageFormat = WriterPageFormat.standard.rawValue
        template.font = WriterFont.sans.rawValue
        template.markdown = """
        ::: {.right}
        **{{absender.vorname}} {{absender.nachname}}**
        {{absender.strasse}}
        {{absender.plz}} {{absender.ort}}
        Telefon: {{absender.telefon}}
        E-Mail: {{absender.email}}
        :::

        <span style="font-size:8pt">{{absender.vorname}} {{absender.nachname}} · {{absender.strasse}} · {{absender.plz}} {{absender.ort}}</span>

        {{empfaenger}}

        ::: {.right}
        {{absender.ort}}, {{heute}}
        :::

        **Betreff des Briefes**

        Sehr geehrte Damen und Herren,

        hier steht der Text Ihres Briefes. Nach DIN 5008 beginnt er eine Leerzeile unter der Anrede, die Absätze trennt je eine Leerzeile.

        Mit freundlichen Grüßen

        {{absender.vorname}} {{absender.nachname}}

        """
        return template
    }

    /// A German CV in table form: personal data, experience and education in reverse order, skills, place and date.
    static var cv: DataTemplate {
        var template = DataTemplate(name: "Lebenslauf (tabellarisch)", kind: .writer)
        template.id = cvID
        template.builtIn = "lebenslauf"
        template.symbol = "person.text.rectangle"
        template.summary = "Tabellarischer Lebenslauf, wie er in Deutschland üblich ist: persönliche Daten, Berufserfahrung und Ausbildung (neueste zuerst), Kenntnisse, Ort und Datum."
        template.slots = [TemplateSlot(key: "person", name: "Person", structure: .person)]
        template.pageFormat = WriterPageFormat.standard.rawValue
        template.font = WriterFont.sans.rawValue
        template.markdown = """
        # Lebenslauf

        ## Persönliche Daten

        | Angabe | |
        |---|---|
        | Name | {{person.vorname}} {{person.nachname}} |
        | Anschrift | {{person.strasse}}, {{person.plz}} {{person.ort}} |
        | Telefon | {{person.telefon}} |
        | E-Mail | {{person.email}} |
        | Geburtsdatum | {{person.geburtsdatum}} in {{person.geburtsort}} |
        | Staatsangehörigkeit | {{person.staatsangehoerigkeit}} |

        ## Berufserfahrung

        | Zeitraum | Tätigkeit |
        |---|---|
        | 01/2023 – heute | **Position**, Unternehmen, Ort – wichtigste Aufgaben und Erfolge |
        | 09/2019 – 12/2022 | **Position**, Unternehmen, Ort – wichtigste Aufgaben und Erfolge |

        ## Ausbildung

        | Zeitraum | Abschluss |
        |---|---|
        | 10/2015 – 08/2019 | **Studium**, Hochschule, Ort – Abschluss und Note |
        | 08/2007 – 06/2015 | **Abitur**, Schule, Ort – Note |

        ## Kenntnisse

        | Bereich | Kenntnisse |
        |---|---|
        | Sprachen | Deutsch (Muttersprache), Englisch (verhandlungssicher) |
        | EDV | Programme und Werkzeuge |
        | Sonstiges | Führerschein, Zertifikate |

        ## Interessen

        Ehrenamt, Sport, weitere Interessen

        {{person.ort}}, {{heute}}

        {{person.vorname}} {{person.nachname}}

        """
        return template
    }

    /// A plain master: title and date in the footer, page numbers; duplicate it to add a logo.
    static var plainMaster: DataTemplate {
        var template = DataTemplate(name: "Master: Klar", kind: .presenter)
        template.id = masterID
        template.builtIn = "master-klar"
        template.symbol = "rectangle.on.rectangle"
        template.summary = "Fußzeile mit Titel und Datum, Seitenzahlen, ruhiges Design. Duplizieren, um ein Logo und eigene Zeilen einzusetzen."
        template.master = SlideMaster(logo: nil, logoCorner: .obenRechts, logoSize: 0.12, header: "", footer: "{{titel}} · {{heute.kurz}}",
                                      pageNumbers: true, onTitle: false, rule: true)
        return template
    }
}
