---
title: Action-Schicht
mermaid: true
---

# Action-Schicht: Terminal, MCP, Chat-Werkzeuge

[← Übersicht](index.md) · [Funktionsweise](funktionen.md) · [Architektur](architektur.md) · [Code-Führer](code.md) · [Speicherformate](speicherformate.md)

Was die App kann, ist als **Action** erreichbar: aus dem Terminal (`llmd`), über MCP und aus dem eigenen Chat. Alle Wege laufen durch dieselbe Registry und dieselben Sicherheitsregeln.

```mermaid
flowchart LR
    CLI["llmd (Terminal)"] -->|"Unix-Socket, JSON-RPC"| SRV["ActionServer"]
    MCP["MCP-Client"] -->|stdio| AD["llmd mcp<br/>MCPAdapter"] -->|"Unix-Socket"| SRV
    CHAT["Chat mit Werkzeugen<br/>ChatActionTools"] --> REG
    SRV --> REG["ActionRegistry<br/>Schema, Regel, Undo, Protokoll"]
    REG --> POL["ActionPolicy<br/>Rule of Two"]
    REG --> APP["ActionApproval<br/>Dialog"]
    REG --> ACT["Actions<br/>Writer, Presenter, Citation, Stories, Chat"]
    ACT --> AM["AppModel und Bibliothek"]
```

## Terminal

Das Werkzeug liegt in der App unter `Contents/Helpers/llmd`. Die Einstellungen legen unter „Terminal und Agenten“ einen Link nach `~/.local/bin` an.

```bash
llmd status
llmd actions --module writer
llmd describe writer.format.bold
```

Befehle entstehen aus den Schemas: Punkte werden Wörter, `camelCase` wird `--kebab-case`, Pflichtparameter dürfen ohne Namen stehen.

```bash
llmd writer text insert-markdown --doc Bericht --markdown "# Titel"
llmd writer format bold --doc Bericht --match "Wort" --state on
llmd writer export --doc Bericht --format pdf
cat kapitel.md | llmd writer text insert-markdown --doc Bericht --stdin
llmd batch < schritte.jsonl
llmd watch
llmd completion zsh > "${fpath[1]}/_llmd"
```

Optionen: `--json`, `--quiet`, `--stdin`, `--stdin-to NAME`, `--no-launch`, `--run ID`. Läuft die App nicht, startet `llmd` sie. Exit-Codes: 0 Erfolg, 1 Fehler, 2 falscher Aufruf, 3 App nicht erreichbar, 4 verweigert, 5 nicht gefunden oder mehrdeutig, 6 Versionskonflikt.

Beispielskripte: [`docs/plan/beispiele/`](https://github.com/AlexEhrenberger/LLMDesigner/tree/main/docs/plan/beispiele).

## Adressen

Writer-Actions arbeiten auf dem Markdown, auch wenn das Dokument nicht offen ist. Nur der betroffene Block wird umgewandelt; alles andere bleibt, wie es geschrieben ist.

| Adresse | Bedeutung |
|---|---|
| `--match "Text" [--occurrence 2]` | eine Fundstelle; bei mehreren Treffern ohne `occurrence` ein Fehler |
| `--block b3-ab12cd` | ein Block aus `writer.blocks.list`; die ID veraltet, wenn sich der Block ändert |
| `--heading "Kapitel 2/Einleitung"` | eine Überschrift über ihren Pfad |
| `--range 120:15` | Zeichenbereich im Markdown |
| `--all` | der ganze Text |

Tabellen, Kästen, Spalten, Bilder, Formeln und Code-Blöcke haben eigene Parameter (`--table`, `--box`, `--section`, `--image`, `--formula`, `--plot`, `--code-block`): eine Nummer im Text ab 1 oder eine Block-ID, ohne Angabe das einzige Objekt dieser Art. Zellen heißen wie in Formeln: `A1` ist links oben, Zeile 1 die Kopfzeile. Bilder und Kästen werden auch in Kästen und Spaltenabschnitten gefunden; Tabellen und Code-Blöcke nur als eigener Block.

`--doc` nimmt ID oder Titel. `--deck` mit `--slide` oder `--slide-index` (und `--field`, `--notes`) wendet dieselben Actions auf Folien an. Lesen liefert eine `version`; Schreiben nimmt sie als `--if-version` und bricht bei fremden Änderungen ab.

## Sicherheit

Die Regeln stehen im [Sicherheitskonzept](plan/Sicherheitskonzept-Prompt-Injection.md) und im Code (`ActionPolicy`), nicht im Prompt. Ein **Lauf** merkt sich, ob er Fremdes (A) oder Sensibles (B) gelesen hat. Jede Action erklärt, was sie liest und bewirkt (C).

```mermaid
flowchart TB
    S["Action soll laufen"] --> U{"Kanal Oberfläche?"}
    U -->|ja| OK["erlauben"]
    U -->|nein| M{"MCP und sensibel?"}
    M -->|ja| NO["verweigern"]
    M -->|nein| T{"A und B und C?"}
    T -->|ja| ASK["Mensch fragen"]
    T -->|nein| O{"nach außen, und A oder B?<br/>zerstört, und A?<br/>sensibel, und A?"}
    O -->|ja| ASK
    O -->|nein| L["Stufe aus den Einstellungen"]
```

- **Herkunft:** Dokumente tragen `herkunft: fremd` im Kopf, wenn sie von außen kommen. Was ein markierter Lauf schreibt, wird ebenfalls fremd. „Als geprüft bestätigen“ fragt immer, einzeln.
- **Socket:** nur für den eigenen Benutzer (Ordner 0700, Socket 0600), Peer-UID-Prüfung, neues Token je Start. Kein Netzwerkport.
- **Export:** ohne Rückfrage nur in den Exportordner, und nur wenn der Lauf nichts Fremdes gelesen hat.
- **Web-Ansichten:** laden nichts aus dem Netz (`WKContentRuleList`).
- **Protokoll:** Fenster → „Aktivität von Terminal und Agenten“ zeigt Zeit, Kanal, Lauf, Action, A/B, Entscheidung und Ergebnis, aber keine Inhalte.

## MCP

`llmd mcp` ist ein stdio-Server nach Spezifikation 2026-07-28 und versteht auch das ältere `initialize`.

```bash
claude mcp add llmd -- "/Pfad/LLM Designer.app/Contents/Helpers/llmd" mcp --profile core
```

| Profil | Inhalt |
|---|---|
| `core` | der kleine Satz zum Lesen, Schreiben, Präsentieren, Zitieren und Fragen |
| `writer`, `presenter`, `citation`, `stories`, `chat` | ein Studio |
| `full` | alles außer privaten Daten |

Jedes Profil hat zusätzlich `llmd_search_actions` und `llmd_run_action`, damit kleine Modelle nicht alle Tools laden müssen. Dazu kommen Resources (`llmd://writer/doc/{id}`, `llmd://presenter/deck/{id}`, `llmd://citation/source/{key}`, `llmd://stories/world/{id}`), Prompts aus Skills und `subscriptions/listen`.

Der Kanal gilt immer als fremd. `memory.*` und `persona.files.*` sind gesperrt, Chats mit privaten Dateien ebenso. Eine Runde, die von hier ausgeht, läuft in einem Chat ohne dessen Werkzeuge.

## Werkzeuge im Chat

Der Blitz im Eingabefeld schaltet Gruppen zu (Writer, Presenter, Citation, Stories, andere Chats, Gedächtnis) und stellt ein, wie viel ohne Rückfrage geht. Jede Gruppe enthält nur den Minimalsatz, weil ihre Schemas bei jeder Frage den Kontext belegen. Jeder Schritt erscheint in der Antwort, und der Pfeil unter der Antwort nimmt alle ihre Änderungen zurück, solange die App läuft.

Fremde Ergebnisse kommen in einem Rahmen mit zufälliger Kennung zum Modell. Das hilft dem Modell, schützt aber nicht: Geschützt wird durch die Registry. Ein Chat kann sich keine Nachrichten schicken und seine eigenen Freigaben nicht ändern.

## Eine Action hinzufügen

```swift
struct WriterDocStatsAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "writer.doc.stats", summary: "Zählt Wörter", kind: .read, security: .plainRead,
        input: .object(["doc": .string("Dokument")], required: ["doc"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output { … }
}
```

Sie wird in `register…Actions()` eingetragen und bekommt einen Test über die Registry. `kind` und `security` haben absichtlich keine Vorgaben. Liest sie je nach Ziel Fremdes oder Privates, sagt das `preflight`.
