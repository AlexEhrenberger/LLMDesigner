# WriterStudio – Action-Katalog

_Meilenstein „Action-Schicht“: Jede Bedienhandlung wird eine elementare, adressierbare Action – aufrufbar aus Oberfläche, Terminal (CLI), MCP und AgentSteps._
_Stand: 02.11.2026 · abgeleitet aus dem Code (Commit `c7e95c3`)_

Legende Status: ✅ Funktion existiert bereits in der UI (muss nur als Action freigelegt werden) · 🆕 neu, für Agenten nötig
Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv/nach außen (Bestätigung)

---

## 0. Grundidee (Zielbild)

Eine **Action-Registry** ist die einzige Stelle, an der Writer etwas tut. Alle anderen Wege rufen nur Actions auf:

```
Knopf / Menü / Tastenkürzel ─┐
Terminal:  llmd writer …     ├──►  Action-Registry  ──►  AppModel / Dokument  ──►  offener Editor lädt neu
MCP-Tool (Claude, Qwen)      │       (ID, Parameter,
AgentSteps-Workflow          │        Prüfung, Ergebnis,
Tests / Makros               ┘        Undo, Protokoll)
```

Jede Action hat:
- **ID** mit Namensraum, z. B. `writer.format.bold`
- **Parameter** als JSON-Schema (dient zugleich als MCP-Tool-Beschreibung)
- **Ziel**: Dokument-ID + Adresse (siehe 0.1)
- **Ergebnis** als JSON (neue Auswahl, betroffene Block-IDs, Fehler)
- **Art** L/S/D, Undo-fähig, wird protokolliert

Selbstbeschreibung: `llmd actions list --module writer --json` liefert alle Actions mit Schema – damit findet eine KI selbst heraus, was sie tun kann.

### 0.1 Adressierung – der wichtigste Designpunkt
Ein Mensch arbeitet mit Schreibmarke und Markierung. Eine KI sieht den Bildschirm nicht und braucht stabile Adressen. Deshalb **zwei Ebenen**:

| Ebene | Wie | Beispiel |
|---|---|---|
| **Cursor-Modell** (wie ein Mensch) | erst Auswahl setzen, dann Action | `writer.select --match "Wasserkreislauf"` → `writer.format.bold` |
| **Direktadresse** (robust für Agenten) | Ziel direkt in der Action | `writer.format.bold --block b12 --match "Wasserkreislauf"` |

Adressformen: `--range 120:15` (Zeichen), `--block <blockID>`, `--heading "Kapitel 2/Einleitung"`, `--match "Text" [--occurrence 2]`, `--all`. **Block-IDs** (stabil über Änderungen hinweg) sind dafür 🆕 nötig.

### 0.2 Elementar und gebündelt
Elementare Actions erlauben feine Steuerung. Für Sprachmodelle ist aber oft `writer.text.insertMarkdown` effizienter: ein Aufruf mit Überschrift, Liste und Fettdruck statt 20 Einzelschritte. Beides anbieten.

---

## 1. Dokumente verwalten

| Action | Parameter | Art | Status |
|---|---|---|---|
| `writer.doc.list` | `folder?`, `query?` | L | ✅ |
| `writer.doc.create` | `title?`, `folder?`, `format?`, `markdown?` | S | ✅ |
| `writer.doc.open` | `doc` | L | ✅ |
| `writer.doc.close` | `doc` | S | ✅ |
| `writer.doc.rename` | `doc`, `title` | S | ✅ |
| `writer.doc.autoTitle` | `doc` | S | ✅ |
| `writer.doc.move` | `doc`, `folder` \| `newFolder` | S | ✅ |
| `writer.doc.duplicate` | `doc`, `title?` | S | 🆕 |
| `writer.doc.save` | `doc?` | S | ✅ |
| `writer.doc.delete` | `doc` | D | ✅ |

## 2. Lesen & Zustand abfragen
_Ohne diese Gruppe kann eine KI nicht sinnvoll arbeiten – sie ist ihr „Bildschirm“._

| Action | Parameter | Liefert | Status |
|---|---|---|---|
| `writer.doc.read` | `doc`, `format: markdown\|plain`, `range?`/`block?`/`heading?` | Inhalt | 🆕 (Daten ✅) |
| `writer.blocks.list` | `doc` | Blöcke mit ID, Typ, Kurztext | 🆕 |
| `writer.outline.get` | `doc` | Überschriftenbaum | ✅ |
| `writer.selection.get` | – | Auswahl, Schreibmarke, aktive Formate | 🆕 |
| `writer.state.get` | – | offenes Dokument, Tab, laufende KI-Aufgaben | 🆕 |
| `writer.find` | `doc`, `query`, `caseSensitive?` | Trefferliste mit Adressen | ✅ |
| `writer.doc.stats` | `doc` | Wörter, Zeichen, Seiten | 🆕 |
| `writer.comments.list` | `doc` | Kommentare mit Thread | ✅ |
| `writer.bookmarks.list` | `doc` | Lesezeichen | ✅ |
| `writer.citations.list` | `doc` | verwendete Zitierschlüssel | ✅ |

## 3. Navigation & Auswahl

| Action | Parameter | Art | Status |
|---|---|---|---|
| `writer.caret.set` | Adresse, `edge: start\|end` | L | ✅ |
| `writer.select` | Adresse | L | ✅ |
| `writer.select.all` | – | L | ✅ |
| `writer.find.next` / `.previous` | – | L | ✅ |
| `writer.jump.heading` | `heading` | L | ✅ |
| `writer.jump.bookmark` | `bookmark` | L | ✅ |
| `writer.jump.comment` | `comment` | L | ✅ |
| `writer.view.reveal` | Adresse (in Sicht scrollen) | L | ✅ |

## 4. Text

| Action | Parameter | Art | Status |
|---|---|---|---|
| `writer.text.insert` | `text`, Adresse? (sonst Schreibmarke) | S | ✅ |
| `writer.text.insertMarkdown` | `markdown`, Adresse?, `position: before\|after\|replace` | S | ✅ |
| `writer.text.replace` | Adresse, `text`/`markdown` | S | ✅ |
| `writer.text.replaceAll` | `find`, `replace` | S | 🆕 |
| `writer.text.delete` | Adresse | S | ✅ |
| `writer.paragraph.new` | Adresse? | S | ✅ |
| `writer.block.move` | `block`, `before\|after: block` | S | ✅ (Power-Panel) |
| `writer.edit.undo` / `.redo` | – | S | ✅ |

## 5. Zeichenformat

| Action | Parameter | Status |
|---|---|---|
| `writer.format.bold` | Adresse?, `state: toggle\|on\|off` | ✅ |
| `writer.format.italic` | dto. | ✅ |
| `writer.format.underline` | dto. | ✅ |
| `writer.format.strikethrough` | dto. | ✅ |
| `writer.format.code` | dto. | ✅ |
| `writer.format.superscript` | dto. | ✅ |
| `writer.format.subscript` | dto. | ✅ |
| `writer.format.font` | `font` (serif, sans, rounded, mono, georgia, palatino, … 19 Schriften) | ✅ |
| `writer.format.fontSize` | `size` \| `step: +1\|-1` | ✅ |
| `writer.format.color` | `color` (Name/Hex) \| `none` | ✅ |
| `writer.link.set` / `.remove` | `url` | ✅ |
| `writer.format.clear` | Adresse? | ✅ |

_`state: on|off` ist 🆕 und für Agenten wichtig – ein reines Umschalten ist nicht vorhersagbar, wenn die KI den aktuellen Zustand nicht kennt._

## 6. Absatz & Blocktyp

| Action | Parameter | Status |
|---|---|---|
| `writer.block.set` | `type`: paragraph, heading1, heading2, heading3, chapter, bullet, numbered, quote, code | ✅ |
| `writer.list.level` | `step: +1\|-1` | ✅ |
| `writer.paragraph.align` | `left\|center\|right\|justify` | ✅ |
| `writer.paragraph.indent` | `step` \| `left`, `right`, `firstLine` | ✅ |
| `writer.paragraph.lineSpacing` | `value` | ✅ |
| `writer.paragraph.clearFormat` | Adresse? | ✅ |
| `writer.insert.rule` | Adresse? | ✅ |
| `writer.insert.pageBreak` | Adresse? | ✅ |

_Praktische Kurzformen für Agenten: `writer.heading.insert --level 1 --text "…"` (🆕, gebündelt)._

## 7. Struktur: Inhaltsverzeichnis, Lesezeichen, Kommentare

| Action | Parameter | Art | Status |
|---|---|---|---|
| `writer.toc.insert` | `mode: formal\|dynamic`, Adresse? | S | ✅ |
| `writer.toc.setMode` | `mode` | S | ✅ |
| `writer.toc.expand` | – (KI erweitert) | S | ✅ |
| `writer.toc.remove` | – | S | ✅ |
| `writer.bookmark.add` | Adresse, `name` | S | ✅ |
| `writer.bookmark.rename` / `.remove` | `bookmark`, `name?` | S | ✅ |
| `writer.comment.add` | Adresse, `text` | S | ✅ |
| `writer.comment.reply` | `comment`, `text` | S | ✅ |
| `writer.comment.edit` | `comment`, `text` | S | ✅ |
| `writer.comment.resolve` | `comment` | S | ✅ |
| `writer.comment.delete` | `comment` | S | ✅ |

## 8. Tabellen

| Action | Parameter | Status |
|---|---|---|
| `writer.table.insert` | `rows`, `columns`, `header?`, `data?` (2D-Array) | ✅ (`data` 🆕) |
| `writer.table.read` | `table` | 🆕 |
| `writer.table.cell.set` | `table`, `row`, `column`, `text` | 🆕 |
| `writer.table.row.insert` | `table`, `at`, `above\|below` | ✅ |
| `writer.table.column.insert` | `table`, `at`, `left\|right` | ✅ |
| `writer.table.row.delete` / `.column.delete` | `table`, `at` | ✅ |
| `writer.table.cells.merge` | Zellbereich \| `right\|down` | ✅ |
| `writer.table.cell.split` | Zelle | ✅ |
| `writer.table.align` | Zellbereich, Ausrichtung | ✅ |
| `writer.table.columns.equalize` / `.setWidths` | `widths?` | ✅ |
| `writer.table.style` | `lines: standard\|grid\|horizontal\|frame\|none`, `lineWidth?`, `fill?` | ✅ |
| `writer.table.formula.set` | Zelle, `formula` (z. B. `=SUMME(B2:B5)`) | ✅ |
| `writer.table.sumRow` | `table` | ✅ |
| `writer.table.sort` | `table`, `column`, `ascending` | ✅ |
| `writer.table.recalculate` | `table?` | ✅ |
| `writer.table.toChart` | `table`, Diagrammart? | ✅ |
| `writer.table.delete` | `table` | ✅ |

## 9. Kästen & Spalten

| Action | Parameter | Status |
|---|---|---|
| `writer.box.insert` | `kind: definition\|merksatz\|beispiel\|hinweis\|achtung\|eigener`, `title?`, `markdown?` | ✅ |
| `writer.box.style` | `position: full\|left\|center\|right`, `frame: bar\|outline\|filled` | ✅ |
| `writer.box.remove` | `box`, `keepText?` | ✅ |
| `writer.columns.set` | `count`, Adresse | ✅ |
| `writer.columns.break` | Adresse? | ✅ |
| `writer.columns.remove` | Adresse | ✅ |

## 10. Bilder & Abbildungen

| Action | Parameter | Art | Status |
|---|---|---|---|
| `writer.image.insert` | `file`, Adresse?, `width?`, `caption?` | S | ✅ |
| `writer.image.setWidth` | `image`, `width` | S | ✅ |
| `writer.image.caption` | `image`, `text` | S | ✅ |
| `writer.image.delete` | `image` | S | ✅ |
| `writer.image.generate` | `prompt`, Adresse? (Draw Things) | S | ✅ |
| `writer.image.regenerate` / `.cancel` | `image`, `prompt?` | S | ✅ |
| `writer.image.toSlide` | `image`, `deck`, `slide` | S | ✅ |
| `writer.chart.insert` | `kind`, `data`, `legend?`, `aspect?`, `palette?` | S | ✅ |
| `writer.chart.edit` | `chart`, Felder | S | ✅ |
| `writer.mermaid.insert` | `type` (flowchart, sequence, mindmap, timeline, classDiagram, state, entity, gantt, pie, journey, quadrant), `code` \| `instruction` (KI) | S | ✅ |
| `writer.mermaid.edit` | `figure`, `code` | S | ✅ |
| `writer.drawing.insert` / `.edit` | `elements` (Formen, Linien, Text) | S | 🟡 Editor ✅, Datenformat für Agenten 🆕 |

## 11. Formeln & Plots

| Action | Parameter | Status |
|---|---|---|
| `writer.formula.insert` | `latex`, `display: inline\|block` | ✅ |
| `writer.formula.edit` | `formula`, `latex` | ✅ |
| `writer.plot.insert` | `expression` \| `python`, Bereich, Beschriftung | ✅ |
| `writer.plot.edit` | `plot`, Felder | ✅ |

## 12. Code

| Action | Parameter | Status |
|---|---|---|
| `writer.code.insert` | `language`, `code` | ✅ |
| `writer.code.setLanguage` | `block`, `language` | ✅ |
| `writer.code.format` | `block` | ✅ |
| `writer.code.flowchart` | `block` (Python/SQL → Flussdiagramm) | ✅ |

## 13. Zitate (Verbindung zu CitationStudio)

| Action | Parameter | Status |
|---|---|---|
| `writer.citation.insert` | `key`, `page?`, Adresse? | ✅ |
| `writer.citation.edit` | `citation`, `page?` | ✅ |
| `writer.quote.insert` | `quoteID` (wörtliches Zitat mit Pille) | ✅ |
| `writer.bibliography.insert` | Adresse? (APA 7 de) | ✅ |

## 14. Seite & Dokument-Layout

| Action | Parameter | Status |
|---|---|---|
| `writer.page.format` | `standard\|taschenbuch\|normseite\|eigen`, Maße? | ✅ |
| `writer.page.setup` | Ränder, Ausrichtung | ✅ |
| `writer.page.runningHeads` | Kopf-/Fußzeile | ✅ |
| `writer.doc.font` | `font` (Grundschrift) | ✅ |
| `writer.page.template.save` / `.delete` | `name` | ✅ |

## 15. KI-Assistent im Dokument
_Damit kann ein steuernder Agent (z. B. Claude) Arbeit an das lokale Modell delegieren._

| Action | Parameter | Status |
|---|---|---|
| `writer.ai.write` | `instruction`, Adresse/`placement` | ✅ |
| `writer.ai.rewrite` | Adresse, `preset: rephrase\|shorter\|longer\|casual\|formal\|simpler` \| `instruction` | ✅ |
| `writer.ai.expand` | Adresse | ✅ |
| `writer.ai.answer` | `question`, Adresse? | ✅ |
| `writer.ai.check` | `kind: language\|plausibility`, Adresse? | ✅ |
| `writer.ai.comment` | Adresse | ✅ |
| `writer.ai.cancel` | – | ✅ |
| `writer.ai.status` | – (läuft / fertig / Ergebnis) | 🆕 |

## 16. Inhaltsanalyse

| Action | Parameter | Status |
|---|---|---|
| `writer.analysis.run` | `modules: overview\|argumentation\|narrative\|structure\|code` | ✅ |
| `writer.analysis.get` | `doc` (Ergebnis als JSON) | ✅ |
| `writer.analysis.cancel` / `.delete` | – | ✅ |

## 17. Audio

| Action | Parameter | Status |
|---|---|---|
| `writer.speech.read` | Adresse?, `voice?` | ✅ |
| `writer.speech.stop` | – | ✅ |
| `writer.dictation.start` / `.stop` | – (nur sinnvoll mit Mensch am Mikrofon) | ✅ |

## 18. Export & Druck

| Action | Parameter | Art | Status |
|---|---|---|---|
| `writer.export` | `format: pdf\|latex\|markdown\|plainMarkdown`, `path?` | D | ✅ (`path` 🆕) |
| `writer.print` | – | D | ✅ |

## 19. Ansicht (optional – damit die KI dem Menschen etwas zeigen kann)

| Action | Parameter | Status |
|---|---|---|
| `writer.view.tab` | Writer-Tab | ✅ |
| `writer.view.panel` | `outline\|bookmarks\|sources\|comments\|analysis\|power` | ✅ |
| `writer.view.highlight` | Adresse (kurz aufleuchten) | ✅ |

---

## Empfehlungen zur Umsetzung

**Reihenfolge**
1. **Fundament:** Registry, Block-IDs, Adressierung, JSON-Ergebnis, Undo-Gruppierung, Protokoll.
2. **Minimalsatz (~25 Actions):** Abschnitte 1, 2, 4, 5, 6 – damit kann eine KI bereits vollständige Dokumente lesen, schreiben und formatieren.
3. Tabellen, Zitate, Kästen, Formeln, Bilder.
4. KI-Assistent, Analyse, Layout, Export, Ansicht.

**Technik**
- Actions arbeiten **auf dem Dokumentmodell (Markdown)**, nicht auf der `NSTextView`. Die Architektur unterstützt das schon: Ändert sich der Text im `AppModel`, lädt der offene Editor neu und behält Schreibmarke und Scroll-Position. So funktionieren Actions auch, wenn das Dokument nicht geöffnet ist.
- UI-Knöpfe Schritt für Schritt auf dieselben Actions umstellen – dann ist garantiert, dass Mensch und Agent dasselbe können.
- Transport fürs Terminal: lokaler Socket oder XPC zur laufenden App; `llmd` ist ein dünner Client. Der MCP-Server nutzt dieselbe Registry.
- Destruktive Actions (Art **D**) brauchen eine Freigabe-Einstellung (z. B. „Agent darf löschen/exportieren: fragen | erlaubt“).
- Jede Action bekommt einen Test, der sie ohne Oberfläche ausführt – das verbessert nebenbei die Testabdeckung.

**Offene Fragen**
- Block-IDs: im Markdown speichern (z. B. als Kommentar/Attribut) oder nur zur Laufzeit vergeben?
- Soll ein Agent im *sichtbaren* Editor arbeiten (Mensch schaut zu, mit KI-Cursor) oder im Hintergrund?
- Gleichzeitiges Bearbeiten Mensch + Agent im selben Dokument: sperren oder zusammenführen?
- CLI-Name: `llmd`?
