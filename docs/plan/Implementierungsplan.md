# Implementierungsplan: Action-Schicht → CLI `llmd` → MCP

_Für die Umsetzung mit Claude Code (Modell: Claude Opus 5.5) · Stand: 02.11.2026_
_Repository: `AlexEhrenberger/LLMDesigner` · Basis-Commit: `c7e95c3`_
_Konzepte: Action-Kataloge (`*-Actions.md`), `CLI-Konzept.md`, `MCP-Schicht.md`, **`Sicherheitskonzept-Prompt-Injection.md`**_

---

## 0. So wird dieser Plan benutzt

1. **Plan ins Repo legen:** Diesen Plan und die Konzepte als `docs/plan/` ins Repository kopieren (Aufgabe 0.1), damit Claude Code sie in jeder Sitzung lesen kann.
2. **Eine Phase pro Sitzung.** Jede Phase beginnt im Plan-Modus (Claude Code liest, schlägt Vorgehen vor, du bestätigst), endet mit grünen Tests und einem Commit.
3. **Am Ende jeder Phase:** Claude Code aktualisiert den Abschnitt „Fortschritt“ in `docs/plan/Implementierungsplan.md` und die betroffenen `docs/*.md`.
4. **Startanweisungen** für jede Phase stehen in Abschnitt 9 – einfach in Claude Code einfügen.

---

## 1. Ziel

Jede Bedienhandlung von LLMDesigner wird eine **Action** in einer zentralen Registry. Dieselbe Action ist erreichbar über:
- die Oberfläche (später schrittweise umgestellt),
- das Terminal (`llmd`),
- MCP (`llmd mcp`) für Claude Desktop/Claude Code,
- den internen Chat als Tool-Gruppe.

Die Registry setzt dabei die Sicherheitsregeln aus `Sicherheitskonzept-Prompt-Injection.md` durch (Herkunft, „Rule of Two“, Ausgangskontrolle).

**Nicht-Ziele in diesem Plan:** UI-Umbau, neue Studios, Hintergrundbetrieb ohne Fenster, Cloud-Anbieter im `LLMClient`, KI-Funktionen für Citation/Stories, AgentSteps (eigener Plan).

---

## 2. Feste Regeln für Claude Code

**Lesen vor Schreiben**
- Vor jeder Phase lesen: `docs/architektur.md`, `docs/code.md`, diesen Plan, den relevanten Action-Katalog und das Sicherheitskonzept.
- Bestehende Funktionen in `AppModel+*.swift` **wiederverwenden**, nicht neu schreiben. Actions sind dünne Hüllen.

**Code-Stil (aus dem bestehenden Projekt)**
- Swift 6 Toolchain, `swiftLanguageMode(.v5)` beibehalten, macOS 15 als Mindestziel.
- Zustand auf dem Main Actor; Netzwerk/Prozesse in `Task`s.
- Oberflächentexte und Fehlermeldungen auf **Deutsch**, Code-Kommentare wie im Bestand.
- Keine neuen Fremdabhängigkeiten außer den in diesem Plan genannten (swift-argument-parser, ggf. MCP-Swift-SDK) – jeweils erst nach Rückfrage.

**Qualität**
- Jede Action bekommt mindestens einen Test (Swift Testing), der sie **direkt über die Registry** ausführt – ohne Socket, ohne Fenster.
- `scripts/test.sh` muss am Ende jeder Phase grün sein; bestehende 171 Tests bleiben grün.
- Kleine Commits mit klarer Nachricht; ein Commit pro abgeschlossener Aufgabe.

**Sicherheit**
- Schutz entsteht durch **Regeln im Code**, nie durch Anweisungen im Prompt. Kein Erkennungsfilter als alleiniger Schutz.
- Jede Action deklariert `liestFremdes`, `sensibel` und `wirkung`; neue Actions ohne diese Angaben lassen sich nicht registrieren.
- Keine Netzwerkports öffnen. Socket nur für den eigenen Benutzer.
- API-Schlüssel nie in Ergebnissen, Protokoll oder Fehlermeldungen.
- Actions der Art D (destruktiv/sensibel) laufen immer durch die Freigabeprüfung.

**Bei Unklarheit:** anhalten und fragen statt raten – besonders bei Datenformaten (`.llmdlibrary`) und allem, was gespeicherte Daten verändert.

---

## 3. Zielstruktur

```
Package.swift
├── Sources/LLMDProtocol/            (neu, Bibliothek – keine App-Abhängigkeiten)
│   ├── RPC.swift                    JSON-RPC-Nachrichten, Fehlercodes
│   ├── ActionDescriptor.swift       ID, Zusammenfassung, Art (L/S/D), Sicherheitsmerkmale, Schema, Beispiel
│   ├── JSONSchema.swift             kleiner Schema-Baukasten (JSON Schema 2020-12)
│   ├── JSONValue.swift              beliebige JSON-Werte
│   └── SocketPaths.swift            Pfade für Socket und Token
├── Sources/LLMDesigner/
│   └── Actions/                     (neu)
│       ├── Action.swift             Protokoll LLMDAction
│       ├── ActionRegistry.swift     Registrierung, Prüfung, Undo-Gruppe, Protokoll, Freigabe
│       ├── ActionPolicy.swift       Rule-of-Two-Entscheidung, Lauf-Zustand (A/B)
│       ├── ActionServer.swift       Unix-Socket (Network.framework), Token, Peer-Prüfung
│       ├── ActionApproval.swift     Freigabestufen je Kanal, Dialog mit Begründung
│       ├── ActionLog.swift          Aktivitätsprotokoll
│       ├── Provenance.swift         Herkunft eigen/intern/fremd, Ansteckung
│       ├── Addressing.swift         Adressen: doc, block, heading, match, range, slide …
│       ├── App/                     app.status, models.list …
│       ├── Writer/                  writer.* Actions
│       ├── Presenter/ Citation/ Stories/ Chat/   (spätere Phasen)
├── Sources/llmd/                    (neu, Programm)
│   ├── main.swift                   ArgumentParser-Grundbefehle
│   ├── Client.swift                 Socket-Verbindung, App starten falls nötig
│   ├── DynamicCommands.swift        Befehle aus Schema, Optionen, --stdin, --json
│   ├── Output.swift                 Mensch-/JSON-Ausgabe, Exit-Codes
│   └── MCP/                         (Phase 5) Adapter
└── Tests/
    ├── LLMDesignerTests/Actions/    Registry- und Action-Tests
    ├── LLMDesignerTests/Security/   Regeltests, präparierte Angriffsinhalte
    └── llmdTests/                   Parser-, Ausgabe-, MCP-Übersetzungstests
```

### Kernvertrag

```swift
enum ActionKind: String, Codable { case read, write, destructive }
enum ActionEffect: String, Codable { case none, local, destructive, outbound }

struct ActionSecurity: Codable {
    var readsUntrusted: Bool        // A – liestFremdes (kann zusätzlich dynamisch gesetzt werden)
    var sensitive: Bool             // B – sensibel
    var effect: ActionEffect        // C – wirkung
}

protocol LLMDAction {
    associatedtype Args: Decodable & Sendable
    associatedtype Output: Encodable & Sendable
    static var descriptor: ActionDescriptor { get }   // id, summary, kind, security, schema, example
    @MainActor static func run(_ args: Args, context: ActionContext) async throws -> Output
}

struct ActionContext {
    let app: AppModel
    let channel: Channel          // .ui, .cli, .mcp, .chat
    let run: RunState             // Lauf-ID, hat Fremdes gelesen (A), hat Sensibles gelesen (B)
    let undoGroup: UndoGroup
}
```

### Schlüsseltechnik für Writer-Actions ohne Editor
Writer-Actions arbeiten auf dem **Dokumentmodell (Markdown)**, nicht auf `NSTextView`:
1. Markdown laden → `WriterMarkdown.attributedString(...)` (existiert in `Core/WriterMarkdown.swift`)
2. Adresse auflösen (Block, Überschrift, Treffer) → Bereich im attributierten Text
3. Änderung anwenden (z. B. Attribut `.writerBold`, Blocktyp `.writerBlock`) mit den vorhandenen Stil-Helfern
4. Zurück → `WriterMarkdown.markdown(...)` → `AppModel.updateDocument` (der offene Editor lädt dann selbst neu)

Damit funktionieren Actions auch bei geschlossenem Dokument. **Risiko:** Hin-und-zurück-Treue. Gegenmaßnahme: Rundlauf-Tests (Markdown → attributiert → Markdown ergibt identischen Text) für alle Blocktypen, bevor Actions darauf aufbauen.

### Adressierung und Konflikte
- Jede Lese-Action liefert eine **`version`** des Dokuments (Hash des Markdowns).
- Schreib-Actions akzeptieren optional `ifVersion`; passt sie nicht, Fehler −32030 „Dokument wurde inzwischen geändert“.
- **Block-IDs** zunächst flüchtig (gültig für eine `version`); persistente IDs sind eine spätere Entscheidung (offene Frage).
- Adressformen Phase 2: `range`, `block` (+`version`), `heading` (Pfad), `match` (+`occurrence`), `all`.

---

## 4. Phasen

### Phase S – Sicherheits-Sofortmaßnahme (½ Sitzung, vor allem anderen)

Hintergrund: In einem Chat mit Persona-Dateien **und** Websuche existiert heute das „tödliche Dreieck“ – `open_page(url)` darf jede Adresse abrufen und könnte private Dateiinhalte in der URL hinausschicken (Sicherheitskonzept, Abschnitt 2).

| # | Aufgabe | Abnahme |
|---|---|---|
| S.1 | `open_page` nur für Adressen zulassen, die in der Nutzernachricht stehen oder wörtlich in einem Suchergebnis dieses Chats vorkamen | Test: erfundene URL → abgelehnt mit verständlicher Meldung an das Modell |
| S.2 | Abfrageparameter, die nicht aus dieser Quelle stammen, ablehnen | Test: Suchergebnis-URL + angehängtes `?d=…` → abgelehnt |
| S.3 | Wenn im Chat Persona-Dateien gelesen wurden: `open_page` und `web_search` danach nur nach Rückfrage | Test mit simuliertem Ablauf |
| S.4 | Prüfen und berichten: LaTeX-Dateizugriff über Roh-Blöcke (`\input`, `\openin`), Netzwerkzugriffe aus WebViews | Kurzbericht im Fortschritt; Fix als eigene Aufgabe vorschlagen |

### Phase 0 – Vorbereitung (½ Sitzung)

| # | Aufgabe | Abnahme |
|---|---|---|
| 0.1 | Plan und Konzepte nach `docs/plan/` kopieren (Kataloge, CLI-, MCP-, Sicherheitskonzept, dieser Plan) | Dateien im Repo, in `docs/index.md` verlinkt |
| 0.2 | `CLAUDE.md` im Repo-Wurzelverzeichnis anlegen: Build-/Testbefehle, Regeln aus Abschnitt 2, Verweis auf `docs/plan/` | Datei vorhanden, knapp (< 80 Zeilen) |
| 0.3 | README-Abweichungen korrigieren (z. B. „UI immer schwarz“) | README stimmt mit Code überein |
| 0.4 | Bestandsaufnahme: `scripts/test.sh` ausführen, Laufzeit notieren | alle Tests grün, Ergebnis im Fortschritt notiert |

### Phase 1 – Fundament: Protokoll, Registry, Sicherheitsregel, Socket, `llmd status` (2 Sitzungen)

| # | Aufgabe | Abnahme |
|---|---|---|
| 1.1 | Ziel `LLMDProtocol` anlegen (RPC-Typen, Fehlercodes, `ActionDescriptor` **mit `ActionSecurity`**, `JSONSchema`, `JSONValue`) | baut ohne App-Abhängigkeit; Codable-Tests |
| 1.2 | `LLMDAction`, `ActionRegistry` mit Parameterprüfung gegen Schema, Undo-Gruppe, Protokoll; Registrierung ohne Sicherheitsangaben unmöglich | Test: unbekannte Action → −32601; falsche Parameter → −32602 |
| 1.3 | `ActionPolicy`: Lauf-Zustand (A/B) und Entscheidungsregel aus Sicherheitskonzept 4.2 | **Tabellengetriebene Regeltests für alle Kombinationen** Kanal × A × B × Wirkung |
| 1.4 | `ActionApproval`: Freigabestufen je Kanal × Art; Dialog zeigt Action, Ziel, Daten (gekürzt) und **Grund** | Tests; Dialog vorerst als einfacher `NSAlert` |
| 1.5 | `ActionServer`: `NWListener` auf Unix-Socket `~/Library/Application Support/LLMDesigner/llmd.sock`, Rechte 0600, Token-Datei, Peer-UID-Prüfung, zeilenweises JSON-RPC | Socket entsteht beim App-Start, wird beim Beenden entfernt; veralteter Socket wird ersetzt |
| 1.6 | Erste Actions: `app.status`, `actions.list`, `actions.describe`, `writer.doc.list`, `writer.doc.read` | Registry-Tests grün |
| 1.7 | Ziel `llmd` mit swift-argument-parser (nach Rückfrage: Paket oder `Vendor/`): `status`, `actions`, `describe`, `call` | `llmd status` zeigt Version und Bibliothek; `llmd call writer.doc.list --json` liefert JSON |
| 1.8 | App automatisch starten, wenn Socket fehlt (`--no-launch` verhindert es) | Aufruf bei geschlossener App startet sie und antwortet |
| 1.9 | `build-app.sh`: `llmd` nach `Contents/Helpers/` kopieren | gebaute App enthält `llmd` |

### Phase 2 – Writer-Minimalsatz, Herkunft und dynamische Befehle (2–3 Sitzungen)

| # | Aufgabe | Abnahme |
|---|---|---|
| 2.1 | Rundlauf-Tests Markdown ⇄ attributiert für alle Blocktypen und Inline-Formate | Tests grün oder Abweichungen dokumentiert und behoben |
| 2.2 | `Addressing.swift`: Auflösung von `range`, `block`, `heading`, `match`, `all`; `version`/`ifVersion` | Tests für Mehrdeutigkeit, kein Treffer, veraltete Version |
| 2.3 | `Provenance.swift`: Herkunft `eigen`/`intern`/`fremd` im YAML-Kopf und je Block; Lesen eines `fremd`-Dokuments setzt A im Lauf; Schreiben aus A-Lauf markiert Ziel als `fremd` | Tests für Ansteckung und „als geprüft bestätigen“ |
| 2.4 | Lesen: `writer.blocks.list`, `writer.outline.get`, `writer.find`, `writer.doc.stats` | Tests |
| 2.5 | Verwalten: `writer.doc.create/open/rename/move/delete` | Tests; `delete` läuft durch Freigabe |
| 2.6 | Text: `writer.text.insert`, `insertMarkdown`, `replace`, `delete`, `writer.paragraph.new` | Tests inkl. geöffnetem Dokument (Editor lädt neu) |
| 2.7 | Format: `writer.format.bold/italic/underline/strikethrough/code/superscript/subscript` mit `state: toggle\|on\|off`, `writer.format.clear` | Tests; `on` ist idempotent |
| 2.8 | Block: `writer.block.set`, `writer.list.level`, `writer.paragraph.align`, `writer.insert.rule`, `writer.insert.pageBreak` | Tests |
| 2.9 | `writer.edit.undo/redo` über die Undo-Gruppen der Registry | Test: Action + Undo ergibt Ausgangs-Markdown |
| 2.10 | `writer.export` (pdf, latex, markdown) mit `path`; **nur Exportordner**, andere Pfade mit Freigabe; `wirkung: nachAußen` | Tests für erlaubte/abgelehnte Pfade |
| 2.11 | `llmd`: dynamische Befehle aus Schema (`llmd writer format bold …`), `camelCase`→`--kebab-case`, Positionsparameter, `--stdin`, `--json`, `--quiet`, Exit-Codes; Schema-Cache je App-Version | Parser-Tests; Beispiele aus `CLI-Konzept.md` Abschnitt 8 laufen |

### Phase 3 – Alltagstauglichkeit (1–2 Sitzungen)

| # | Aufgabe | Abnahme |
|---|---|---|
| 3.1 | `action.batch` + `llmd batch` (JSONL, eine Undo-Gruppe, Abbruch beim ersten Fehler) | Test: Fehler in Zeile 3 → nichts geändert |
| 3.2 | `events.subscribe` + `llmd watch` (Dokument geändert, Action ausgeführt) | manuell prüfbar, Test für Ereignisformat |
| 3.3 | Aktivitäts-Panel in der App (Zeit, Kanal, Lauf, Action, **Herkunftsstatus A/B, Entscheidung der Regel**, Ergebnis) | sichtbar, filterbar nach Kanal |
| 3.4 | Einstellungen: Freigabestufen je Kanal; Exportordner; „Kommandozeilenwerkzeug installieren“ (Link nach `~/.local/bin`) | Link funktioniert; Freigaben wirken |
| 3.5 | `llmd completion zsh` aus Schema | Tab-Vervollständigung für Module, Actions, Optionen |
| 3.6 | Hervorhebung von Änderungen durch CLI/MCP im offenen Editor (kurz aufleuchten) | sichtbar beim Zuschauen |
| 3.7 | WebViews: Netzwerkzugriffe per `WKContentRuleList` sperren; eigene CSS-Designs ohne `url(http…)` | Test/manuelle Prüfung: externe Ressource wird nicht geladen |

### Phase 4 – Weitere Studios (je Studio 1 Sitzung)

Reihenfolge und Umfang je Minimalsatz aus den Katalogen; **jede Action mit Sicherheitsmerkmalen**:
- **4.1 Presenter** (~12): Folien-Adressierung `--deck/--slide/--field`; `writer.*` auf Folien; `presenter.slide.render` (PNG) – Renderer aus `SlidePrinter` nutzen.
- **4.2 Citation** (~8): Adressierung über Citekey; vorhandene Suchsyntax durchreichen; Quellen, Anhänge und Importe sind `fremd` (A), Paraphrasen `eigen`.
- **4.3 Stories** (~10): generische `stories.element.*` mit `kind`; `stories.world.read --depth overview`.
- **4.4 Chat** (~8): `chat.create`, `chat.ask`, `chat.read`, `chat.list`, `chat.search`, `persona.list`, `skill.list`, `models.list`; Rekursionsschutz; `memory.*` und `persona.files.*` als `sensibel` (B).

Abnahme je Studio: alle Minimalsatz-Actions mit Tests; Beispiel-Skript in `docs/plan/beispiele/`.

### Phase 5 – MCP-Adapter `llmd mcp` (2 Sitzungen)

| # | Aufgabe | Abnahme |
|---|---|---|
| 5.0 | **Prüfen:** Unterstützt `modelcontextprotocol/swift-sdk` die Spezifikation 2026-07-28? Ergebnis + Empfehlung (SDK oder eigener Adapter) vorlegen, **Entscheidung abwarten** | Notiz im Fortschritt |
| 5.1 | stdio-Transport; `server/discover` **und** altes `initialize` beantworten | Test mit aufgezeichneten Nachrichten beider Varianten |
| 5.2 | `tools/list` aus `actions.list`: Namen mit Unterstrich, `inputSchema` 2020-12, `outputSchema`, Annotationen aus Art/Wirkung, feste Reihenfolge, `ttlMs`/`cacheScope` | Schemas gegen 2020-12-Validator getestet |
| 5.3 | `tools/call` → `action.run`; Ergebnis als `structuredContent` + Kurztext; Fehler als `isError` | Tests |
| 5.4 | Profile `core`, `writer`, `presenter`, `citation`, `stories`, `chat`, `full`; Meta-Tools `llmd_search_actions`, `llmd_run_action` | `tools/list` je Profil im Test |
| 5.5 | Kanal „MCP“: Client gilt als **fremd** (A gesetzt); `sensibel`-Gruppen (B) gesperrt; Wirkung `nachAußen` nur nach Freigabe | Regeltests |
| 5.6 | Manuelle Prüfung mit Claude Code (`claude mcp add …`) und dem MCP Inspector | kurzer Prüfbericht im Fortschritt |

### Phase 6 – Resources, Prompts, Chat-Tools (2 Sitzungen)

| # | Aufgabe | Abnahme |
|---|---|---|
| 6.1 | Resources `llmd://writer/doc/{id}`, `…/presenter/deck/{id}`, `…/citation/source/{key}`, `…/stories/world/{id}` | `resources/list` und `resources/read` getestet |
| 6.2 | Prompts aus Skills (importierte Skills mit Herkunft `fremd` nur nach Bestätigung) | `prompts/list` zeigt Skills |
| 6.3 | `subscriptions/listen` auf `events.subscribe` | Änderung in der App erreicht Client |
| 6.4 | **Interner Chat:** `chat.tools.enable/disable` – Studios als Tool-Gruppen (gleiche Descriptoren wie MCP), Rule of Two über `ActionPolicy`, fremde Inhalte eingerahmt mit zufälliger Kennung, Freigaben im Chat, „Antwort rückgängig“ | Qwen 3.5 9B legt ein Dokument korrekt an (manueller Test); Angriffsszenarien aus `Tests/Security/` werden **von der Registry** blockiert |
| 6.5 | Angriffssammlung `Tests/LLMDesignerTests/Security/`: präparierte Webseiten, PDFs, Dokumente, Skills mit eingebetteten Anweisungen; Szenariotests | 0 erfolgreiche A+B+C-Abflüsse |

---

## 5. Gesamt-Abnahme (Definition of Done)

- `llmd writer doc create … && llmd writer text insert-markdown … && llmd writer export …` erzeugt ein PDF – ohne die Oberfläche anzufassen.
- Claude Code kann über MCP (Profil `core`) ein Dokument anlegen, formatieren, eine Präsentation daraus machen und eine Quelle zitieren.
- Der interne Chat kann mit zugeschalteter Gruppe `writer.core` ein Dokument bearbeiten; die Änderung ist mit einem Klick rückgängig.
- Kein Lauf kann gleichzeitig Fremdes lesen, Sensibles lesen und nach außen senden, ohne dass du es freigibst – nachgewiesen durch Regel- und Szenariotests.
- Alle Actions der Minimalsätze haben Tests; Gesamtsuite grün.
- `docs/` beschreibt Registry, Sicherheitsregeln, CLI und MCP inkl. Einrichtung.

---

## 6. Risiken und Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| Markdown-Rundlauf verliert Formatierung | Phase 2.1 zuerst; Actions erst danach |
| Gleichzeitige Bearbeitung Mensch + Agent | `version`/`ifVersion`; Editor lädt nur neu, wenn keine eigenen Änderungen offen sind (bestehendes Verhalten) |
| Main-Actor-Blockade bei langen Actions | KI-Actions asynchron mit Status-Abfrage; Socket-Verarbeitung außerhalb des Main Actors |
| Prompt Injection über gelesene Inhalte | Herkunft + Rule of Two in der Registry (Phase 1.3, 2.3); Tests in 6.5 |
| Freigabe-Müdigkeit | Freigaben bündeln, Begründung anzeigen, nur für echte Risikokombinationen fragen |
| Ad-hoc-Signatur: Erlaubnisse nach Neubau weg | Socket braucht keine Systemerlaubnis; nur Bildschirmaufnahme betroffen (bekannt) |
| MCP-Versionen im Umbruch | Adapter in `llmd` isoliert; beide Handshake-Varianten; Tests mit aufgezeichneten Nachrichten |
| Zu viele Tools für kleine Modelle | Profile, Meta-Tools, Minimalsätze |
| Schemas zu locker für 2020-12 | Validator-Test für jedes Schema in Phase 5.2 |

---

## 7. Offene Entscheidungen (vor der jeweiligen Phase klären)

| Vor Phase | Frage |
|---|---|
| 1 | CLI-Name `llmd` bestätigen; swift-argument-parser als Paket oder in `Vendor/`? |
| 2 | Block-IDs flüchtig (Vorschlag) oder persistent im Markdown? Herkunft „geprüft“ pauschal je Quelle oder nur einzeln? |
| 3 | Installationsort `~/.local/bin` (Vorschlag) oder `/usr/local/bin`? Exportordner fest oder frei mit Freigabe? |
| 5 | MCP-Swift-SDK oder eigener Adapter (nach Prüfung 5.0)? MCP-Kanal immer `fremd`? |
| 6 | Gedächtnis-Actions über MCP komplett sperren (Vorschlag) oder lesend mit Freigabe? Heuristik-Hinweise sichtbar im Chat? |

---

## 8. Fortschritt

_(wird von Claude Code nach jeder Phase gepflegt)_

| Phase | Status | Datum | Notizen |
|---|---|---|---|
| S | fertig | 04.11.2026 | S.1–S.3 in `Core/WebToolGuard.swift`. Bericht S.4 siehe unten. |
| 0 | fertig | 04.11.2026 | Basislauf vorher: 171 Tests in 25 Suiten grün, 56 s; am Ende über 400 Tests. CLI-, MCP- und Sicherheitskonzept lagen nicht vor und sind aus diesem Plan abgeleitet (siehe Kopf der Dateien). |
| 1 | fertig | 04.11.2026 | `llmd status` und `llmd call writer.doc.list --json` laufen. BSD-Sockets statt Network.framework, weil `getpeereid` den Deskriptor braucht. Eigener Parser statt swift-argument-parser (vom Nutzer gewählt). Automatischer App-Start (1.8) ist gebaut, aber nicht Ende zu Ende geprüft, weil beim Test eine andere Instanz lief. |
| 2 | fertig | 04.11.2026 | Rundlauf verlustfrei, einzige Abweichung ist die Normalform `| --- |` der Tabellen-Trennzeile. Actions wandeln nur den betroffenen Block um. Herkunft wirkt je Dokument, nicht je Block: strenger, und `geprüft` geht nur einzeln. Block-IDs sind flüchtig: Stelle plus Fingerabdruck des Inhalts. |
| 3 | fertig | 04.11.2026 | Alle Aufgaben umgesetzt. WebView-Sperre mit Zähl-Server samt Gegenprobe getestet. Aktivitätsfenster und Einstellungen offscreen gerendert und angesehen, Hinweis im Editor ebenso. |
| 4 | fertig | 04.11.2026 | Minimalsätze aller vier Studios plus etwas mehr, Beispielskripte in `docs/plan/beispiele/`. Die übrigen Katalog-Actions (Tabellen, Bilder, Kästen, KI-Assistent, Analyse, Stories-KI usw.) sind nicht Teil dieses Plans und bleiben offen. Alle fünf Beispielskripte liefen gegen den Release-Build auf einer Wegwerf-Bibliothek. |
| 5 | fertig | 04.11.2026 | Eigener Adapter (Entscheidung nach 5.0). Skriptierte stdio-Sitzung mit beiden Handshakes lief gegen eine Wegwerf-Bibliothek. **Offen:** 5.6 mit echtem Claude Code und MCP Inspector, weil `claude` hier nicht im PATH lag und der Inspector einen Download gebraucht hätte. Kein Python-`jsonschema` vorhanden: Schemas prüft ein eigener Strukturtest. |
| 6 | fertig | 04.11.2026 | Mit Qwen 3.5 9B (Kapitsa) auf einer Wegwerf-Bibliothek geprüft: Dokument angelegt, Stichpunkte, Fettdruck, 84 s, drei Schritte, „Antwort rückgängig“ nahm alle drei zurück. Plan-Ziel über MCP: Dokument, Format, Beleg, Literatur, Präsentation daraus. Angriffssammlung in `Tests/LLMDesignerTests/Security/` spielt die Angriffe mit einem Modell durch, das dem eingeschleusten Text folgt: 0 Abflüsse. **Offen:** Das Blitz-Menü im Eingabefeld und der Rückgängig-Pfeil wurden nur gebaut, nicht von Hand angeklickt. PDF-Anhänge lesen die Actions noch nicht (`citation.attachment.read` fehlt), also keine PDF-Szenarien. |

### Weitere Katalog-Actions (Reihenfolge vom Nutzer bestätigt)

| Stufe | Status | Notizen |
|---|---|---|
| W1 Tabellen | fertig | `MarkdownTable` arbeitet auf dem Markdown und schreibt über `WriterMarkdown.tableMarkdown`, also wie der Editor. Sortieren und Summenzeile teilen sich beide über `WriterTableArrange`. Tabellen in Kästen oder Spaltenabschnitten sind nicht adressierbar: der Editor lässt dort keine zu. |
| W2 Kästen, Spalten | fertig | |
| W3 Bilder, Diagramme, Mermaid, Zeichnungen | fertig | Zusätzlich `writer.figure.read`, sonst könnte ein Agent ein Diagramm nur blind ändern. `writer.image.insert` fragt über Chat und MCP nach. |
| W4 Formeln, Plots, Code | fertig | Zusätzlich `writer.formula.list`. Der Katalog nennt `python` bei `writer.plot.insert`: nicht umgesetzt, das wäre beliebiger Code von außen. Plots entstehen wie im Editor aus der Formel. |
| W5 KI-Assistent, Analyse | fertig | Der Assistent des Editors hängt am offenen Editor und seiner Auswahl; die Actions nutzen dieselben Prompts (`WriterPrompts`), aber eigene Aufträge (`WriterAIJobs`) und warten auf das Modell. `writer.ai.rewrite` setzt den Text ein, mit `apply: false` bleibt er Vorschlag. `writer.ai.check` ändert nichts und liefert Funde. Der Text wird nach dem Warten neu gelesen, damit Getipptes nicht verloren geht. |
| Anhänge, W9, C4, P7 | fertig | `citation.attachment.read` nutzt `DocumentText` (PDFKit und mehr), liefert den Text in Teilen und gilt immer als fremd. W9 braucht den offenen Editor, weil Schreibmarke und Auswahl nur dort existieren. Ansichten des Citation Studios und die Auswahl der Hintergründe laufen über Modellzustand im `AppModel`, den der offene Bildschirm übernimmt; die Tests prüfen den Zustand und `CitationStudioModel.apply`, nicht das Fenster. |
| W6, W7, W8, W10 | fertig | Damit sind alle Writer-Actions des Katalogs da. Das Mikrofon fragt außerhalb der Oberfläche immer nach; das beantwortet die offene Frage des Katalogs vorsichtig. Vorlesen, Diktat und Druck laufen in den Tests nicht echt, damit dabei nichts spricht, aufnimmt oder druckt: geprüft sind Verweigerung, Fehlerfälle und `writer.speech.stop`. |

### Entscheidungen (04.11.2026)

Vom Nutzer bestätigt: CLI-Name `llmd`; eigener kleiner Parser statt swift-argument-parser; Block-IDs flüchtig; Installation nach `~/.local/bin`; Exportordner frei mit Freigabe; MCP-Kanal immer `fremd`; Gedächtnis über MCP gesperrt; „geprüft“ nur einzeln. Die Phasen laufen ohne Rückfrage nacheinander.

### Prüfung 5.0 (04.11.2026)

Das offizielle `modelcontextprotocol/swift-sdk` nennt im README nur die Spezifikation 2025-11-25; `server/discover` und 2026-07-28 kommen dort nicht vor. Der Nutzer hat den eigenen Adapter gewählt: `Sources/llmd/MCP/`, ohne Fremdabhängigkeit, beantwortet `server/discover` und das alte `initialize`.

### Bericht S.4 (nur geprüft, nichts geändert)

- **LaTeX, Befund:** Formeln gehen im Modus `native` unverändert an die Engine (`LaTeXWriter.displayMath`). Tectonic mit `--untrusted` sperrt nur Shell-Aufrufe: `\\openin` und `\\input` lesen weiter absolute Pfade (geprüft mit einer neutralen Datei; es erscheint nur eine Warnung „accessing absolute path“). Ein präpariertes Dokument kann so lokale Dateien in das exportierte PDF holen. **Vorschlag:** Vor dem Satz gefährliche Befehle in Formeln ablehnen (`\\input`, `\\include`, `\\openin`, `\\openout`, `\\read`, `\\write`, `\\catcode`, `\\csname`) und solche Formeln als Code setzen. Eigene Aufgabe.
- **WebViews, Befund:** `SlideViews.LiveDesignView`, `FigureSheetParts` und `MermaidDiagramView` laden HTML ohne Inhaltsregeln. Externe Ressourcen in eigenen CSS-Designs (`url(http…)`) oder Diagrammen würden geladen. Wird in Aufgabe 3.7 behoben.
- **Hinweis:** `wikipedia_search` bleibt auch nach gelesenen Persona-Dateien frei. Der Plan nennt nur `open_page` und `web_search`, und das Ziel ist fest wikipedia.org.

---

## 9. Startanweisungen für Claude Code

**Phase S**
> Lies `docs/plan/Sicherheitskonzept-Prompt-Injection.md` (Abschnitte 1–2) – oder, falls noch nicht im Repo, den Text, den ich dir gebe – sowie `Core/WebTools.swift` und `Core/PersonaFileTools.swift`. Setze Aufgaben S.1–S.3 aus Phase S um, mit Tests. Für S.4 nur prüfen und berichten, nichts ändern. Zeige mir zuerst deinen Plan.

**Phase 0**
> Lies `docs/architektur.md`, `docs/code.md` und `docs/plan/Implementierungsplan.md`. Führe Phase 0 aus (Aufgaben 0.1–0.4). Halte dich an die Regeln in Abschnitt 2. Zeige mir zuerst deinen Plan, dann setze um. Am Ende: Tests ausführen, Fortschritt in Abschnitt 8 eintragen, committen.

**Phase 1**
> Lies `docs/plan/Implementierungsplan.md` (Abschnitte 2, 3, Phase 1), `docs/plan/CLI-Konzept.md` und `docs/plan/Sicherheitskonzept-Prompt-Injection.md` Abschnitt 4.2. Kläre zuerst die offene Entscheidung für Phase 1 mit mir. Setze dann Aufgaben 1.1–1.9 einzeln um, jeweils mit Tests und eigenem Commit. Die Regeltests in 1.3 sind tabellengetrieben und decken alle Kombinationen ab. Abschluss: `llmd status` und `llmd call writer.doc.list --json` funktionieren; Fortschritt eintragen.

**Phase 2**
> Lies den Plan (Abschnitt 3 „Schlüsseltechnik“ und „Adressierung“, Phase 2), `docs/plan/WriterStudio-Actions.md` und das Sicherheitskonzept Abschnitt 4.1. Beginne zwingend mit 2.1 (Rundlauf-Tests) und berichte Abweichungen, bevor du Actions baust. Danach 2.2–2.11 in dieser Reihenfolge. Jede Action ist eine dünne Hülle um bestehende Writer-Funktionen; arbeite auf Markdown, nicht auf `NSTextView`.

**Phase 3**
> Lies Plan Phase 3 und `docs/plan/CLI-Konzept.md` Abschnitte 4–7. Setze 3.1–3.7 um. Für 3.3 und 3.4 orientiere dich an der bestehenden `SettingsView` und den Panels in `UI/`.

**Phase 4 (je Studio)**
> Lies Plan Phase 4, den Katalog `docs/plan/<Studio>-Actions.md` und das Sicherheitskonzept Abschnitt 4.2. Setze den dort empfohlenen Minimalsatz um, jede Action mit korrekten Sicherheitsmerkmalen, Tests und einem Beispielskript in `docs/plan/beispiele/`.

**Phase 5**
> Lies Plan Phase 5, `docs/plan/MCP-Schicht.md` und das Sicherheitskonzept Abschnitt 5. Beginne mit 5.0: Prüfe den aktuellen Stand des offiziellen MCP-Swift-SDK bezüglich der Spezifikation 2026-07-28 und lege mir eine Empfehlung vor. Warte auf meine Entscheidung, dann 5.1–5.6.

**Phase 6**
> Lies Plan Phase 6, `docs/plan/MCP-Schicht.md` Abschnitt 2, `docs/plan/Chat-Actions.md` Abschnitt 9 und das Sicherheitskonzept Abschnitte 4.4 und 6. Setze 6.1–6.5 um. Für 6.4 nutze das bestehende Tool-Muster aus `WebTools.swift` und `PersonaFileTools.swift`.
