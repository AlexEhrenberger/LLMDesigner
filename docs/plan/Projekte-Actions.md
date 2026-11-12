# Projekte – Action-Katalog

_Teil der Action-Schicht · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 12.11.2026 · alle Actions gebaut und über die Registry getestet (`ProjectsActionTests`)_

Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv (Bestätigung je nach Freigabestufe)

---

## 0. Besonderheiten

**Datenmodell:** Ein Projekt hat eine Seite aus Bausteinen auf einem Raster mit 12 Spalten, ein Aufgaben-Board mit eigenen Spalten, ToDo-Listen, Meilensteine, Verknüpfungen und einen Verlauf je Tag. Format: [Speicherformate](../speicherformate.md#projekte).

**Verknüpfungen:** Ein Projekt, eine Aufgabe und ein ToDo zeigen auf Chats, Dokumente, Präsentationen, Notes und Romanwelten (mit Teil oder Element). Die Verknüpfung steht im Projekt; das Verknüpfte bleibt, wo es ist. Ein gelöschtes Ding bleibt als Hinweis stehen (`exists: false`) und lässt sich über seine ID lösen.

**Fortschritt:** Aufgaben zählen als erledigt, wenn sie in einer Spalte mit `done` stehen. Eine Aufgabe ist abnahmebereit (`acceptable`), wenn alle Akzeptanzkriterien erfüllt sind; sie ist blockiert (`blocked`), solange ein Hindernis offen ist. „Alles“ zählt Aufgaben, ToDos und Meilensteine zusammen.

**Adressierung:**
- `--project <id|titel>` (Titel muss eindeutig sein)
- Aufgaben, Spalten, Bausteine, ToDo-Listen, ToDos, Meilensteine, Kriterien und Hindernisse als ID, Nummer wie in der Ausgabe (Meilensteine nach Datum) oder eindeutigen Titel
- Verknüpftes als `--chat`, `--doc`, `--note` oder `--world` mit `--part <Pfad>` oder `--element figure:Mara`
- Tage als `2026-11-20`; ein leerer Text entfernt den Tag

**Sicherheit:** Projekte haben keine eigene Herkunft, und Agenten können in sie schreiben. Lesen zählt deshalb als fremd (A), wie bei Notes und Romanwelten. Löschen ist destruktiv; alles lässt sich über die Undo-Gruppe des Laufs zurücknehmen. Chat-Gruppe `projects.core`, MCP-Profil `projects`, Resource `llmd://projects/project/{id}`, Ereignis `project.changed`.

---

## 1. Projekte

| Action | Parameter | Art |
|---|---|---|
| `projects.project.list` | `query?`, `status?` | L |
| `projects.project.create` | `title?`, `subtitle?`, `status?`, `color?`, `symbol?`, `empty?` (ohne Startseite), `columns?` (die letzte zählt als erledigt), `open?`, Verknüpfung? | S |
| `projects.project.read` | `project`, `include: alles\|seite\|board\|kurz` | L |
| `projects.project.update` | `project`, `title?`, `subtitle?`, `status?`, `color?`, `symbol?`, `font?`, `background?`, `accent?` | S |
| `projects.project.delete` | `project` (Papierkorb) | D |
| `projects.project.progress` | `project`: Aufgaben, Kriterien, ToDos, Meilensteine, Hindernisse, Spalten, Verlauf | L |

## 2. Verknüpfungen

| Action | Parameter | Art |
|---|---|---|
| `projects.link.add` | `project`, Verknüpfung | S |
| `projects.link.remove` | `project`, Verknüpfung (überall im Projekt; Gelöschtes per ID) | S |
| `projects.link.find` | Verknüpfung: welche Projekte, Aufgaben und ToDos darauf zeigen | L |

## 3. Seite

| Action | Parameter | Art |
|---|---|---|
| `projects.block.list` | `project` | L |
| `projects.block.add` | `project`, `kind`, `x?`, `y?`, `width?`, `height?`, Einstellungen (siehe unten) | S |
| `projects.block.update` | `project`, `block`, Einstellungen | S |
| `projects.block.move` | `project`, `block`, `x?`, `y?`, `width?`, `height?` (was im Weg ist, rückt nach unten) | S |
| `projects.block.delete` | `project`, `block` | D |
| `projects.block.entries` | `project`, `block`, `entries` (eigene Werte eines Diagramms) | S |
| `projects.styles.list` | – : Bausteine, Anzeigen, Diagramme, Datenquellen, Zählweisen, Hintergründe, Farben | L |

Einstellungen eines Bausteins: `title`, `text`, `font` (`seite` = wie die Seite), `size`, `textColor`, `bold`, `italic`, `align`, `measure`, `display`, `list`, `chart`, `source`, `date`, `color`, `value`.

## 4. ToDos und Meilensteine

| Action | Parameter | Art |
|---|---|---|
| `projects.todolist.add` | `project`, `title?`, `block?` (Baustein dazu) | S |
| `projects.todolist.delete` | `project`, `list` | D |
| `projects.todo.add` | `project`, `list?`, `text` oder `texts`, `due?`, Verknüpfung? | S |
| `projects.todo.check` | `project`, `todo`, `list?`, `done?` | S |
| `projects.todo.update` | `project`, `todo`, `text?`, `due?`, Verknüpfung?, `unlink?` | S |
| `projects.todo.delete` | `project`, `todo` | D |
| `projects.milestone.add` | `project`, `title`, `date`, `done?`, `color?` | S |
| `projects.milestone.update` | `project`, `milestone`, `title?`, `date?`, `done?`, `color?` | S |
| `projects.milestone.delete` | `project`, `milestone` | D |

## 5. Board

| Action | Parameter | Art |
|---|---|---|
| `projects.column.add` | `project`, `title`, `color?`, `done?`, `limit?`, `position?` (ohne: vor den erledigten) | S |
| `projects.column.update` | `project`, `column`, `title?`, `color?`, `done?`, `limit?` (0 entfernt), `position?` | S |
| `projects.column.delete` | `project`, `column` (Aufgaben in die Spalte davor) | D |
| `projects.task.list` | `project`, `column?`, `query?`, `blocked?`, `open?` | L |
| `projects.task.add` | `project`, `title`, `column?`, `details?`, `priority?`, `start?`, `due?`, `tags?`, `criteria?`, `impediments?`, Verknüpfung? | S |
| `projects.task.read` | `project`, `task` | L |
| `projects.task.update` | `project`, `task`, `title?`, `details?`, `appendDetails?`, `priority?`, `start?`, `due?`, `tags?` | S |
| `projects.task.move` | `project`, `task`, `column`, `before?` | S |
| `projects.task.delete` | `project`, `task` | D |
| `projects.task.criterion.add` | `project`, `task`, `text` oder `texts` | S |
| `projects.task.criterion.check` | `project`, `task`, `criterion`, `met?` → erfüllt, gesamt, abnahmebereit | S |
| `projects.task.criterion.delete` | `project`, `task`, `criterion` | D |
| `projects.task.impediment.add` | `project`, `task`, `text`, `solution?` | S |
| `projects.task.impediment.update` | `project`, `task`, `impediment`, `text?`, `solution?`, `resolved?` | S |
| `projects.task.impediment.delete` | `project`, `task`, `impediment` | D |
| `projects.task.link` | `project`, `task`, Verknüpfung | S |
| `projects.task.unlink` | `project`, `task`, Verknüpfung (Gelöschtes per ID) | S |

## 6. Oberfläche

| Action | Parameter | Art |
|---|---|---|
| `projects.studio.open` | `project`, `tab: seite\|aufgaben`, `task?` (öffnet die Karte im Board) | L |
| `projects.studio.close` | – | L |

---

## 7. Nicht gebaut (E3 Teil B)

Rezepte, Abstammung („veraltet“) und der Projektrahmen für Agenten aus Epic E3, Teil B, brauchen die Aufträge aus E1 und sind nicht Teil dieses Schritts.
