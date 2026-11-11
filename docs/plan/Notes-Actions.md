# Notes – Action-Katalog

_Teil der Action-Schicht · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 11.11.2026 · alle Actions gebaut und über die Registry getestet (`NotesActionTests`)_

Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv (Bestätigung je nach Freigabestufe)

---

## 0. Besonderheiten

**Datenmodell eines Notes:** Titel, Fortschrittsanzeige (`anzeige`), ToDos mit Unter-ToDos in beliebiger Tiefe, freier Notiztext, Zugehörigkeiten (`gehoertZu`). Ein ToDo hat Text, erledigt, eingeklappt und verknüpfte Dokumente. Format: [Speicherformate](../speicherformate.md#notes).

**Fortschritt:** Es zählen die ToDos ohne eigene Unter-ToDos. Ein ToDo mit Unter-ToDos ist erledigt, sobald alle erledigt sind; Abhaken hakt alle darunter mit ab, Öffnen öffnet alle. So stimmen Liste und Anzeige immer überein.

**Zugehörigkeit:** Ein Note kann allgemein sein oder zu einem Writer-Dokument, einer Präsentation, einer Romanwelt oder einem ihrer Teile gehören, auch zu mehreren. Die Zugehörigkeit steht im Note; Dokumente und Welten bleiben unverändert.

**Adressierung:**
- `--note <id|titel>` (Titel muss eindeutig sein)
- `--todo` als ID, Nummer wie in der Liste (`2.1` = erstes Unter-ToDo des zweiten), Pfad aus Texten (`Webseite/Startseite`) oder ein Text, den nur ein ToDo hat
- Besitzer als `--doc <id|titel>` (Dokument oder Präsentation) oder `--world <id|titel>` mit optionalem `--part <id|Pfad>`

**Sicherheit:** Notes haben keine eigene Herkunft, und Agenten können in sie schreiben. Lesen zählt deshalb als fremd (A), wie bei Romanwelten. Löschen von Notes und ToDos ist destruktiv; alles lässt sich über die Undo-Gruppe des Laufs zurücknehmen.

---

## 1. Notes

| Action | Parameter | Art |
|---|---|---|
| `notes.note.list` | `query?`, `doc?`, `world?` + `part?`, `general?` (nur allgemeine) | L |
| `notes.note.create` | `title?`, `style?`, `text?`, `todos?` (JSON), `markdown?` (Aufgabenliste), `doc?`/`world?`+`part?`, `open?` | S |
| `notes.note.read` | `note`, `format: json\|markdown` | L |
| `notes.note.update` | `note`, `title?`, `text?`, `appendText?`, `style?` | S |
| `notes.note.delete` | `note` (Papierkorb) | D |
| `notes.note.attach` | `note`, `doc` oder `world` + `part?` | S |
| `notes.note.detach` | `note`, `doc` oder `world` + `part?` | S |
| `notes.note.progress` | `note`: erledigt, offen, je Hauptaufgabe, die nächsten fünf offenen | L |
| `notes.note.removeDone` | `note` | D |

Ohne Titel bekommt ein Note mit Besitzer dessen Namen („Bachelorarbeit“).

## 2. ToDos

| Action | Parameter | Art |
|---|---|---|
| `notes.todo.add` | `note`, `text`, `parent?` oder `after?`, `done?` | S |
| `notes.todo.addMany` | `note`, `todos?` (`[{text, done, children}]`) oder `markdown?`, `parent?` | S |
| `notes.todo.update` | `note`, `todo`, `text` | S |
| `notes.todo.check` | `note`, `todo`, `done?` (Vorgabe true) | S |
| `notes.todo.delete` | `note`, `todo` (mit Unter-ToDos) | D |
| `notes.todo.move` | `note`, `todo`, `by` **oder** `parent`/`top` mit `index?` | S |
| `notes.todo.indent` | `note`, `todo`, `direction: in\|out` | S |
| `notes.todo.collapse` | `note`, `todo?` (ohne: alle), `collapsed?` | S |
| `notes.todo.link` | `note`, `todo`, `doc` | S |
| `notes.todo.unlink` | `note`, `todo`, `doc` (auch die ID eines gelöschten Dokuments) | S |

`markdown` versteht `- [ ]`, `- [x]`, `*`, `+`, `1.` und Einrückung (zwei Leerzeichen oder Tab je Stufe). Enthält der Text eine Liste, werden nur deren Zeilen ToDos; sonst jede Zeile.

## 3. Anzeigen und Studio

| Action | Parameter | Art |
|---|---|---|
| `notes.styles.list` | – | L |
| `notes.studio.open` | `note?`, `todo?` (bekommt die Schreibmarke) | L |
| `notes.studio.close` | – | L |
| `writer.view.panel` | `panel: notes` zeigt die Notes des offenen Dokuments rechts | L |

Anzeigen: `balken`, `ringe`, `glas`, `pflanze`, `rakete`, `gipfel`, `akku`, `mond`, `pizza`, `schnecke`, `tacho`, `pixel`.

## 4. Chat, MCP, Suchleiste

- Werkzeuggruppe im Chat **„Notes: ToDos und Fortschritt“** (`notes.core`): `notes.note.list`, `.create`, `.read`, `.progress`, `notes.todo.add`, `.addMany`, `.check`, `.update`, `.delete`.
- MCP-Profil `notes`, Resource `llmd://notes/note/{id}`, Ereignis `note.changed` für Abonnements.
- Die Suchleiste schaltet die Gruppe bei Wörtern wie „ToDo“, „Aufgabe“, „abhaken“, „Checkliste“, „Fortschritt“ zu.

## 5. Beispiele

```bash
llmd notes note create --title "Webseite programmieren" --style rakete \
  --markdown $'- [ ] Konzept ausarbeiten\n  - [ ] Zielgruppe\n- [ ] Design\n- [ ] Umsetzung'
llmd notes todo link --note "Webseite programmieren" --todo "Konzept ausarbeiten" --doc Konzept
llmd notes todo check --note "Webseite programmieren" --todo 1.1
llmd notes note create --doc Bachelorarbeit --markdown $'- [ ] Einleitung\n- [ ] Methodik\n- [ ] Ergebnisse'
llmd notes note progress --note Bachelorarbeit --json
```
