# StoriesStudio – Action-Katalog

_Teil des Meilensteins „Action-Schicht“ · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 02.11.2026 · abgeleitet aus dem Code (Commit `c7e95c3`)_

Legende Status: ✅ existiert in der UI/im Modell · 🟡 teilweise · 🆕 neu
Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv/nach außen (Bestätigung)

---

## 0. Besonderheiten

**Datenmodell einer Romanwelt:**
- **Welt:** Titel, Genre, Logline, Überblick, Regeln, Themen, Kalender (Zeiteinheit), Zeitleiste, Galerie
- **Struktur (Teile):** Buch → Akt → Kapitel → Abschnitt
  - Buch-Art: main, side, history, novella, anthology, other
  - Status je Teil: idea, outlined, draft, revised, done
  - **Fokus** je Teil: Was / Mit wem / Wo / Warum / Wozu – jeweils Text **und** Verknüpfungen zu Elementen
  - Erzählperspektive (POV-Figur) bei Kapitel und Abschnitt, Notizen, Zeitleiste (nicht bei Abschnitt), Galerie
- **Elemente (7 Arten):** `figure`, `place`, `event`, `reason`, `purpose`, `species`, `fact`

**Generisch + spezifisch:** Viele Actions funktionieren für alle Elementarten gleich (`stories.element.*` mit `kind`). Nur strukturierte Unterlisten (Beziehungen, Szenen, Folgen, Prämissen …) bekommen eigene Actions.

**Adressierung:** `--world <id|titel>`, `--part <id>` oder Pfad `--path "Buch 1/Akt 2/Kapitel 5"`, `--element <kind>:<id>` oder `--element figure:"Mara"` (Name, solange eindeutig).

**KI fehlt hier noch:** Das Stories Studio hat bisher keine KI-Funktionen. Abschnitt 11 schlägt sie vor (🆕). Gerade hier ist KI besonders wertvoll: Konsistenz prüfen, Figuren ausarbeiten, offene Fäden finden.

**Romantext:** Der Text lebt in Writer-Dokumenten, die mit ihrem Teil verknüpft sind (`manuscriptID`, vom Nutzer am 04.11.2026 entschieden). Die Welt enthält Fokus und Notizen.

---

## 1. Romanwelten

| Action | Parameter | Art | Status |
|---|---|---|---|
| `stories.world.list` | – | L | ✅ |
| `stories.world.create` | `title?` | S | ✅ |
| `stories.world.read` | `world`, `depth: overview\|full` | L | 🆕 (Daten ✅) |
| `stories.world.update` | `world`, Felder (title, genre, logline, overview, rules, themes) | S | ✅ |
| `stories.world.calendar` | `world`, `unit`, `suffix` (z. B. „Jahr“, „n. d. F.“) | S | ✅ |
| `stories.world.delete` | `world` | D | ✅ |
| `stories.world.export` | `world`, `format: markdown\|json`, `path?` (Story-Bible) | D | 🆕 |

## 2. Struktur: Bücher, Akte, Kapitel, Abschnitte

| Action | Parameter | Art | Status |
|---|---|---|---|
| `stories.part.tree` | `world` | L | ✅ (Navigator) |
| `stories.part.read` | `part` | L | 🆕 (Daten ✅) |
| `stories.part.add` | `world`, `level: book\|act\|chapter\|section`, `parent?`, `title?` | S | ✅ |
| `stories.part.update` | `part`, `title?`, `subtitle?`, `notes?` | S | ✅ |
| `stories.part.bookKind` | `part`, `main\|side\|history\|novella\|anthology\|other` | S | ✅ |
| `stories.part.status` | `part`, `idea\|outlined\|draft\|revised\|done` | S | ✅ |
| `stories.part.focus.set` | `part`, `aspect: was\|mitWem\|wo\|warum\|wozu`, `text` | S | ✅ |
| `stories.part.focus.link` / `.unlink` | `part`, `aspect`, `element` | S | ✅ |
| `stories.part.pov` | `part`, `figure` \| `none` (nur Kapitel/Abschnitt) | S | ✅ |
| `stories.part.move` | `part`, `by: -1\|+1` | S | ✅ |
| `stories.part.reparent` | `part`, `parent` | S | 🆕 |
| `stories.part.delete` | `part` (mit Unterteilen) | D | ✅ |

_Abkürzung für Agenten 🆕: `stories.outline.create` – eine ganze Gliederung (Bücher/Akte/Kapitel mit Fokus) in einem Aufruf als JSON/Markdown anlegen._

## 3. Elemente allgemein (alle 7 Arten)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `stories.element.list` | `world`, `kind`, `query?`, `tag?` | L | ✅ |
| `stories.element.read` | `element` | L | 🆕 (Daten ✅) |
| `stories.element.create` | `world`, `kind`, `name`, Felder? | S | ✅ |
| `stories.element.createFromText` | `world`, `kind`, `text` (erste Zeile = Name, Rest = Haupttext) | S | ✅ (Power-Panel) |
| `stories.element.update` | `element`, Felder | S | ✅ |
| `stories.element.delete` | `element` (Verweise werden überall entfernt) | D | ✅ |
| `stories.element.usages` | `element` → wo verwendet (Teile, Events, Fakten …) | L | ✅ |
| `stories.element.facts` | `element` → Fakten zu diesem Element | L | ✅ |
| `stories.element.search` | `world`, `query` (alle Arten) | L | 🟡 |

## 4. Figuren

Felder: name, epithet, role (none, protagonist, antagonist, deuteragonist, mentor, supporting, minor), species, birth, origin, biography, appearance, behavior, secrets, wants, needs, coreConflict, fears, development, persona, politics, voice, perception

| Action | Parameter | Status |
|---|---|---|
| `stories.figure.personality` | `figure`, Achsen `energy`, `perception`, `decisions`, `lifestyle` (Werte + Notizen), `neuroticism?`, `stressNote?` | ✅ |
| `stories.figure.relation.add` | `figure`, `target` (Element), `attitude` (−/+), `label`, `note?` | ✅ |
| `stories.figure.relation.update` / `.remove` | `relation`, Felder | ✅ |
| `stories.figure.relations.incoming` | `figure` → wer steht wie zu ihr | ✅ |
| `stories.figure.scene.add` | `figure`, `kind: quote\|scene\|incident`, `text`, `part?` | ✅ |
| `stories.figure.scene.update` / `.remove` | `scene`, Felder | ✅ |
| `stories.figure.image.add` / `.remove` | `figure`, `file`, `caption?` | ✅ |
| `stories.figure.video.add` / `.remove` | `figure`, `file`, `caption?` (Videocards) | ✅ |

## 5. Orte

Felder: name, placeKind (world, realm, region, city, castle, building, landscape, water, other), atmosphere, geography, history, society, significance, secrets, notes

| Action | Parameter | Status |
|---|---|---|
| `stories.place.parent` | `place`, `parent` \| `none` (verschachteln) | ✅ |
| `stories.place.possibleParents` | `place` (ohne Zyklen) | ✅ |
| `stories.place.subplaces` | `place` | ✅ |
| `stories.place.residents` | `place`, `add[]`, `remove[]` (Figuren) | ✅ |
| `stories.place.image.add` / `.remove` | `place`, `file` | ✅ |

## 6. Events

Felder: name, eventKind (turningPoint, conflict, political, personal, revelation, catastrophe, ritual, other), when, course, causes, significance, notes, knowledge (open, rumour, secret)

| Action | Parameter | Status |
|---|---|---|
| `stories.event.places` / `.figures` | `event`, `add[]`, `remove[]` | ✅ |
| `stories.event.cause.add` / `.remove` | `event`, `causeEvent` (Ursachenkette) | ✅ |
| `stories.event.causes` / `.followers` | `event` → Kette rückwärts/vorwärts | ✅ |
| `stories.event.consequence.add` | `event`, `area` (power, society, personal, economy, war, faith, nature), `reach` (immediate, medium, long), `text`, `affected[]`, `followEvent?` | ✅ |
| `stories.event.consequence.update` / `.remove` | `consequence`, Felder | ✅ |
| `stories.event.knowledge` | `event`, `open\|rumour\|secret`, `knownBy[]` (Figuren) | ✅ |

## 7. Reasons (Begründungen/Argumente)

Felder: name, holder (Figur), conclusion, weakness, notes

| Action | Parameter | Status |
|---|---|---|
| `stories.reason.assumption.add` | `reason`, `text`, `validity: open\|holds\|mistaken` | ✅ |
| `stories.reason.premise.add` | dto. | ✅ |
| `stories.reason.statement.update` / `.remove` | `statement`, Felder | ✅ |

## 8. Purposes (literarische Funktion)

Felder: name, function (exposition, tension, turningPoint, foreshadowing, characterization, worldbuilding, theme, redHerring, retardation, relief, contrast, climax, resolution, catharsis, other), intent, readerEffect, theme, notes

| Action | Parameter | Status |
|---|---|---|
| `stories.purpose.setup` | `purpose`, `add[]`, `remove[]` (Teile, in denen etwas angelegt wird) | ✅ |
| `stories.purpose.payoff` | dto. (Teile, in denen es eingelöst wird) | ✅ |
| `stories.purpose.openPromises` | `world` → Setups ohne Payoff | ✅ (Markierung im Modell) |

## 9. Spezies & Fakten

**Spezies** – Felder: name, speciesKind (people, beast, magical, spirit, undead, plant, other), appearance, abilities, weaknesses, lifeCycle, habitat, culture, relations, history, significance, secrets, notes

| Action | Parameter | Status |
|---|---|---|
| `stories.species.habitat` | `species`, `add[]`, `remove[]` (Orte) | ✅ |
| `stories.species.members` | `species` → Figuren dieser Spezies | ✅ |
| `stories.species.image.add` / `.remove` | `species`, `file` | ✅ |

**Fakten** – Felder: name, text, tags, source

| Action | Parameter | Status |
|---|---|---|
| `stories.fact.tag` | `fact`, `add[]`, `remove[]` | ✅ |
| `stories.fact.link` / `.unlink` | `fact`, `element` (Figur, Spezies, Ort, Event) | ✅ |
| `stories.fact.image.add` / `.remove` | `fact`, `file` | ✅ |
| `stories.fact.filter` | `world`, `tags[]`, `query?` | ✅ |

## 10. Zeitleisten, Galerien, Verbindungen

| Action | Parameter | Art | Status |
|---|---|---|---|
| `stories.timeline.read` | `owner: world\|part` | L | ✅ |
| `stories.timeline.pin` | `owner`, `element`, `start`, `end?`, `note?` | S | ✅ |
| `stories.timeline.update` / `.unpin` | `entry`, Felder | S | ✅ |
| `stories.timeline.scale` | `owner`, `unit`, `suffix` | S | ✅ |
| `stories.element.pins` | `element` → alle Zeitleisten-Einträge | L | ✅ |
| `stories.gallery.add` | `world` \| `part`, `file`, `caption?` | S | ✅ |
| `stories.gallery.update` / `.remove` | `image`, `caption?` | S | ✅ |
| `stories.gallery.list` | `world` \| `part` (inkl. Unterteile) | L | ✅ |
| `stories.part.manuscript` | `part` → zugehöriges Writer-Dokument anlegen/öffnen | S | 🆕 |
| `stories.image.generate` | Ziel (Figur, Ort, Spezies, Galerie), `prompt?` (Draw Things, Prompt aus Beschreibung) | S | 🆕 |
| `stories.studio.open` / `.close` | `world?`, `element?` | L | ✅ |

## 11. KI im Stories Studio (Vorschläge, alle 🆕)

| Action | Was sie tut |
|---|---|
| `stories.ai.develop` | Element ausarbeiten: leere Felder einer Figur/eines Orts passend zur Welt füllen (als Vorschlag) |
| `stories.ai.consistency` | Widersprüche finden: Zeitleiste, Wissen (wer weiß was wann), Spezies-Fähigkeiten, Ortslogik |
| `stories.ai.openThreads` | offene Versprechen (Setup ohne Payoff), Figuren ohne Entwicklung, ungenutzte Events |
| `stories.ai.outline` | Gliederung aus Logline/Überblick vorschlagen (Akte, Kapitel mit Fokus) |
| `stories.ai.extract` | aus einem Text (Notiz, Manuskript, Chat) Figuren, Orte, Events, Fakten erkennen und anlegen |
| `stories.ai.scene` | Szene skizzieren aus Fokus (Was/Mit wem/Wo/Warum/Wozu) → Writer |
| `stories.ai.ask` | Fragen an die Welt („Wer kennt das Geheimnis von X?“) – beantwortet aus den Daten |
| `stories.ai.persona` | Figur als Chat-Persona übernehmen (Stimme, Wissen, Haltung) – Brücke zu den Personas |

_Grundsatz: KI-Vorschläge werden als Entwurf markiert und erst nach Bestätigung übernommen – die Welt gehört der Autorin/dem Autor._

---

## Empfehlungen

**Minimalsatz für den Chat (~10 Actions):**
`stories.world.read`, `stories.part.tree`, `stories.part.read`, `stories.part.add`, `stories.part.focus.set`, `stories.element.list`, `stories.element.read`, `stories.element.create`, `stories.element.update`, `stories.element.usages`

**Kontext sparen:** Eine Romanwelt kann groß werden. `stories.world.read --depth overview` sollte nur Namen und Kurzzeilen liefern; Details holt das Modell gezielt nach. Für ein 9B-Modell mit 16–32K Kontext ist das entscheidend.

**Offene Fragen**
- Figuren als Chat-Personas: gewünscht? (Würde Stories, Personas und Thalamus verbinden.)
- Export als „Story-Bible“ (Markdown/PDF) gewünscht?
