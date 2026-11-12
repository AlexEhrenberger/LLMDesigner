---
title: Speicherformate
mermaid: true
---

# Speicherformate

[← Übersicht](index.md) · [Funktionsweise](funktionen.md) · [Architektur](architektur.md) · [Code-Führer](code.md)

## Aufbau einer Bibliothek

Eine Bibliothek ist ein Ordner-Paket `Name.llmdlibrary` (im Finder ein einzelnes Objekt, Doppelklick öffnet es in LLM Designer). Alle Pfade darin sind relativ – die Bibliothek lässt sich frei verschieben.

```mermaid
flowchart LR
    L[("Name.llmdlibrary")] --> B["Bibliothek.json<br/>Kennung, Format"]
    L --> E["Einstellungen.plist<br/>Endpoint, Modell, Prompt …"]
    L --> CH["Chats/<br/>ein JSON pro Chat"]
    L --> CF["ChatFolders.json<br/>Ordner und Unterordner"]
    L --> ST["SidebarStacks.json<br/>Stapel, Öffnungstage"]
    L --> SK["Skills.json"]
    L --> D["Documents/"]
    D --> DM["‹id›.md<br/>Dokumente und Präsentationen"]
    D --> BI["Bilder/<br/>Bilder, Plots, Zeichnungen, Diagramme"]
    D --> IA["Inhaltsanalysen/"]
    L --> PE["Personas/‹id›/<br/>persona.json, Bild, files/, thalamus.json"]
    L --> AT["Attachments/<br/>Bilder aus Chats"]
    L --> Z["Zitate/"]
    Z --> ZQ["Quellen/‹id›.json<br/>Quelle mit Zitaten"]
    Z --> ZA["Anhänge/‹id›/"]
    Z --> ZO["Ordner.json"]
    L --> G["Geschichten/"]
    G --> GW["‹id›.json<br/>eine Romanwelt"]
    G --> GB["Bilder/‹id›/"]
    L --> N["Notizen/<br/>‹id›.json: ein Note"]
    L --> PJ["Projekte/<br/>‹id›.json: ein Projekt"]
    L --> PD["Präsentationen/Designs/<br/>eigene CSS-Designs"]
```

`ChatFolders.json` ist eine Liste von Ordnern (`id`, `name`, `color`, `isCollapsed`). Ein Unterordner hat `parentID`, die ID eines Ordners der obersten Ebene; tiefer geht es nicht. Fehlt der Eltern-Ordner, steht der Unterordner oben.

`SidebarStacks.json` gehört zum automatischen Stapeln (Einstellung `sidebarArrangement` = `date` oder `stacks`, `sidebarStackMode` = `topics`, `types` oder `relevance`): `topics` sind die Themenstapel des Modells (`id`, `name`, `itemIDs`), `tidiedAt` das letzte Aufräumen, `expanded` die offenen Stapel, `activity` je Chat oder Dokument die Tage (`yyyy-MM-dd`), an denen es geöffnet wurde, höchstens 60 Tage zurück. Inhalte stehen darin nicht.

Außerhalb der Bibliotheken merkt sich die App nur die Liste der zuletzt geöffneten Bibliotheken (Pfad + Bookmark) in ihren Voreinstellungen.

## Dokumente

Jedes Dokument ist eine Markdown-Datei mit kurzem Kopf:

```markdown
---
id: 3BC48041-12EC-4B73-87B7-BAA02A0AC3A3
title: Der Wasserkreislauf
customTitle: true
created: 2026-10-30T08:10:00Z
updated: 2026-10-30T08:12:00Z
font: serif
format: taschenbuch
---

# Der Wasserkreislauf

Text mit **fett**, <u>unterstrichen</u>, H<sub>2</sub>O und [@muster2020, S. 12].
```

Writer erweitert Markdown Pandoc-kompatibel:

| Element | Markdown |
|---|---|
| Kapitel | `# Titel {.chapter}` |
| Ausrichtung | `::: {.center}` … `:::` |
| Kasten | `::: {.box kind=merksatz position=right width=40 wrap=true}` … `:::` |
| Zwei Spalten | `::: {.columns count=2 gap=1cm rule=true}` … `\columnbreak` … `:::` |
| Hoch-/tiefgestellt | `<sup>…</sup>`, `<sub>…</sub>` |
| Farbe, Schrift, Größe | `<span style="color:#…; font-size:14pt">…</span>` |
| Lesezeichen | `<span id="lz-…" title="…">…</span>` |
| Kommentar | `<span class="comment" data-comment="k-…" data-thread="…">…</span>` |
| Bild, Plot, Abbildung | `![Unterschrift](Bilder/x.png){width=50%}`, `{.plot …}`, `{.chart}`, `{.drawing}`, `{.mermaid}` |
| Tabelle mit Formeln | Tabelle in `::: {#tab-… calc-3-1="SUMME(B2:B3)"}`; Spaltenbreiten als Anzahl der Striche |
| Zitation | `[@schluessel, S. 12]`, Literaturverzeichnis `[Literatur]` |
| Fußnote | `^[Text der Fußnote]` (Pandoc-Inline-Fußnote, Text als Inline-Markdown; nummeriert in der Reihenfolge im Text) |
| Inhaltsverzeichnis | `[TOC]` oder `[TOC]{.dynamic}` |
| Seitenumbruch | `\newpage` |

### Herkunft

Der Kopf eines Dokuments kann `herkunft: fremd` oder `herkunft: intern` tragen. Fehlt das Feld, gilt der Text als eigener; so bleiben alle älteren Dokumente, wie sie sind. Skills haben dasselbe als optionales Feld `provenance`. Chats speichern ihre zugeschalteten Werkzeuggruppen in `actionGroups` und die Freigabestufe in `actionApproval`. In den Einstellungen der Bibliothek liegen `actionApprovalLevels` und `actionExportFolder`. Siehe [Action-Schicht](actions.md).

## Präsentationen

Eine Präsentation ist ein Dokument mit `kind: presentation` und den Hintergründen im Kopf. Jede Folie beginnt mit einer Kommentarzeile, die ihre Metadaten als JSON trägt; die Moderatorenkarte folgt als eigener Kommentar. Andere Markdown-Programme zeigen nur den Text.

```markdown
---
id: 422A2BDC-…
title: Wetter
kind: presentation
backgrounds: {"folie":{"kind":"design","design":"seide"}}
---

<!-- folie {"id":"…","rolle":"titel"} -->

# Wetter und Klima {.chapter}

<!-- folie {"id":"…","rolle":"folie","textbereich":{"x":0.1,"y":0.08,"b":0.5,"h":0.8},"bilder":[
  {"id":"…","quelle":"Bilder/wolke.png","x":0.6,"y":0.2,"b":0.3,"h":0.4},
  {"id":"…","inhalt":"**Merksatz**\n\nWasser geht nicht verloren.","kasten":"merksatz","x":0.55,"y":0.55,"b":0.38,"h":0.28,"lage":"vorne"}
]} -->

# Wolken

- Entstehen durch Abkühlung

<!-- moderation
Was der Vortragende sagt.
-->
```

| Schlüssel | Bedeutung |
|---|---|
| `rolle` | `titel`, `kapitel`, `folie` |
| `hintergrund` | eigener Hintergrund der Folie (Design, Farbe, Verlauf, Bild) |
| `textbereich` | Rahmen des Folientexts in Anteilen der Folie; fehlt er, gelten die Standardränder |
| `bilder` | freie Elemente, das letzte liegt oben |
| `quelle` | Bild: Pfad in der Bibliothek |
| `inhalt` | Textfeld: Writer-Markdown (Text, Tabelle, Code, Abbildung …) |
| `kasten`, `rahmen` | Textfeld als Kasten: Art (`definition`, `merksatz`, `beispiel`, `hinweis`, `achtung`, `eigener`) und Rahmen (`bar`, `outline`, `filled`) |
| `x`, `y`, `b`, `h` | Rahmen in Anteilen der Folienbreite/-höhe (Ursprung oben links) |
| `lage` | `umfliessen` (Vorgabe), `vorne`, `hinten` |


Zusätzliche Felder (seit 2026-11-07, alle optional): Eine Folie trägt `"ohnePlatzhalter": true`, wenn ihr Hinweis („Folientitel“) ausgeblendet ist. Ein Bild in `bilder` kann `zuschnitt` (`{"left","top","right","bottom"}`, Anteile, die je Seite wegfallen; die Datei bleibt ganz), `rand` (Breite in Punkten der 720-pt-Folie), `randfarbe` (Hex, z. B. `"FFFFFF"`) und `schatten` (`true`) haben.

## Zitate

`Zitate/Quellen/<id>.json` enthält eine Quelle mit ihren Wissensbausteinen:

```json
{
  "format": 1,
  "source": {
    "id": "…", "citekey": "muster2020", "type": "book",
    "title": "Grundlagen der Meteorologie",
    "authors": [{"family": "Muster", "given": "Erika"}],
    "year": 2020, "publisher": "Testverlag", "place": "Berlin"
  },
  "quotes": [
    {"id": "…", "sourceID": "…", "exactText": "Wolken sind …", "page": "12", "tags": ["Wolken"]}
  ]
}
```

## Romanwelten

`Geschichten/<id>.json` enthält eine ganze Welt als `{"format": 1, "world": {…}}`: Titel, Kalender, Zeitleiste, Bücher mit Akten/Kapiteln/Abschnitten und die Listen `figures`, `places`, `events`, `reasons`, `purposes`, `species`, `facts` sowie `gallery` (Bilder mit `caption`; jedes Buch, jeder Akt, jedes Kapitel und jeder Abschnitt hat ebenfalls eine `gallery`). Welt und Teile haben `linkedDocuments`: IDs von Writer-Dokumenten und Präsentationen, die dazugehören („Dazugehörige Dokumente“); die Dokumente bleiben in ihren Ordnern. Verweise zwischen Elementen sind IDs innerhalb derselben Datei. Ein Teil kann mit `manuscriptID` auf das Writer-Dokument mit seinem Text zeigen; die Welt enthält den Plan, das Dokument den Text. Bilder liegen in `Geschichten/Bilder/<id>/`, die Videocards der Figuren (`videos`) in `Geschichten/Videos/<id>/`. Unbekannte oder fehlende Felder werden beim Lesen übergangen.

## Notes

`Notizen/<id>.json` enthält ein Note als `{"format": 1, "note": {…}}`. Die Schlüssel sind deutsch; leere Felder (`text`, `gehoertZu`, `zu`, `dokumente`, `unter`) werden nicht geschrieben.

```json
{
  "format": 1,
  "note": {
    "id": "…",
    "titel": "Bachelorarbeit",
    "anzeige": "glas",
    "text": "Abgabe am 20.11.",
    "gehoertZu": [
      {"art": "dokument", "id": "…"},
      {"art": "romanwelt", "welt": "…", "teil": "…"}
    ],
    "todos": [
      {"id": "…", "text": "Konzept ausarbeiten", "erledigt": false, "dokumente": ["…"],
       "unter": [{"id": "…", "text": "Gliederung", "erledigt": true}]},
      {"id": "…", "text": "Literatur", "erledigt": false, "zu": true, "unter": [ … ]}
    ],
    "erstellt": "2026-11-11T09:00:00Z",
    "geaendert": "2026-11-11T09:30:00Z"
  }
}
```

| Schlüssel | Bedeutung |
|---|---|
| `anzeige` | Fortschrittsanzeige: `balken`, `ringe`, `glas`, `pflanze`, `rakete`, `gipfel`, `akku`, `mond`, `pizza`, `schnecke`, `tacho`, `pixel`; Unbekanntes wird `balken` |
| `gehoertZu` | Zugehörigkeiten: `dokument` (Writer-Dokument oder Präsentation) mit `id`; `romanwelt` mit `welt` und optional `teil` (ohne: die ganze Welt). Unbekannte Arten werden beim Lesen übergangen |
| `todos`, `unter` | ToDos und ihre Unter-ToDos, beliebig tief |
| `erledigt` | ein ToDo mit Unter-ToDos ist erledigt, wenn alle erledigt sind; die App gleicht das beim Ändern an |
| `zu` | Unter-ToDos eingeklappt |
| `dokumente` | IDs verknüpfter Writer-Dokumente und Präsentationen; die Dokumente bleiben in ihren Ordnern |

Die Dokumente, Präsentationen und Romanwelten selbst ändern sich durch eine Zuordnung nicht. Ein gelöschtes Note kommt in den Papierkorb. Die zuletzt gewählte Anzeige (`notesDefaultStyle`) und das zuletzt offene Note (`notesLastNote`) stehen in den Einstellungen der Bibliothek.

## Projekte

`Projekte/<id>.json` enthält ein Projekt als `{"format": 1, "projekt": {…}}`: Seite, Aufgaben-Board, ToDo-Listen, Meilensteine, Verknüpfungen und Verlauf in einer Datei. Die Schlüssel sind deutsch; Tage stehen als `"2026-11-20"` (Kalender des Macs). Alles wird nachsichtig gelesen: Unbekanntes oder Fehlendes behält seinen Standard, ein Baustein unbekannter Art fällt weg, eine Aufgabe ohne bekannte Spalte kommt in die erste, ein Projekt ohne Spalten bekommt die fünf Standardspalten.

```json
{
  "format": 1,
  "projekt": {
    "id": "…", "titel": "Hausarbeit Statistik", "untertitel": "Regression an offenen Daten",
    "symbol": "graduationcap", "farbe": "teal", "status": "laeuft",
    "gestaltung": {"schrift": "georgia", "akzent": "pink", "hintergrund": "papier"},
    "bausteine": [
      {"id": "…", "art": "text", "x": 0, "y": 0, "b": 8, "h": 2, "text": "Ziel …",
       "stil": {"schrift": "didot", "groesse": 22, "farbe": "blue", "fett": true, "kursiv": true, "ausrichtung": "mitte"}},
      {"id": "…", "art": "fortschritt", "x": 8, "y": 0, "b": 4, "h": 4, "anzeige": "reise", "quelle": "alles"},
      {"id": "…", "art": "todos", "x": 0, "y": 4, "b": 6, "h": 5, "liste": "…"},
      {"id": "…", "art": "diagramm", "x": 0, "y": 9, "b": 12, "h": 5,
       "diagramm": {"art": "gantt", "quelle": "manuell", "werte": [{"id": "…", "titel": "Lesen", "wert": 1, "start": "2026-11-12", "ende": "2026-11-18"}]}},
      {"id": "…", "art": "haftnotiz", "x": 0, "y": 14, "b": 3, "h": 4, "text": "…", "farbe": "yellow"}
    ],
    "verknuepft": [
      {"art": "dokument", "id": "…"}, {"art": "chat", "id": "…"}, {"art": "note", "id": "…"},
      {"art": "romanwelt", "id": "…", "teil": "…"}, {"art": "romanwelt", "id": "…", "element": {"art": "figure", "id": "…"}}
    ],
    "todoListen": [{"id": "…", "titel": "Nächste Schritte", "todos": [{"id": "…", "text": "Mail ans Institut", "erledigt": false, "faellig": "2026-11-15", "verweis": {"art": "dokument", "id": "…"}}]}],
    "meilensteine": [{"id": "…", "titel": "Abgabe", "datum": "2026-11-20", "erledigt": false, "farbe": "red"}],
    "spalten": [{"id": "…", "titel": "Offen", "farbe": "blue"}, {"id": "…", "titel": "In Arbeit", "limit": 3}, {"id": "…", "titel": "Erledigt", "fertig": true}],
    "aufgaben": [
      {"id": "…", "titel": "Kapitel 3", "beschreibung": "…", "spalte": "…", "prioritaet": "hoch", "start": "2026-11-12", "faellig": "2026-11-15",
       "etiketten": ["Schreiben"],
       "akzeptanz": [{"id": "…", "text": "Quellen geprüft", "erfuellt": true}],
       "hindernisse": [{"id": "…", "text": "Daten fehlen", "loesung": "Beim Institut anfragen", "behoben": false}],
       "verweise": [{"art": "dokument", "id": "…"}],
       "erstellt": "…", "geaendert": "…"}
    ],
    "verlauf": [{"tag": "2026-11-12", "offen": 8, "erledigt": 12}],
    "erstellt": "2026-11-12T09:00:00Z", "geaendert": "2026-11-12T09:30:00Z"
  }
}
```

| Schlüssel | Bedeutung |
|---|---|
| `status` | `geplant`, `laeuft`, `pausiert`, `fertig` |
| `farbe`, `akzent`, Farben überall | die Ordnerfarben: `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`, `pink` |
| `gestaltung` | Schrift der Seite (Writer-Schriften, z. B. `georgia`, `didot`, `sans`), Akzent (ohne: Farbe des Projekts), Hintergrund `standard`, `papier`, `verlauf`, `punkte`, `blaupause` |
| `bausteine` | Platz im Raster mit 12 Spalten: `x` (Spalte 0–11), `y` (Zeile), `b` (Breite in Spalten), `h` (Höhe in Zeilen). Arten: `text`, `fortschritt`, `todos`, `meilensteine`, `diagramm`, `verknuepfungen`, `kennzahl`, `countdown`, `haftnotiz`, `hindernisse`, `board` |
| `stil` | nur, was vom Standard abweicht: `schrift`, `groesse` (8–96), `farbe`, `fett`, `kursiv`, `ausrichtung` (`links`, `mitte`, `rechts`) |
| `anzeige` | Fortschrittsanzeige: die zwölf von Notes und `reise`, `sternbild`, `sanduhr`, `skyline` |
| `quelle` | was Fortschritt oder Kennzahl zählt: `aufgaben`, `akzeptanz`, `todos`, `meilensteine`, `alles`; Kennzahlen auch `offeneAufgaben`, `hindernisse`, `verknuepfungen`, `restTage`, `manuell` (mit `wert` und `text`) |
| `liste`, `datum` | die ToDo-Liste eines ToDo-Bausteins; der Tag eines Countdowns (ohne: der nächste offene Meilenstein) |
| `diagramm` | `art`: `gantt`, `kreis`, `balken`, `verlauf`, `ablauf`; `quelle`: `aufgaben`, `meilensteine`, `spalten`, `prioritaet`, `etiketten`, `todos`, `verlauf`, `manuell`; `werte` nur bei eigenen Werten (`titel`, `wert`, `farbe`, `start`, `ende`, `erledigt`, `form`: `schritt`, `entscheidung`, `start`) |
| `verknuepft`, `verweise`, `verweis` | Chats, Dokumente/Präsentationen, Notes, Romanwelten mit optionalem `teil` oder `element`. Das Verknüpfte bleibt, wo es ist; ein gelöschtes hinterlässt einen Hinweis statt eines Fehlers |
| `spalten` | eigene Spalten des Boards; `fertig`: Aufgaben darin gelten als erledigt; `limit`: WIP-Grenze |
| `aufgaben` | in Board-Reihenfolge; `prioritaet`: `niedrig`, `mittel`, `hoch`, `dringend`; `akzeptanz`: woran man die Abnahme erkennt; `hindernisse` mit `loesung` |
| `verlauf` | ein Eintrag je Tag, an dem sich etwas geändert hat: offene und erledigte Aufgaben und ToDos zusammen, nie Text; höchstens 400 Tage |

Ein gelöschtes Projekt kommt in den Papierkorb. Ob die Kategorie „Projekte“ in der Seitenleiste eingeklappt ist (`projectsSectionCollapsed`), steht in den Einstellungen der Bibliothek.
