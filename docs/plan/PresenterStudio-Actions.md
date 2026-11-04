# PresenterStudio – Action-Katalog

_Teil des Meilensteins „Action-Schicht“ · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 02.11.2026 · abgeleitet aus dem Code (Commit `c7e95c3`)_

Legende Status: ✅ existiert in der UI · 🟡 teilweise · 🆕 neu, für Agenten nötig
Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv/nach außen (Bestätigung)

---

## 0. Besonderheiten gegenüber Writer

**Writer-Actions werden wiederverwendet.** Folientext wird mit demselben Editor bearbeitet. Deshalb gibt es keine eigenen Presenter-Actions für Fett, Überschrift, Tabelle, Formel, Zitat usw. – alle `writer.*`-Actions funktionieren auch auf Folien, wenn die Adresse auf eine Folie zeigt:

```
writer.format.bold    --deck d1 --slide s4 --match "Wasserkreislauf"
writer.table.insert   --deck d1 --slide s4 --rows 3 --columns 2
writer.text.insertMarkdown --deck d1 --slide s4 --field f2 --markdown "**Merke:** …"
```

**Erweiterte Adressierung:**

| Adresse | Bedeutung |
|---|---|
| `--deck <id>` | Präsentation (technisch ein Dokument eigener Art) |
| `--slide <id>` \| `--slide-index <n>` | Folie; Index ist bequem, ID ist stabil |
| `--field <id>` | freies Element auf der Folie (Bild, Textfeld, Kasten, Tabelle, Code) |
| `--notes` | Moderatorenkarte der Folie |

**Positionen und Größen** von Elementen sind Anteile der Folie (0–1) bei einer Leinwand von 720 × 405 pt. Das ist für Agenten günstig: `x: 0.55, y: 0.2, width: 0.4` ist unabhängig von Bildschirmgröße.

**Sehen können:** Eine KI kann Layout nicht aus Text erschließen. `presenter.slide.render` (Folie als Bild) ist deshalb wichtig, damit Modelle mit Bildverständnis (Gemma 4, Qwen 3.5, Claude) ihr Ergebnis prüfen können.

---

## 1. Präsentationen verwalten

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.deck.list` | `folder?`, `query?` | L | ✅ |
| `presenter.deck.create` | `title?`, `folder?` | S | ✅ |
| `presenter.deck.open` | `deck` | L | ✅ |
| `presenter.deck.close` | `deck` | S | ✅ |
| `presenter.deck.rename` | `deck`, `title` | S | ✅ |
| `presenter.deck.move` | `deck`, `folder` | S | ✅ |
| `presenter.deck.duplicate` | `deck`, `title?` | S | 🆕 |
| `presenter.deck.delete` | `deck` | D | ✅ |

_Verwaltung läuft im Code über dieselben Funktionen wie Writer-Dokumente; die Actions können intern auf `writer.doc.*` zeigen._

## 2. Lesen & Zustand abfragen

| Action | Parameter | Liefert | Status |
|---|---|---|---|
| `presenter.deck.read` | `deck`, `withNotes?` | alle Folien: ID, Index, Rolle, Titel, Text, Elemente, Hintergrund | 🆕 (Daten ✅) |
| `presenter.slides.list` | `deck` | Kurzliste: ID, Index, Rolle, Titel | 🆕 |
| `presenter.slide.read` | `slide` | Text (Markdown), Moderatorenkarte, Elemente mit Position, Textbereich, Hintergrund | 🆕 |
| `presenter.slide.render` | `slide`, `size?` | Folie als PNG (für Bildprüfung durch die KI) | 🟡 Renderer ✅ |
| `presenter.backgrounds.get` | `deck` | Hintergründe für Präsentation / Rollen / einzelne Folien | ✅ |
| `presenter.designs.list` | – | 17 eingebaute + eigene CSS-Designs | ✅ |
| `presenter.state.get` | – | offene Präsentation, aktuelle Folie, Auswahl, laufende KI-Aufgabe, Vortragsstatus | 🆕 |
| `presenter.find` | `deck`, `query` | Treffer mit Folie und Adresse | 🟡 |

## 3. Folien

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.slide.add` | `deck`, `after?`, `role: titel\|kapitel\|folie`, `markdown?` | S | ✅ |
| `presenter.slide.addFromText` | `deck`, `after?`, `text` (erste Zeile = Titel, Rest = Stichpunkte) | S | ✅ (Power-Panel) |
| `presenter.slide.addAgenda` | `deck`, `after?` (Agenda aus Kapitelfolien) | S | ✅ |
| `presenter.slide.duplicate` | `slide` | S | ✅ |
| `presenter.slide.move` | `slide`, `to` (Index) \| `after` | S | ✅ |
| `presenter.slide.delete` | `slide` | S | ✅ |
| `presenter.slide.restore` | – (zuletzt gelöschte) | S | ✅ |
| `presenter.slide.select` | `slide` | L | ✅ |
| `presenter.slide.setRole` | `slide`, `role` | S | ✅ |
| `presenter.slide.setText` | `slide`, `markdown` (ganzer Folientext) | S | ✅ |
| `presenter.slide.setTitle` | `slide`, `title` | S | 🆕 (Kurzform) |

## 4. Textbereich der Folie

| Action | Parameter | Status |
|---|---|---|
| `presenter.textArea.set` | `slide`, `x`, `y`, `width`, `height` | ✅ |
| `presenter.textArea.reset` | `slide` | ✅ |

## 5. Freie Elemente (Bilder, Textfelder, Kästen, Tabellen, Code)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.field.addText` | `slide`, `markdown`, `x`, `y`, `width`, `height?` | S | ✅ |
| `presenter.field.addImage` | `slide`, `file`, Position?, `caption?` | S | ✅ |
| `presenter.field.generateImage` | `slide`, `prompt`, Position? (Draw Things) | S | ✅ |
| `presenter.field.regenerateImage` | `field`, `prompt?` | S | ✅ |
| `presenter.field.addBox` | `slide`, `kind` (definition, merksatz, beispiel, hinweis, achtung, eigener), `markdown`, Position | S | ✅ |
| `presenter.field.addTable` / `.addCode` / `.addFigure` | `slide`, Inhalt, Position | S | ✅ |
| `presenter.field.detachSelection` | `slide`, Adresse (markierten Text als Textfeld herauslösen) | S | ✅ |
| `presenter.field.move` | `field`, `x`, `y` \| `nudge: dx, dy` | S | ✅ |
| `presenter.field.resize` | `field`, `width`, `height` \| `fitText` | S | ✅ |
| `presenter.field.restoreAspect` | `field` | S | ✅ |
| `presenter.field.align` | `field`, `center\|left\|right\|top\|bottom` (wie Einrasten) | S | 🆕 |
| `presenter.field.placement` | `field`, `umfliessen\|vorne\|hinten` | S | ✅ |
| `presenter.field.order` | `field`, `front\|back\|forward\|backward` | S | ✅ |
| `presenter.field.box` | `field`, `kind?`, `frame?` | S | ✅ |
| `presenter.field.caption` | `field`, `text` | S | ✅ |
| `presenter.field.edit` | `field` (Editor in das Feld setzen; danach `writer.*`-Actions) | L | ✅ |
| `presenter.field.endEdit` | – | L | ✅ |
| `presenter.field.delete` | `field` | S | ✅ |
| `presenter.field.toSlide` | aus Writer: Bild an Folie übergeben (`writer.image.toSlide`) | S | ✅ |

## 6. Hintergründe & Design

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.background.set` | Ziel `deck` \| `role` \| `slide`; `kind: design\|color\|gradient\|image` + Wert | S | ✅ |
| `presenter.background.clear` | `slide` (fällt auf Rollen-/Präsentationshintergrund zurück) | S | ✅ |
| `presenter.background.image` | Ziel, `file` | S | ✅ |
| `presenter.background.generate` | `description`, `style`, `tone: light\|dark`, `roles[]` \| `slide`, `resolution` (Draw Things) | S | ✅ |
| `presenter.design.apply` | `deck`, `design` (artdeco, aurora, bauhaus, blaupause, botanik, graphit, hoehenlinien, morgenrot, orbit, papier, pastell, prisma, schiefer, seide, terrazzo, tusche, wellen oder eigenes) | S | ✅ |
| `presenter.design.revealFolder` | – (Ordner für eigene CSS-Designs) | L | ✅ |
| `presenter.design.create` | `name`, `css` | S | 🆕 |

## 7. Moderatorenkarten

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.notes.get` | `slide` | L | ✅ |
| `presenter.notes.set` | `slide`, `text` | S | ✅ |
| `presenter.notes.generate` | `slides[]` \| `all`, `anew?` (KI) | S | ✅ |
| `presenter.notes.cancel` | – | S | ✅ |

## 8. KI: Präsentation erzeugen & umwandeln

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.ai.createDeck` | `deck`, `instruction` (z. B. „Predictive Coding, 8 Folien“), `withNotes`, `thenPresent` | S | ✅ |
| `presenter.ai.cancel` | – | S | ✅ |
| `presenter.ai.undoGeneration` | `deck` | S | ✅ |
| `presenter.ai.intent` | `text` (natürliche Anweisung → Folien / Karten / Vortrag) | S | ✅ |
| `presenter.ai.status` | – | L | 🆕 |
| `presenter.fromDocument` | `doc` \| `file`, `notes`, `carryObjects` (Formeln, Tabellen, Code, Bilder), `thenPresent` | S | ✅ |
| `presenter.fromDocument.plan` | `doc` → Gliederung (Kapitel/Folien) ohne Anlegen | L | 🟡 (intern ✅) |
| `presenter.toHandout` | `deck`, `tableOfContents`, `speakerNotes`, `slidePictures`, `expand`, `length: short\|medium\|long` → neues Writer-Dokument | S | ✅ |
| `presenter.toHandout.cancel` | – | S | ✅ |

_Hinweis: „Präsentation → Dokument“ ist damit über das Handout bereits umgesetzt._

## 9. Vortrag (Wiedergabe)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.play.start` | `deck`, `from?`, `screen?` (zweiter Bildschirm), `fullScreen?` | S | ✅ |
| `presenter.play.withAI` | `deck` (Vollbild, Karten vorlesen mit Qwen TTS, automatisch weiter) | S | ✅ |
| `presenter.play.next` / `.previous` | – | S | ✅ |
| `presenter.play.goTo` | `slide` \| `index` | S | ✅ |
| `presenter.play.pause` / `.resume` | – | S | ✅ |
| `presenter.play.stop` | – | S | ✅ |
| `presenter.play.readNotes` | – (aktuelle Karte vorlesen) | S | ✅ |
| `presenter.play.interrupt` | – (Vorlesen unterbrechen) | S | ✅ |
| `presenter.play.loop` | `on\|off` | S | ✅ |
| `presenter.play.status` | – (Phase: bereit, schreibt, spricht, blättert, fertig; aktuelle Folie) | L | 🆕 |

## 10. Export & Druck

| Action | Parameter | Art | Status |
|---|---|---|---|
| `presenter.export.pdf` | `deck`, `path?` (Text bleibt Text) | D | ✅ (`path` 🆕) |
| `presenter.export.slideImage` | `slide`, `format: png`, `path?` | D | 🟡 Renderer ✅ |
| `presenter.print` | `deck` | D | ✅ |

## 11. Ansicht

| Action | Parameter | Status |
|---|---|---|
| `presenter.view.panel` | Panel (Folienliste, Lesezeichen, Power) | ✅ |
| `presenter.view.backgroundPicker` | öffnen/schließen | ✅ |

---

## Empfehlungen

**Minimalsatz für den Chat (~12 Actions):**
`presenter.deck.create`, `presenter.deck.read`, `presenter.slide.add`, `presenter.slide.setText`, `presenter.slide.move`, `presenter.slide.delete`, `presenter.notes.set`, `presenter.design.apply`, `presenter.field.addText`, `presenter.field.addImage`, `presenter.slide.render`, `presenter.export.pdf`
Dazu die gebündelten KI-Actions `presenter.ai.createDeck` und `presenter.fromDocument` für große Aufgaben, die das lokale Modell selbst erledigt.

**Gebündelt statt elementar:** Ein Agent baut eine Folie am zuverlässigsten mit `presenter.slide.add --role folie --markdown "# Titel\n- Punkt 1\n- Punkt 2"` – ein Aufruf statt fünf.

**Prüfschleife:** Nach Layout-Änderungen `presenter.slide.render` aufrufen und das Bild vom Modell begutachten lassen (Überlauf, Überlappung, Lesbarkeit).

**Offene Fragen**
- Folien-IDs sind vorhanden – Element-IDs ebenfalls; reichen sie als stabile Adressen, oder braucht es zusätzlich Namen für Elemente („Logo“, „Diagramm links“)?
- Soll `presenter.slide.render` direkt an MCP-Clients als Bild zurückgegeben werden (MCP unterstützt Bildinhalte in Tool-Ergebnissen)?
- Vortrag durch Agenten: darf eine KI einen Vollbild-Vortrag starten, ohne Rückfrage?
