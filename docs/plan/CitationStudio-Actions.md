# CitationStudio – Action-Katalog

_Teil des Meilensteins „Action-Schicht“ · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 02.11.2026 · abgeleitet aus dem Code (Commit `c7e95c3`)_

Legende Status: ✅ existiert in der UI/im Modell · 🟡 teilweise · 🆕 neu
Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv/nach außen (Bestätigung)

---

## 0. Besonderheiten

**Datenmodell:**
- **Quelle** (`CitationSource`): Typ (book, chapter, article, paper, thesis, report, web, other), Zitierschlüssel, Titel/Untertitel, Autor:innen, Herausgeber:innen, Jahr/Datum, Container (Zeitschrift, Sammelband …), Verlag, Ort, Auflage, Band, Heft, Seiten, DOI, ISBN, URL, arXiv, Abrufdatum, Sprache, Abstract, Notizen, Schlagworte, Anhänge, Ordner
- **Wissensbaustein** (`CitationQuote`): gehört zu einer Quelle; wörtlicher Text, Paraphrase/eigener Gedanke, Seite/Fundstelle, Schlagworte, Verknüpfungen zu anderen Bausteinen, eigener Ordner
- **Ablage:** zwei Regale (Quellen / Wissensbausteine) → Gruppen → Ordner

**Adressierung:** Quellen über `--source <citekey>` (lesbar, stabil, für KIs ideal) oder `--source-id <uuid>`; Bausteine über `--quote <id>`.

**Suchsyntax existiert bereits** und eignet sich direkt für Agenten:
`müller #lernen @kahneman 2010-2020 typ:buch` → Wörter, `#Schlagwort`, `@Autor`, Jahr oder Jahresbereich, `typ:`. Umlaute werden in beide Richtungen gefunden (müller ↔ Mueller).

**KI fehlt hier noch:** Im Citation Studio gibt es bisher keine KI-Funktionen. Abschnitt 8 schlägt sie vor (🆕), passend zum Grundprinzip „KI überall“.

---

## 1. Lesen & Suchen

| Action | Parameter | Liefert | Status |
|---|---|---|---|
| `citation.search` | `query` (Suchsyntax s. o.), `shelf: sources\|quotes\|both`, `limit?` | Treffer mit Citekey, Kurzangabe, Ausschnitt | ✅ |
| `citation.source.list` | `folder?`, `tag?`, `type?` | Quellen kurz (Citekey, Autor Jahr, Titel) | ✅ |
| `citation.source.read` | `source` | alle Felder + Bausteine + Anhänge | 🆕 (Daten ✅) |
| `citation.quote.list` | `source?`, `folder?`, `tag?` | Bausteine | ✅ |
| `citation.quote.read` | `quote` | Text, Paraphrase, Seite, Verknüpfungen, Quelle | 🆕 (Daten ✅) |
| `citation.quote.linked` | `quote` | verknüpfte Bausteine | ✅ |
| `citation.tags.list` | `shelf?` | Schlagworte mit Häufigkeit | 🟡 |
| `citation.collections.list` | `shelf` | Gruppen und Ordner als Baum | ✅ |
| `citation.duplicates.check` | Quellenfelder \| `identifier` | mögliche Dubletten | ✅ |
| `citation.usages` | `source` | Dokumente/Präsentationen, die die Quelle zitieren | 🆕 |

## 2. Quellen

| Action | Parameter | Art | Status |
|---|---|---|---|
| `citation.source.import` | `identifier` (DOI, ISBN, arXiv-ID oder URL – automatisch erkannt), `folder?` | S | ✅ |
| `citation.source.lookup` | `identifier` → Metadaten **ohne** Anlegen (zur Prüfung) | L | ✅ |
| `citation.source.create` | `type`, Felder (Titel, Autor:innen, Jahr …), `folder?` | S | ✅ |
| `citation.source.update` | `source`, Felder | S | ✅ |
| `citation.source.setCitekey` | `source`, `key` (eindeutig; Vorschlag via `citation.source.suggestCitekey`) | S | ✅ |
| `citation.source.suggestCitekey` | `source` | L | ✅ |
| `citation.source.tag` | `source`, `add[]`, `remove[]` | S | ✅ |
| `citation.source.move` | `source`, `folder` \| `unsorted` | S | ✅ |
| `citation.source.merge` | `keep`, `remove` (Dublette zusammenführen, Bausteine übernehmen) | S | 🆕 |
| `citation.source.delete` | `source` (löscht auch Bausteine und Verknüpfungen) | D | ✅ |

## 3. Anhänge

| Action | Parameter | Art | Status |
|---|---|---|---|
| `citation.attachment.add` | `source`, `file` | S | ✅ |
| `citation.attachment.list` | `source` | L | ✅ |
| `citation.attachment.open` | `source`, `file` | L | ✅ |
| `citation.attachment.read` | `source`, `file` → Text (z. B. aus PDF) | L | 🆕 |
| `citation.attachment.remove` | `source`, `file` | S | ✅ |

_`attachment.read` ist der Schlüssel für KI-gestütztes Exzerpieren (Abschnitt 8)._

## 4. Wissensbausteine (Zitate & Paraphrasen)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `citation.quote.add` | `source`, `exactText?`, `paraphrase?`, `page?`, `tags?`, `folder?` | S | ✅ |
| `citation.quote.update` | `quote`, Felder | S | ✅ |
| `citation.quote.tag` | `quote`, `add[]`, `remove[]` | S | ✅ |
| `citation.quote.link` | `quote`, `with` | S | ✅ |
| `citation.quote.unlink` | `quote`, `from` | S | ✅ |
| `citation.quote.move` | `quote`, `folder` \| `unsorted` | S | ✅ |
| `citation.quote.delete` | `quote` | D | ✅ |

## 5. Gruppen & Ordner

| Action | Parameter | Art | Status |
|---|---|---|---|
| `citation.group.add` | `shelf`, `name` | S | ✅ |
| `citation.group.rename` | `group`, `name` | S | ✅ |
| `citation.group.delete` | `group` | D | ✅ |
| `citation.folder.add` | `group`, `name` | S | ✅ |
| `citation.folder.rename` | `folder`, `name` | S | ✅ |
| `citation.folder.move` | `folder`, `group` | S | ✅ |
| `citation.folder.delete` | `folder` | D | ✅ |

## 6. Zitieren & Literaturverzeichnis (APA 7, deutsch)

| Action | Parameter | Liefert | Status |
|---|---|---|---|
| `citation.format.inText` | `items: [{key, page?}]` | „(Müller, 2020, S. 12)“ | ✅ |
| `citation.format.reference` | `source` | Literaturangabe | ✅ |
| `citation.format.bibliography` | `keys[]` \| `doc` | sortiertes Literaturverzeichnis | ✅ |
| `citation.export.bibtex` | `keys[]` \| `folder` \| `all`, `path?` | BibTeX-Datei | 🆕 |
| `citation.export.csl` | dto. (CSL-JSON, z. B. für Zotero) | Datei | 🆕 |
| `citation.import.bibtex` | `file` | neue Quellen (mit Dublettenprüfung) | 🆕 |

_Einfügen in Dokumente läuft über Writer: `writer.citation.insert`, `writer.quote.insert`, `writer.bibliography.insert` – mit Folien-Adresse auch im Presenter._

## 7. Studio & Ansicht

| Action | Parameter | Status |
|---|---|---|
| `citation.studio.open` | `source?` (direkt eine Quelle zeigen) | ✅ |
| `citation.studio.close` | – | ✅ |
| `citation.view.shelf` | `sources\|quotes` | ✅ |
| `citation.view.filterTags` | `tags[]` | ✅ |
| `citation.view.select` | `source` \| `quote` | ✅ |

## 8. KI im Citation Studio (Vorschläge, alle 🆕)

| Action | Was sie tut |
|---|---|
| `citation.ai.excerpt` | aus Anhang/Text einer Quelle Kernaussagen als Bausteine anlegen (wörtlich + Paraphrase + Seite) |
| `citation.ai.paraphrase` | Paraphrase zu einem wörtlichen Zitat vorschlagen |
| `citation.ai.tag` | Schlagworte für Quelle/Baustein vorschlagen, an vorhandenen Schlagworten ausgerichtet |
| `citation.ai.linkSuggest` | thematisch verwandte Bausteine finden und Verknüpfungen vorschlagen |
| `citation.ai.summarize` | Abstract/Zusammenfassung einer Quelle erzeugen |
| `citation.ai.findSupport` | zu einer Behauptung (z. B. aus Writer) passende Bausteine heraussuchen |
| `citation.ai.completeMetadata` | fehlende Felder prüfen und ergänzen (über Lookup, nicht erfinden) |

_Wichtig: KI darf Fundstellen und bibliographische Angaben nie erfinden. Wörtliche Zitate nur aus vorliegendem Text, Metadaten nur aus Lookup._

---

## Empfehlungen

**Minimalsatz für den Chat (~8 Actions):**
`citation.search`, `citation.source.read`, `citation.source.import`, `citation.quote.add`, `citation.quote.read`, `citation.format.inText`, plus aus Writer `writer.citation.insert` und `writer.bibliography.insert`.
Damit kann eine KI recherchieren, belegen und korrekt zitieren.

**Zusammenspiel mit Rechercherista (später):** Recherche findet Quellen → `citation.source.import` → `citation.ai.excerpt` → Writer zitiert. Das wäre ein typischer AgentSteps-Workflow.

**Offene Fragen**
- Weitere Zitierstile neben APA 7 (z. B. DIN ISO 690, Chicago, Harvard) – über CSL-Stile?
- BibTeX-Export/Import gewünscht (für LaTeX-Nutzung außerhalb und Austausch mit Zotero/Citavi)?
- PDF-Text aus Anhängen extrahieren: lokal mit PDFKit (macOS) – reicht das?
