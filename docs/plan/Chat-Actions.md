# Chat – Action-Katalog

_Teil des Meilensteins „Action-Schicht“ · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 02.11.2026 · abgeleitet aus dem Code (Commit `c7e95c3`)_

Legende Status: ✅ existiert in der UI/im Modell · 🟡 teilweise · 🆕 neu
Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv/nach außen/sensibel (Bestätigung)

---

## 0. Besonderheiten: Der Chat hat zwei Rollen

**1. Chat als Modul, das gesteuert wird.** Ein Agent (z. B. Claude über MCP oder ein AgentSteps-Workflow) legt Chats an, schickt Nachrichten, liest Antworten. So kann ein großes Modell Teilaufgaben an das lokale Modell delegieren – oder eine Persona befragen.

**2. Chat als Steuerzentrale, die selbst Actions benutzt.** Der Chat ist der Ort, an dem das lokale Modell die Actions aller Studios als Tools bekommt. Dafür braucht es eine neue Gruppe `chat.tools.*` (Abschnitt 9): Welche Action-Gruppen darf dieser Chat benutzen?

**Vorbild existiert schon:** Web-/Wikipedia-Suche (`WebTools`) und die Persona-Dateiwerkzeuge (`PersonaFileTools`: Dateien durchsuchen, Datei lesen) sind bereits Tools mit Beschreibung, Parametern und protokollierten Schritten (`ToolStep`). Die Action-Schicht verallgemeinert dieses Muster.

**Asynchron:** Antworten werden gestreamt. `chat.send` liefert sofort eine Nachrichten-ID; das Ergebnis holt man mit `chat.wait` oder fragt den Status ab. Mehrere Chats können gleichzeitig antworten.

**Adressierung:** `--chat <id|titel>`, `--message <id>` oder `--message last` / `--message -2` (relativ, praktisch für Agenten), `--persona <id|name>`, `--skill <id|name>`, `--folder <id|name>`.

**Sensible Daten:** API-Schlüssel werden von keiner Lese-Action ausgegeben. Gedächtnis (Thalamus) und Persona-Dateien sind persönlich – Lese- und Lösch-Actions darauf sind als **D** eingestuft.

---

## 1. Chats verwalten

| Action | Parameter | Art | Status |
|---|---|---|---|
| `chat.list` | `folder?`, `query?`, `persona?`, `limit?` | L | ✅ |
| `chat.create` | `title?`, `folder?`, `persona?`, `skills[]?`, `model?`, `contextLength?`, `memory: on\|off`, `webSearch?`, `wikipedia?`, `thinking?` | S | ✅ |
| `chat.open` | `chat`, `window: main\|mini` | L | ✅ |
| `chat.rename` | `chat`, `title` | S | ✅ |
| `chat.autoTitle` | `chat` | S | ✅ |
| `chat.move` | `chat`, `folder` \| `newFolder` | S | ✅ |
| `chat.branch` | `chat`, `at: message` (abzweigen) | S | ✅ |
| `chat.branch.source` | `chat` → ursprünglicher Chat | L | ✅ |
| `chat.delete` | `chat` | D | ✅ |

## 2. Lesen & Zustand abfragen

| Action | Parameter | Liefert | Status |
|---|---|---|---|
| `chat.read` | `chat`, `from?`, `limit?`, `withReasoning?`, `withTools?` | Nachrichten (Rolle, Text, Modell, Zeit, Bilder, Werkzeugschritte) | 🆕 (Daten ✅) |
| `chat.message.read` | `message` | eine Nachricht vollständig, inkl. Statistik, Fehler, Folgefragen, Quellen | 🆕 |
| `chat.outline.get` | `chat` | Inhaltsverzeichnis des Chats | ✅ |
| `chat.sources.get` | `chat` | Web-/Wikipedia-/Datei-Quellen aller Antworten | ✅ |
| `chat.search` | `query` (über alle Chats) | Treffer mit Chat und Nachricht | ✅ |
| `chat.state.get` | `chat?` | Modell, Kontextlänge, Kontextauslastung, Persona, Skills, Schalter, läuft gerade? | 🆕 (Daten ✅) |
| `chat.context.usage` | `chat` | Token belegt / verfügbar | ✅ |

## 3. Nachrichten & Generierung

| Action | Parameter | Art | Status |
|---|---|---|---|
| `chat.send` | `chat`, `text`, `images[]?`, `screenGlance?` → `messageID` | S | ✅ |
| `chat.wait` | `message`, `timeout?` → fertige Antwort | L | 🆕 |
| `chat.ask` | wie `send` + `wait` in einem Aufruf (für Agenten am bequemsten) | S | 🆕 |
| `chat.status` | `chat` → idle / denkt / schreibt / Werkzeug läuft | L | 🟡 |
| `chat.stop` | `chat` | S | ✅ |
| `chat.regenerate` | `chat`, `message?` (Standard: letzte Antwort) | S | ✅ |
| `chat.edit` | `message`, `text`, `images[]?` (Frage bearbeiten, ab dort neu generieren) | S | ✅ |
| `chat.followUps.get` | `message` → vorgeschlagene Folgefragen | L | ✅ |
| `chat.followUps.send` | `chat`, `index` \| `text` | S | ✅ |
| `chat.message.copy` | `message`, `format: markdown\|plain` | L | ✅ |
| `chat.draft.set` / `.get` | `chat`, `text`, `images[]?` (Eingabefeld füllen, ohne zu senden) | S | 🟡 |

## 4. Chat-Einstellungen

| Action | Parameter | Status |
|---|---|---|
| `chat.model.set` | `chat`, `model` | ✅ |
| `chat.contextLength.set` | `chat`, `8192\|16384\|32768` (lädt Modell neu) | ✅ |
| `chat.thinking.set` | `chat`, `on\|off` | ✅ |
| `chat.webSearch.set` | `chat`, `on\|off` | ✅ |
| `chat.wikipedia.set` | `chat`, `on\|off` | ✅ |
| `chat.memory.set` | `chat`, `on\|off` (Thalamus) | ✅ |
| `chat.persona.set` | `chat`, `persona` \| `none` | ✅ |
| `chat.skills.set` | `chat`, `add[]`, `remove[]` | ✅ |

_Hinweis: Manche Einstellungen sind im Code nur vor der ersten Nachricht änderbar (`isChatSetupLocked`). Die Action meldet dann einen klaren Fehler statt still nichts zu tun._

## 5. Lesezeichen & Navigation

| Action | Parameter | Art | Status |
|---|---|---|---|
| `chat.bookmark.add` | `message`, `selectedText?` | S | ✅ |
| `chat.bookmark.rename` / `.delete` | `bookmark`, `title?` | S | ✅ |
| `chat.bookmark.list` | `chat` | L | ✅ |
| `chat.jump` | `chat`, `bookmark` \| `outlineEntry` \| `message` | L | ✅ |

## 6. Bilder

| Action | Parameter | Art | Status |
|---|---|---|---|
| `chat.image.attach` | `chat`, `files[]` (max. 1600 px) | S | ✅ |
| `chat.image.removeDraft` | `chat`, `image` | S | ✅ |
| `chat.image.generate` | `chat`, `prompt` (Draw Things) | S | ✅ |
| `chat.image.cancel` | `generation` \| `all` | S | ✅ |
| `chat.screen.glance` | `display?` (Bildschirm ohne Mini-Fenster an nächste Nachricht) | D | ✅ |

_`screen.glance` ist **D**, weil ein Bildschirmfoto persönliche Inhalte zeigen kann – ein Agent sollte das nur nach Freigabe auslösen._

## 7. Export

| Action | Parameter | Art | Status |
|---|---|---|---|
| `chat.export.pdf` | `chat`, `withOutline?`, `path?` | D | ✅ (`path` 🆕) |
| `chat.export.answer` | `message`, `path?` (einzelne Antwort als PDF) | D | ✅ |
| `chat.export.markdown` | `chat`, `path?` | D | 🆕 |
| `chat.toDocument` | `chat` \| `message[]` → neues Writer-Dokument | S | 🆕 (heute per Ziehen im Power-Panel ✅) |

## 8. Ordner (Chats und Skills)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `folder.create` | `section: chats\|skills`, `name`, `color?` | S | ✅ |
| `folder.rename` | `folder`, `name` | S | ✅ |
| `folder.color` | `folder`, `color` | S | ✅ |
| `folder.collapse` | `folder`, `on\|off` | S | ✅ |
| `folder.delete` | `folder` | D | ✅ |

## 9. Werkzeuge im Chat (neu: Brücke zur Action-Schicht)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `chat.tools.list` | `chat` → aktive Werkzeuge/Action-Gruppen | L | 🟡 (Web/Wiki/Dateien ✅) |
| `chat.tools.enable` / `.disable` | `chat`, `groups[]` (z. B. `writer.core`, `presenter.core`, `citation.core`, `stories.core`) | S | 🆕 |
| `chat.tools.approval` | `chat`, `ask\|allowWrites\|allowAll` (wie viel der Chat ohne Rückfrage darf) | S | 🆕 |
| `chat.tools.log` | `chat` → ausgeführte Actions mit Ergebnis | L | 🟡 (`ToolStep` ✅) |
| `chat.tools.undoTurn` | `chat`, `message` → alle Änderungen einer Antwort zurücknehmen | S | 🆕 |

_Das ist der Kern dessen, was du willst: Der lokale Chat bekommt die Minimalsätze der Studios als Tools, sieht jeden Schritt im Verlauf, und eine ganze Antwort lässt sich mit einem Klick rückgängig machen._

## 10. Skills

| Action | Parameter | Art | Status |
|---|---|---|---|
| `skill.list` | `folder?` | L | ✅ |
| `skill.read` | `skill` | L | ✅ |
| `skill.create` | `name`, `summary`, `instructions`, `symbol?`, `folder?` | S | ✅ |
| `skill.update` | `skill`, Felder | S | ✅ |
| `skill.duplicate` | `skill` | S | ✅ |
| `skill.move` | `skill`, `folder` \| `newFolder` | S | ✅ |
| `skill.import` | `file` (`.md`) | S | 🆕 |
| `skill.export` | `skill`, `path?` (`.md`) | D | 🆕 |
| `skill.delete` | `skill` | D | ✅ |

## 11. Personas

| Action | Parameter | Art | Status |
|---|---|---|---|
| `persona.list` | – | L | ✅ |
| `persona.read` | `persona` (ohne Dateiinhalte) | L | ✅ |
| `persona.create` | `name`, `biography`, `behavior`, `voice?`, `voiceStyle?` | S | ✅ |
| `persona.update` | `persona`, Felder | S | ✅ |
| `persona.avatar.set` / `.remove` | `persona`, `file` | S | ✅ |
| `persona.files.add` / `.remove` | `persona`, `files[]` | S | ✅ |
| `persona.files.search` | `persona`, `query` (wie das bestehende Persona-Tool) | D | ✅ |
| `persona.voice.preview` | `persona`, `text?` | S | ✅ |
| `persona.startChat` | `persona` → neuer Chat | S | ✅ |
| `persona.delete` | `persona` | D | ✅ |

## 12. Gedächtnis (Thalamus) – sensibel

| Action | Parameter | Art | Status |
|---|---|---|---|
| `memory.profile.get` | `persona` | D | ✅ |
| `memory.list` | `persona`, `kind: impressions\|memories\|facts` | D | ✅ |
| `memory.consolidate` | `persona` \| `all` (Verdichtung jetzt ausführen) | S | ✅ |
| `memory.consolidate.cancel` | – | S | ✅ |
| `memory.delete` | `persona`, `item` (Eindruck, Erinnerung, Fakt) | D | ✅ |
| `memory.deleteAll` | `persona` | D | ✅ |

_Empfehlung: Gedächtnis-Actions standardmäßig **nicht** über MCP nach außen geben – nur im internen Chat und mit Freigabe._

## 13. Sprache & Gesprächsmodus

| Action | Parameter | Status |
|---|---|---|
| `chat.speak` | `message` (Antwort vorlesen, Qwen TTS) | ✅ |
| `chat.speak.stop` | – | ✅ |
| `chat.conversation.start` / `.stop` | `chat` (Diktat ↔ Sprachausgabe im Wechsel) | ✅ |
| `chat.dictation.start` / `.stop` | `chat` (nur sinnvoll mit Mensch am Mikrofon) | ✅ |

## 14. Mini-Chat & Ansicht

| Action | Parameter | Status |
|---|---|---|
| `minichat.open` | `chat?` \| `new` | ✅ |
| `minichat.pin` | `on\|off` (vor allen Fenstern) | ✅ |
| `minichat.toMainWindow` | – | ✅ |
| `view.sidebar` / `view.panel` | `show\|hide`, Panel (Inhalt, Lesezeichen, Quellen, Power) | ✅ |

## 15. Verbindung, Modelle, Bibliothek (global)

| Action | Parameter | Art | Status |
|---|---|---|---|
| `models.list` | – (mit Ladezustand) | L | ✅ |
| `models.refresh` | – | L | ✅ |
| `models.load` | `model`, `contextLength` | S | ✅ |
| `connection.get` | – (Anbieter, Endpoint; **ohne** Schlüssel) | L | ✅ |
| `connection.set` | `provider: lmStudio\|kapitsa`, `endpoint`, `apiKey?` | D | ✅ |
| `library.list` | – (zuletzt geöffnete Bibliotheken) | L | ✅ |
| `library.open` / `.create` | `path` \| `name` | D | ✅ |

_`library.open` ist **D**: Ein Bibliothekswechsel beendet alle laufenden Arbeiten und tauscht den gesamten Inhalt aus._

---

## Empfehlungen

**Minimalsatz für externe Agenten (MCP, ~8 Actions):**
`chat.create`, `chat.ask`, `chat.read`, `chat.list`, `chat.search`, `persona.list`, `skill.list`, `models.list`
Damit kann z. B. Claude das lokale Modell oder eine Persona gezielt befragen.

**Für den internen Chat:** Abschnitt 9 ist der wichtigste neue Baustein. Die Studios liefern Tool-Gruppen (`writer.core` usw.), der Chat schaltet sie zu – vergleichbar mit dem heutigen Schalter für die Websuche.

**Rekursion vermeiden:** Ein Chat sollte sich nicht selbst über `chat.send` Nachrichten schicken können. `chat.*`-Actions im internen Chat nur für *andere* Chats freigeben (z. B. „frag die Persona X“).

**Offene Fragen**
- Sollen Cloud-Anbieter (Claude, CometAPI) als weitere `provider` in `connection.set` und `chat.model.set` erscheinen?
- Darf ein Agent den Gesprächsmodus starten (Mikrofon)?
- Gedächtnis-Actions über MCP: komplett gesperrt oder nur lesend mit Freigabe?
- Skills als `.md`-Import/Export – passend zu deiner ursprünglichen Beschreibung („Skills als .md-Dateien“)?
