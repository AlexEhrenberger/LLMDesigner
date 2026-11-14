# Chat: Code-Streaming und PDF-Eingabe

_Stand 11.11.2026: **umgesetzt** auf Branch `feature/chat-code-pdf` (Teil 1 und Teil 2, Schritte 1–6). Entscheidungen: Datenformat wie vorgeschlagen, Grafiken b + d auf Knopfdruck + e, beschrieben wird mit dem Chat-Modell, wenn es Bilder versteht (Kapitsa: ja), sonst mit einem geladenen Vision-Modell. Die Messungen stammen aus kleinen Nachbauten außerhalb der App (gleicher Compiler, Swift-5-Modus). Nach dem Umbau: Code-Block mit 1000 Zeilen 16 ms statt 624 ms pro Update, 2000 Zeilen 31 ms statt 2,5 s._

## 1. Der Code-Block hinkt dem Modell hinterher

### Befund (gemessen)

Zwei Ursachen verstärken sich gegenseitig.

**1. Die Token-Schleife läuft auf dem Main Thread** (`AppModel.generate`, `for try await event in stream`, `AppModel.swift:1250`).
Nach jedem Neuzeichnen kommt genau ein Token in die Schleife. Weil seit dem letzten Flush schon mehr als 50 ms vergangen sind, löst dieses eine Token sofort den nächsten Flush aus. Sobald ein Neuzeichnen länger als 50 ms dauert, schafft die Oberfläche also **ein Token pro Neuzeichnen**. Der Rest staut sich im Puffer des Streams und läuft nach, wenn das Modell längst fertig ist.

Nachbau: 600 Tokens bei 40 tok/s, das Modell ist nach 17 s fertig.

| Neuzeichnen dauert | Nachlauf heute | Nachlauf, wenn der Strom abseits vom Main Thread gelesen wird |
|---|---|---|
| 20 ms | 0 s | – |
| 60 ms | 21 s | 0,0 s |
| 120 ms | 56 s | 0,1 s |
| 250 ms | ca. 150 s | 0,3 s |
| 500 ms | – | 0,8 s |

Heute gibt es genau so viele Neuzeichnungen wie Tokens (600). Mit der Lösung passt sich die Zahl der Neuzeichnungen an deren Kosten an (37 bis 258).

**2. Ein großes `Text` mit vielen Zeilen ist quadratisch teuer** (`CodeBlockView`, `Markdown.swift:158`).

Layout pro Update:

| Zeilen | Code-Block heute | Fließtext gleicher Länge | eine Zeile je `Text` |
|---|---|---|---|
| 200 | 31–36 ms | 2 ms | 8 ms |
| 500 | 164 ms | 5 ms | 17 ms |
| 1000 | 626 ms | 9 ms | 40 ms |

Textauswahl, horizontales Scrollen und Zeilenabstand ändern daran nichts. Teuer sind die vielen Zeilenumbrüche in einem einzigen `Text`. In der App kommen noch das Parsen der ganzen Antwort (`MarkdownParser.parse` bei jedem Update) und das Layout der Nachrichtenliste dazu.

**Zusammen:** Ein Code-Block von 300 Zeilen (ca. 1 500 Tokens) braucht ca. 80 ms pro Neuzeichnen. Das ergibt 1 500 × 80 ms ≈ 2 min, obwohl Kapitsa nach ca. 50 s fertig ist. Fließtext bleibt unter 50 ms, deshalb fällt es nur bei Code auf. Die Denkansicht zeigt beim Streamen nur die letzten 600 Zeichen und ist unkritisch.

### Umsetzung

**1.1 Den Strom abseits des Main Threads lesen.** Das behebt den Stau unabhängig davon, wie teuer das Zeichnen ist.

- Die innere Schleife aus `generate` wandert in eine `nonisolated` Funktion (neu: `Core/StreamRound.swift`). Sie sammelt Text, Reasoning, Tool-Calls, Usage und Zeitpunkte und gibt höchstens alle 50 ms einen Schnappschuss an den Main Actor.
- **Entscheidend:** Die 50 ms zählen ab dem Moment, in dem der Main Thread den Schnappschuss übernommen hat (`lastFlush` erst nach dem `await` setzen). Sonst löst wieder jedes Token einen Flush aus. Im Nachbau brachte die Verlagerung ohne diese Regel keinen Gewinn.
- `closeRound`, Statistik und Tool-Runden bleiben auf dem Main Actor. `StreamRound` liefert ihnen ein Ergebnis-Struct.
- `.model(...)` geht mit dem ersten Schnappschuss mit. Das Abbrechen bleibt bei `generationTasks[chatID]?.cancel()`.
- Danach `WriterAIActions` (Zeile 137) und `WriterAssistant` (Zeilen 150, 194, 270) prüfen: Dort wird bei jedem Token `cleanPartial(raw)` über den ganzen Text gerechnet und ins NSTextView geschrieben. Nur umbauen, wenn eine Messung dort Nachlauf zeigt.

**1.2 Den Code-Block günstig zeichnen.**

- `CodeBlockView` bekommt ein `NSTextView` statt `Text`: nicht editierbar, auswählbar, kein Zeilenumbruch, horizontaler Scroller. Beim Streamen wird nur das Neue angehängt (`textStorage.append`), wenn der neue Code mit dem alten beginnt, sonst wird er komplett ersetzt. Die Höhe kommt aus dem Layout-Manager. Der Kopieren-Knopf bleibt, die Farben kommen aus `Theme` (hell und dunkel), Schrift 13 pt mono und Zeilenabstand 3 wie heute.
- Fallback, falls das NSTextView in der Nachrichtenliste Probleme macht: den Code in Stücke à 50 Zeilen teilen, fertige Stücke ändern sich nicht mehr (Equatable). Nachteil: Eine Auswahl über Stückgrenzen hinweg geht dann nicht.
- `MarkdownView`: Blöcke als `Equatable`-Views, damit nur der wachsende letzte Block neu gebaut wird. `MarkdownParser.parse` je Update messen und erst dann einen Präfix-Cache einbauen, wenn das Parsen bei 50 000 Zeichen mehr als 5 ms dauert.

**1.3 Prüfen.**

- Test `StreamRoundTests` (Swift Testing, ohne Fenster): 2 000 Ereignisse im 1-ms-Takt, der Empfänger der Schnappschüsse braucht jeweils 150 ms. Erwartung: Ende höchstens 1 s nach dem letzten Ereignis (heute wären es ca. 300 s), der letzte Schnappschuss ist vollständig, und es gibt deutlich weniger Schnappschüsse als 2 000. Zusätzlich: Abbrechen mitten im Strom, Tool-Calls kommen an.
- Test für den Code-Block: Anhängen statt Ersetzen. Die Delta-Logik lässt sich als reine Funktion testen.
- In der App mit Kapitsa: um ca. 500 Zeilen Code bitten und vorher und nachher die Zeit zwischen Stream-Ende und fertigem Code-Block messen. Außerdem prüfen: Auswahl, Kopieren, horizontales Scrollen mit echter Maus, helles und dunkles Design, Mini-Chat und Suchleiste (beide nutzen dieselbe `MessageRow`).

## 2. PDFs und andere Dokumente als Eingabe im Chat

### Was schon da ist

- `DocumentText.extract(from:)` (`Persona.swift:320`) liest PDF (PDFKit, Seite für Seite), Word, RTF, OpenDocument, HTML und Text. Persona-Dateien und Citation-Anhänge nutzen es bereits.
- `PersonaFileTools` mit `search_files` und `read_file` in Teilen à 3 000 Zeichen ist das Vorbild für lange Dokumente.
- Bildanhänge im Composer: `AttachmentStore`, `draftImages`, Bibliotheksordner `Attachments`.
- Texterkennung auf dem Gerät (Vision) mit `de-DE` und `en-US`, auf diesem Mac geprüft. macOS 26 bietet zusätzlich `RecognizeDocumentsRequest` (Absätze, Tabellen). Die App zielt aber auf macOS 15, also nur hinter `#available`.
- Sicherheit: `prepareActionRun` markiert einen Chat als „fremd“ (A), wenn er Webseiten gelesen hat.

### Ablauf

1. **Anhängen:** Die Büroklammer im Composer nimmt Bilder und Dokumente (heute nur Bilder), ebenso Ziehen und Einfügen. Das Dokument erscheint als Chip mit Name, Seitenzahl und „≈ 9 400 Tokens“ sowie dem Fortschritt („Text wird gelesen …“, „Seite 3 wird erkannt …“, „Abbildungen …“).
2. **Text:** `DocumentText` liest Seite für Seite. Seiten ohne Textschicht (Scans) gehen durch die Vision-Texterkennung. Seitenmarken wie `[Seite 4]` bleiben im Text, damit das Modell Seiten nennen kann.
3. **Abbildungen:** siehe unten.
4. **Ins Modell:** Der Text wird Teil der Nutzernachricht, an der das Dokument hängt, als eigener Abschnitt vor der Frage („Datei „X.pdf“, 12 Seiten:“ …). So steht er im festen Anfang der Anfrage und der Präfix-Cache greift bei den folgenden Fragen. Kapitsa muss ihn nur einmal einlesen.
5. **Zu groß für den Kontext** (Schwelle ca. 35 % von `contextLength(of:)`, bei Kapitsa mit 32K ca. 11 000 Tokens bzw. 15–20 Seiten): Statt des Volltexts gehen Inhaltsverzeichnis und erste Seite mit, dazu die Werkzeuge `search_document` und `read_document` (aus `PersonaFileTools` verallgemeinert). Modelle ohne Werkzeuge bekommen den Anfang, und der Chip sagt, wie viele Seiten fehlen. Vor der ersten Nachricht bietet der Chip an, den Kontext größer zu stellen, denn danach ist er fest.
6. **Anzeigen:** In der gesendeten Nachricht steht ein Chip. Ein Klick öffnet ein Blatt mit „Original“ (PDFView), „Text fürs Modell“ und „Abbildungen“.

### Grafiken: Optionen

| Weg | Vorteil | Nachteil |
|---|---|---|
| a. Nur Text | schnell, kein Aufwand | Das Modell weiß nicht einmal, dass es eine Abbildung gab. |
| b. Platzhalter mit Bildunterschrift, z. B. `[Abbildung 3, S. 5: „Umsatz 2020–2024“]` | billig; das Modell kann ehrlich sagen, dass es die Grafik nicht sieht | Der Inhalt der Grafik fehlt. |
| c. Seiten oder Ausschnitte als Bild mitschicken | Das Modell sieht das Original. | Jedes Bild geht mit jeder Frage erneut mit (Kontext, Zeit); nur mit Vision-Modell; kleine Modelle lesen Diagramme unzuverlässig. |
| d. Einmal beschreiben lassen, dann als Text | Danach fallen nur Textkosten an, und es funktioniert mit jedem Modell im Chat. | Einmalige Wartezeit; die Beschreibung kann falsch sein und wird deshalb als „vom Modell beschrieben“ gekennzeichnet. |
| e. Gezielt nachreichen | für Detailfragen zu einer Grafik | braucht ein Werkzeug oder einen Knopf |

**Empfehlung:** b immer. Dazu d auf Knopfdruck („Abbildungen beschreiben“) oder automatisch, wenn ein Vision-Modell bereitsteht. e als spätere Ausbaustufe: Ein Knopf an der Abbildung schickt sie mit der nächsten Frage als Bild mit und nutzt dafür die bestehenden Bildanhänge.

**Abbildungen erkennen**, ohne neue Abhängigkeit: Die Seite wird mit PDFKit gerendert (ca. 100 dpi), die Textzeilen (`PDFPage.selection(for:)` → `selectionsByLine()`) werden ausgeblendet, und große nicht-weiße Flächen gelten als Abbildung. Das findet Rasterbilder ebenso wie Vektorgrafiken. Als Bildunterschrift gilt eine Zeile mit „Abb.“, „Abbildung“, „Fig.“, „Figure“, „Tabelle“ oder „Table“ direkt darunter oder darüber. Die Ausschnitte landen als JPEG im Anhangsordner (wie Bilder, höchstens 1600 px).

**Tabellen:** PDFKit liefert Tabellen als zerrissenen Text. Unter macOS 26 lässt sich `RecognizeDocumentsRequest` in eine Markdown-Tabelle übersetzen. Sonst bleibt es beim Text wie heute, oder Weg d: „als Tabelle abschreiben lassen“.

### Speicherung (Rückfrage nötig)

Vorschlag:

- `ChatMessage.documents: [DocumentAttachment]?`, optional, damit alte Chats lesbar bleiben.
- `DocumentAttachment { id, name, kind (pdf, word, …), pageCount, characterCount, fileName (Original), textFileName, figures: [DocumentFigure]?, truncated: Bool? }`
- `DocumentFigure { page, caption?, imageFileName, description?, describedBy? }`
- Die Dateien liegen im Bibliotheksordner `Attachments/`: das Original, eine `.txt` mit Seitenmarken und Platzhaltern sowie die Ausschnitte. `AttachmentStore.removeUnused` muss sie kennen, und `docs/speicherformate.md` wird ergänzt.

### Sicherheit

- Ein Dokument stammt zwar vom Nutzer, sein Inhalt aber oft von Dritten. Deshalb setzen Nachrichten mit Dokument A (`prepareActionRun` → `markUntrusted()`). Damit fragen Actions mit Wirkung nach der Regel aus Abschnitt 4.2 des Sicherheitskonzepts.
- Test mit einem präparierten PDF (`Tests/LLMDesignerTests/Security/`): Chat mit PDF plus Action mit Wirkung, die Registry muss fragen.
- Action `chat.attach_document` für die CLI (Datei aus einem Pfad) mit `readsUntrusted: true`. Über MCP wird sie verweigert, weil sie lokale Dateien liest.

### Schritte

1. Modell, Speicherung und Text (PDFKit, Seitenmarken), Chip im Composer, Text in die Nachricht, Sicherheitsmarke, Tests.
2. Texterkennung für Seiten ohne Text.
3. Abbildungen erkennen, Platzhalter, Blatt „Abbildungen“.
4. Abbildungen beschreiben (Vision-Modell), Tabellen unter macOS 26.
5. Lange Dokumente: Werkzeuge statt Volltext, Hinweis zur Kontextlänge.
6. Mini-Chat und Suchleiste, Action `chat.attach_document`.

## Offene Entscheidungen

1. Ist das Datenformat oben in Ordnung?
2. Standard für Grafiken: b plus d auf Knopfdruck?
3. Welches Modell beschreibt Abbildungen: das des Chats (wenn es Bilder versteht) oder fest Gemma 4 in LM Studio? Ob Kapitsa Bilder annimmt, ist noch nicht geprüft.
4. Reihenfolge: zuerst Teil 1 (klein, in sich geschlossen), dann das PDF in den Schritten 1–6?
