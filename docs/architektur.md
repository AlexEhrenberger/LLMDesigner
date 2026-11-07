---
title: Architektur
mermaid: true
---

# Architektur

[← Übersicht](index.md) · [Funktionsweise](funktionen.md) · [Code-Führer](code.md) · [Speicherformate](speicherformate.md)

## Schichten

LLM Designer ist eine einzige ausführbare SwiftPM-Zielgruppe (`LLMDesigner`) plus die mitgelieferte Bibliothek **SwiftMath** (Formelsatz). Der Code ist in drei Schichten geteilt:

```mermaid
flowchart TB
    subgraph App["App/ – Start und Fenster"]
        LA["LLMDesignerApp<br/>Menüs, Tastenkürzel"]
        LS["LibrarySession<br/>offene Bibliothek, Wechsel"]
        WC["WindowConfigurator<br/>Titelleiste, Fenstermaße"]
    end
    subgraph UI["UI/ – SwiftUI + AppKit"]
        RV["RootView"]
        CS["ChatScreen"]
        WS["Writer/"]
        PS["Presenter/"]
        CI["Citations/"]
        ST["Stories/"]
        PW["Power/"]
    end
    subgraph Core["Core/ – Modell, Logik, Dienste"]
        AM["AppModel (+ Erweiterungen)"]
        DOC["WriterDocument · PresentationDeck"]
        CL["CitationLibrary"]
        SL["StoryLibrary"]
        TH["Thalamus"]
        LLM["LLMClient"]
        SP["Speech/"]
        MA["Math/ · Code/"]
        STO["Stores: ChatStore, WriterDocumentStore …"]
    end
    LIB[("AppLibrary<br/>*.llmdlibrary")]
    LA --> LS --> AM
    RV --> CS & WS & PS & CI & ST & PW
    UI --> AM
    AM --> DOC & CL & SL & TH & LLM & SP & MA
    STO --> LIB
    AM --> STO
```

- **`AppModel`** (`@Observable`, auf dem Main Actor) ist der zentrale Zustand: Chats, Dokumente, Auswahl, Verbindungen, laufende Aufgaben. Er ist in viele Dateien `AppModel+….swift` aufgeteilt – je eine pro Bereich (Writer, Presenter, Personas, Thalamus, Speech, Power …).
- **`LibrarySession`** hält die geöffnete `AppLibrary` und baut beim Bibliothekswechsel einen neuen `AppModel`. Nichts Globales überlebt den Wechsel, außer der Liste der zuletzt geöffneten Bibliotheken.
- Die **Studios** haben eigene Bibliotheken/Modelle: `CitationLibrary` (Quellen, Zitate, Ordner) und `StoryLibrary` (Romanwelten), beide `@Observable`, lazy geladen, mit verzögertem Speichern (500 ms). `StoryLibrary` hält getippten Text als Entwurf und übernimmt ihn nach 350 ms Pause; geschrieben wird auf einer eigenen Queue. Die Formularfelder des Stories Studio sind `StoryTextEditor` (AppKit-`NSTextView`) statt `TextField(axis: .vertical)`: Sie melden SwiftUI nur eine neue Höhe, nicht jeden Tastendruck – sonst richtete SwiftUI bei jeder Taste das ganze Fenster neu aus. Tab-Leisten (`StoryTabBar`) wählen ihre Kurzform rechnerisch aus der gemessenen Breite statt mit `ViewThatFits` und liegen nie in einer ScrollView.
- **UI-Ansichten** lesen den `AppModel` über die SwiftUI-Umgebung (`@Environment(AppModel.self)`).

## Darstellung: SwiftUI außen, AppKit innen

```mermaid
flowchart LR
    SUI["SwiftUI-Ansichten<br/>Layout, Leisten, Panels, Sheets"] --> REP["NSViewRepresentable"]
    REP --> WTV["WriterTextView<br/>(NSTextView, TextKit 1)"]
    REP --> WEB["WKWebView<br/>Mermaid, Folien-Designs"]
    REP --> POP["NSPopover / Drag-Quellen"]
    WTV --> STY["WriterStyler<br/>Markdown ⇄ Attribute"]
    WTV --> LM["WriterLayoutManager<br/>Spalten, Kästen, Umfluss"]
```

- Der Texteditor ist ein eigenes **`NSTextView` mit TextKit 1** (`WriterTextView`, verteilt auf `WriterTextView+….swift`). Er wandelt Markdown in Attribute (`WriterMarkdown.attributedString`) und zurück (`WriterMarkdown.markdown`). Tabellen sind echte `NSTextTable`-Zellen; Bilder, Formeln, Zitationen und das Inhaltsverzeichnis sind `NSTextAttachment`s.
- Spalten, schwebende Kästen und Textumfluss entstehen in `WriterTextContainer.lineFragmentRect` und dem Layout-Manager-Delegate (TextKit 1 kennt dafür keine fertige Lösung).
- **Folien** benutzen denselben Editor auf einer festen Leinwand von 720 × 405 pt (`WriterTextView.SlideLayout`), die ein `SlideScrollView` auf den verfügbaren Platz vergrößert. So sehen Editor, Miniaturen, Präsentation und PDF identisch aus. Ein `SlideLayout` hat eine eigene Leinwandgröße und einen Textrahmen – dadurch funktionieren auch **freie Textfelder** (eigene kleine Leinwand) und der verschiebbare Textbereich.
- Mermaid-Diagramme und die CSS-Folien-Designs laufen in **`WKWebView`s** (offline, `mermaid.min.js` liegt im App-Bundle).

### Freie Elemente auf Folien

```mermaid
classDiagram
    class PresentationDeck {
        slides: [PresentationSlide]
        backgrounds: RoleBackgrounds
        serialized: String
        parse(body) PresentationDeck
    }
    class PresentationSlide {
        id, role, markdown, notes
        background: SlideBackground?
        images: [SlideImage]
        textArea: SlideArea?
        textFrame: CGRect
        fullMarkdown: String
    }
    class SlideImage {
        source (Bild) | text (Textfeld)
        box: WriterBoxKind?
        boxFrame
        x, y, width, height (Anteile)
        placement: umfliessen | vorne | hinten
    }
    class SlideArea {
        x, y, width, height (Anteile)
    }
    PresentationDeck "1" --> "*" PresentationSlide
    PresentationSlide "1" --> "*" SlideImage
    PresentationSlide --> SlideArea
```

Beim Bearbeiten eines Textfelds bleibt es **ein** `WriterEditor` mit **einem** `WriterEditorController`: Der Editor bekommt als Inhalt das Feld (`WriterSlideContent(id: Feld, slideID: Folie)`), wird an die Position des Felds gelegt, und der Text der Folie wird solange statisch gezeichnet. Dadurch wirken Werkzeugleiste, KI-Leiste, Diktat und Zitate unverändert im Feld. Änderungen meldet der Editor wie gewohnt über `AppModel.updateSlide`, das Feld-IDs erkennt.

## Datenfluss beim Schreiben

```mermaid
sequenceDiagram
    participant TV as WriterTextView
    participant ED as WriterEditor.Coordinator
    participant AM as AppModel
    participant DS as WriterDocumentStore
    TV->>ED: textDidChange
    ED->>ED: 350 ms warten
    ED->>AM: updateDocument / updateSlide (Markdown)
    AM->>AM: Titel ableiten, documents[i] ändern
    AM->>DS: speichern nach 500–700 ms
    Note over AM,TV: Änderung von anderswo (KI, Power-Zugriff, Undo im Panel)
    AM-->>ED: neues Markdown im Modell
    ED->>TV: neu laden (Scroll-Position und Schreibmarke bleiben), falls keine eigenen Änderungen offen
```

## Sprachmodelle

```mermaid
flowchart LR
    AM["AppModel"] --> LC["LLMClient<br/>(Provider: lmStudio | kapitsa)"]
    LC -->|"GET /api/v0/models"| M["Modelle + Ladezustand"]
    LC -->|"POST /v1/chat/completions<br/>stream, tools, response_format"| CC["Antworten"]
    LC -->|"/api/v1/models/load"| LD["Kontextlänge setzen"]
    CC --> TH["Thalamus: Eindruck, Verdichtung"]
    CC --> WA["WriterAssistant: Schreiben, Prüfen"]
    CC --> PG["Presenter: Gliederung, Folien, Karten"]
    CC --> CA["Inhaltsanalyse (JSON-Schema)"]
```

- Strukturierte Antworten laufen über **JSON-Schema mit fester Reihenfolge** (`complete(orderedSchema:)`), weil kleine Modelle in der Reihenfolge der Eigenschaften schreiben.
- Diagramme der Inhaltsanalyse baut die App selbst aus JSON – das Modell schreibt nie Mermaid-Code für sie, damit die Diagramme immer gültig sind. (Nur das Mermaid-Werkzeug in Writer lässt Qwen Mermaid schreiben, mit Syntax-Beispiel und Reparaturrunden.)
- Eigenheit von LM Studio: Ein unbekannter Modellname fällt still auf das geladene Modell zurück. Die App vertraut deshalb dem `model`-Feld im Stream.
- **Der Anfang einer Anfrage bleibt gleich.** Kapitsa und LM Studio heben den Anfang eines Prompts auf (Präfix-Cache) und lesen nur Neues. Ändert sich im System-Prompt ein einziges Zeichen, liest Kapitsa den ganzen Chat neu (gemessen: 11 s statt 0,3 s bei 2 200 Token). Darum steht im System-Prompt nur, was für den ganzen Chat gilt (Datum ohne Uhrzeit, Erinnerungen nach Kalendertagen); was zu einer Runde gehört (Erinnerungen der Runde, Hinweis für gesprochene Antworten), kommt gerahmt vor die neueste Nachricht (`ChatPayloadBuilder`). Anfragen gehen mit sortierten Schlüsseln hinaus, weil Swift die Reihenfolge sonst bei jedem Start neu würfelt. Unter jeder Antwort steht, wie viele Token aus dem Cache kamen; `PromptPrefixTests` hält die Regel fest.

## Action-Schicht

Terminal, MCP und Chat erreichen die App über dieselbe Registry, die Parameter prüft, die Sicherheitsregel anwendet und Undo-Gruppen und Protokoll führt. Details: [Action-Schicht](actions.md).

## Weitere lokale Dienste

| Dienst | Wofür | Anbindung |
|---|---|---|
| Draw Things | Bilder, Folien-Hintergründe | HTTP `:7860` (`/sdapi/v1/txt2img`), `ImageGenerationCenter` (eine Aufgabe nach der anderen) |
| Qwen TTS | Vorlesen, Gesprächsmodus | `QwenTTSClient`, in kurzen Stücken |
| Apple Speech | Diktat | `DictationEngine` (SpeechTranscriber) |
| Tectonic | PDF-Satz von Dokumenten | `LaTeXExport` → `tectonic` |
| Python + matplotlib | Plots, Diagramme aus Tabellen | `MathPlotRenderer`, `Agg`-Backend |
| Crossref, DNB, Open Library, Google Books, arXiv | Quellen importieren | `CitationLookup` |

## Nebenläufigkeit

- UI und Modell laufen auf dem **Main Actor**. Netzwerk und Prozesse (Python, Tectonic) laufen in `Task`s; Ergebnisse kommen auf den Main Actor zurück.
- Streams werden pro Chat verfolgt (`streamingMessageIDs`), damit mehrere Chats gleichzeitig antworten können.
- Lange Modellaufgaben (Gedächtnis-Verdichtung, Gliederung, Moderatorenkarten) weichen, sobald der Nutzer schreibt.

## Power-Zugriff

```mermaid
flowchart TB
    PA["PowerAccess (@Observable)<br/>isOn, module, query, offene Elemente, lastChange"]
    PP["PowerPanel"] --> PA
    PP --> MOD["PowerChats · PowerDocuments · PowerPresentations<br/>PowerCitations · PowerStories"]
    MOD --> PT["PowerText<br/>Blöcke, Klartext, Einfügen/Verschieben"]
    MOD --> AMP["AppModel+Power<br/>powerInsert, powerAppend, powerNewSlide,<br/>powerAddQuote, powerAddStoryElement"]
    MOD --> DS["PowerDragSource (AppKit)<br/>Writer-Markdown + Klartext + Herkunft"]
    AMP --> UNDO["lastChange → „Rückgängig“"]
```

Das Ziehen nutzt eine **AppKit-Drag-Quelle** statt SwiftUIs `onDrag`: Nur so nehmen AppKit-Textansichten (Dokument, Folie, Chat-Eingabe) den Text an. Auf das Pasteboard kommen Writer-Markdown (die Editoren behalten Formatierung, Zitationen werden zu Pillen), Klartext für alle anderen und – bei Blöcken aus dem Panel – deren Herkunft, damit Ziehen innerhalb desselben Dokuments verschiebt statt kopiert.
