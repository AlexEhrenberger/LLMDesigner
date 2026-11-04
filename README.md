# LLM Designer

Native macOS-App (SwiftUI) als „LM Studio Plus“: Chat-Oberfläche im Stil von ChatGPT, die auf dem lokalen LM-Studio-Server (oder Kapitsa) aufsetzt – dazu Writer, Presenter, Citation und Stories Studio. Das Design ist wählbar: hell, dunkel oder wie das System.

**Dokumentation** mit Diagrammen: [Übersicht](docs/index.md) · [Funktionsweise](docs/funktionen.md) · [Architektur](docs/architektur.md) · [Code-Führer](docs/code.md) · [Speicherformate](docs/speicherformate.md)

## Neu

- **Neu-Menü**: Das Stift-Symbol öffnet ein Menü mit „Neuer Chat“ und allen Applikationen (Writer, Citation, Presenter, Stories).
- **Power-Zugriff** (Blitz in der Titelleiste, ⌥⌘J): Das rechte Panel zeigt kompakte Versionen von Chats, Writer, Presenter, Citation und Stories Studio. Durchsuchen, Text in beide Richtungen ziehen, Zitate und Story-Elemente direkt anlegen, Änderungen rückgängig machen. Details in [docs/funktionen.md](docs/funktionen.md#power-zugriff).
- **Presenter Studio** erbt Writers Formatierungen (hoch-/tiefgestellt, durchgestrichen, Code, Tabellen mit Formeln, Diagramme, Zeichnungen) und kennt **frei verschiebbare Elemente**: Textfelder, Kästen, Tabellen, Code und Abbildungen lassen sich wie Bilder auf der Folie verschieben und skalieren (Doppelklick zum Schreiben); auch der Textbereich der Folie ist verschiebbar.

## Bauen & Starten

Benötigt nur die Xcode Command Line Tools (Swift 6), kein Xcode.

```bash
scripts/build-app.sh release --open
```

Das Skript baut das Swift Package, erzeugt beim ersten Mal das App-Icon und legt `build/LLM Designer.app` an.

## Bibliotheken

Alles, was LLM Designer speichert, liegt in einer **Bibliothek**: Chats, Dokumente mit Bildern und Plots, Personas mit ihrem Gedächtnis, Skills, Ordner, Anhänge und alle Einstellungen (auch Endpoint und Modell). Bibliotheken sind voneinander getrennt – eine sieht nichts von der anderen.

- **Portabel**: Eine Bibliothek ist ein Paket `Name.llmdlibrary` (im Finder ein einzelnes Objekt). Man kann sie kopieren, auf einen anderen Mac oder ein externes Laufwerk legen und dort öffnen. Ein Doppelklick im Finder öffnet sie in LLM Designer.
- **Wechseln** unten links in der Seitenleiste, über der LM-Studio-Zeile: zuletzt geöffnete Bibliotheken, „Neue Bibliothek …“, „Bibliothek öffnen …“, Umbenennen, „Im Finder zeigen“ und „Aus der Liste entfernen“. Dieselben Befehle stehen im Menü „Ablage“ (Öffnen: ⇧⌘O). Beim Wechsel wird alles Offene gespeichert und laufende Arbeit (Antworten, Gedächtnis, Vorlesen, Diktat) beendet.
- Neue Bibliotheken liegen standardmäßig in `~/Dokumente/LLM Designer/` und starten mit Standard-Einstellungen.
- Wird die geöffnete Bibliothek im Finder verschoben oder umbenannt, folgt die App ihr, sobald sie wieder im Vordergrund ist. Eine Bibliothek, die fehlt (z. B. Laufwerk nicht angeschlossen), steht als „nicht verfügbar“ in der Liste; beim Start öffnet die App dann eine andere.
- **Außerhalb der Bibliotheken** merkt sich die App nur die Liste der zuletzt geöffneten Bibliotheken (in ihren macOS-Voreinstellungen, zusammen mit dem, was AppKit selbst dort ablegt, etwa Fensterpositionen). HTTP-Antworten werden nicht auf der Festplatte zwischengespeichert. Temporäre Dateien (PDF-Satz, Plots, Sprachausgabe) entstehen im System-Temp-Ordner. Externe Werkzeuge wie Python/matplotlib und Tectonic führen ihre eigenen Caches.
- Beim ersten Start mit dieser Version wurden die bisherigen Daten aus `~/Library/Application Support/LLMDesigner` und die Einstellungen aus den Voreinstellungen in „Meine Bibliothek“ übernommen; der alte Ordner liegt im Papierkorb.

Aufbau einer Bibliothek: `Bibliothek.json` (Kennung, Format), `Einstellungen.plist`, `Chats/` (ein JSON pro Chat), `ChatFolders.json`, `Skills.json` (Skills und ihre Ordner), `Documents/` (Markdown-Dokumente, darin `Bilder/`), `Personas/<ID>/` (`persona.json`, Profilbild, `files/`, `text/`, `thalamus.json`), `Attachments/` (angehängte Bilder). Pfade in den Daten sind relativ, deshalb lässt sich eine Bibliothek frei verschieben.

## LM Studio

- Standard-Endpoint: `http://127.0.0.1:1234` (änderbar unter Einstellungen, ⌘,; gilt pro Bibliothek)
- Modelle + Lade-Status: `GET /api/v0/models` (Fallback: `/v1/models`)
- Chat: `POST /v1/chat/completions` mit Streaming und `include_usage`; mit eingeschalteter Web- oder Wikipedia-Suche zusätzlich `tools` (Tool-Aufrufe kommen gestückelt im Stream und werden zusammengesetzt)
- **Modell wählen**: Klick auf „LM Studio verbunden“ unten links in der Seitenleiste – die geladenen Modelle und die übrigen verfügbaren (der Klick prüft auch die Verbindung neu).
- Hinweis: Bei einem unbekannten Modellnamen antwortet LM Studio stillschweigend mit dem geladenen Modell. Die App zeigt deshalb immer das Modell an, das laut Stream tatsächlich geantwortet hat.

## Ordner & Skills

Oben in der Seitenleiste wechselt „Chats | Skills | Personas“ (⌘1 / ⌘2 / ⌘3) zwischen der Chat-Liste, der Skill-Bibliothek und den Personas.

- **Ordner** (Ordner-Symbol oben oder ⇧⌘N) gibt es für Chats und für Skills, jeweils eine Ebene. Chats und Skills kommen per Ziehen auf den Ordner hinein; irgendwo außerhalb eines Ordners abgelegt, wandern sie wieder heraus. Alternativ: Rechtsklick bzw. „…“ → „In Ordner verschieben“. Ein Klick auf den Ordner klappt ihn auf und zu; sein Menü bietet „Neuer Chat in diesem Ordner“, Umbenennen und Löschen (wahlweise mit oder ohne Inhalt).
- **Skills** sind Bausteine für den System-Prompt: eine Rolle, ein Schreibstil, Formatierungsregeln … Mit + (⌥⌘N) entsteht ein neuer Skill; im Editor stehen Name, Symbol, Kurzbeschreibung, Ordner und die Anweisungen für das Modell (mit Zeichen- und Token-Schätzung). Änderungen werden automatisch gespeichert. Ein neuer Skill, der leer bleibt, verschwindet wieder.
- **Im Chat** öffnet das Puzzle-Symbol im Eingabefeld (⇧⌘K) die Skill-Bibliothek: durchsuchen (↑/↓ und ⏎ gehen auch), beliebig viele Skills anhaken, als Chips wieder abschalten. Unten zeigt sie, wie groß der System-Prompt wird, und auf Klick den zusammengesetzten Text. Belegt er mehr als ein Viertel des geladenen Kontexts, wird die Anzeige gelb.
- Der System-Prompt eines Chats ist: allgemeiner System-Prompt aus den Einstellungen, dann die Anweisungen der eingeschalteten Skills in der Reihenfolge, in der sie eingeschaltet wurden (jeweils durch eine Leerzeile getrennt), danach ggf. die Hinweise für Web- und Wikipedia-Suche. Skills gelten pro Chat, gehen beim Abzweigen mit und wirken ab der nächsten Nachricht. Bearbeitet man einen Skill, gilt das für alle Chats, die ihn nutzen.
- Bei leerer Bibliothek legt „Beispiele anlegen“ fünf Beispiel-Skills an (Finanzberater, Einfühlsamer Zuhörer, Kurz halten, Gedichte, Für PDF gesetzt).

## Gedächtnis & Kontext

Unter dem Eingabefeld sitzt eine Kapsel mit zwei Menüs (ohne Persona nur mit dem Kontext). Beides gilt pro Chat und wird vor der ersten Nachricht gewählt; neue Chats übernehmen die letzte Wahl.

- **Gedächtnis (Thalamus)**: ein oder aus, per Klick umgeschaltet. Erscheint nur, wenn eine Persona gewählt ist, denn das Gedächtnis gehört zur Persona. Eingeschaltet ordnet die Persona jede Nachricht mit Gefühlen ein und verdichtet sie zu Erinnerungen (siehe unten). Chats aus der Zeit, als es „schwach“ und „stark“ gab, gelten als „ein“.
- **Kontext**: kurzes Gespräch (8K), mittleres (16K) oder langes (32K). Stufen über der Höchstlänge des Modells sind gesperrt.
  - Vor einer Antwort prüft die App, ob das Modell mit genau dieser Länge geladen ist. Wenn nicht, lädt sie es über LM Studios REST-API neu (`/api/v1/models/unload`, dann `/api/v1/models/load` mit `context_length`). Das dauert einige Sekunden, beim ersten Mal etwa 10.
  - Die übrigen Einstellungen des Modells in LM Studio bleiben dabei, wie sie sind.
  - Wechselt man zwischen Chats mit verschiedenen Längen, wird jedes Mal neu geladen.
  - Längerer Kontext braucht mehr Speicher, und lange Gespräche werden langsamer.
- **Nach der ersten Nachricht** lässt sich beides nicht mehr ändern:
  - Das Gedächtnis steht dann grau da.
  - Statt des Kontext-Menüs erscheint eine Anzeige, wie viel vom Kontext belegt ist, z. B. „3,1K / 8K“; ab 80 % wird sie gelb, ab 95 % rot.
  - Fährt man mit der Maus darüber, zeigt eine Karte, woraus der Kontext besteht: Persona bzw. System-Prompt, Werkzeuge und Hinweise, eigene Nachrichten, Antworten, Bilder und was noch frei ist.
  - Die Werte sind geschätzt (etwa 3,5 Zeichen pro Token, ein Bild etwa 260 Tokens). Wo es geht, gleicht die App sie mit der Zählung ab, die LM Studio für die letzte Antwort gemeldet hat.
- Chats von vor dieser Einstellung haben keine feste Länge; ihre Anzeige misst an der Länge, mit der das Modell gerade geladen ist.

### Gedächtnis (Thalamus)

Aufgebaut wie das menschliche Gedächtnis: frische **Eindrücke** (Kurzzeit) werden, sobald ein Chat still ist, zu **Erinnerungen** (Themen) und einem **Profil** verdichtet.

**1. Eindruck (vor jeder Antwort)**
- In einem Persona-Chat mit „Gedächtnis: ein“ geht jede Nachricht des Nutzers zuerst an das geladene Modell, mit einem neutralen Prompt statt dem der Persona. Zum Verständnis kurzer Antworten bekommt es auch die vorige Antwort der Persona.
- Es liefert per JSON-Schema: eine Kategorie (möglichst eine vorhandene, sonst aus einer Vorschlagsliste oder neu), einen Satz zum Inhalt in der dritten Person, 2 bis 6 Schlagworte, bis zu drei Gefühle des Nutzers und bis zu drei der KI mit Stärke 1 bis 10, und ob die Nachricht merkenswert ist.
- Daraus entsteht der Schlüssel, z. B. `(Studium, (Angst: 8), (Sorge: 7, Mitgefühl: 6))`. Smalltalk wie „danke dir“ wird eingeordnet, aber nicht gespeichert.
- Über der Antwort zeigt eine Zeile das Ergebnis, z. B. „Studium · Angst 8 · KI: Sorge 7, Mitgefühl 6 · erinnert sich an „Statistik-Klausur““; vorher steht dort „Thalamus ordnet ein …“. Aufgeklappt zeigt sie den Schlüssel, die Schlagworte, die Gefühle und die erinnerten Themen.
- Neu generieren nutzt den vorhandenen Eindruck; ist er schon verdichtet, wird nicht neu eingeordnet, nur erinnert.

**2. Verdichtung (wenn der Chat still ist)**
- Ausgelöst, wenn man den Chat verlässt, wenn 30 Minuten keine neue Nachricht kommt, beim Start der App für liegengebliebene Eindrücke, oder im Persona-Editor mit „Jetzt verdichten“.
- Pro Chat und pro Kategorie ein Aufruf des Modells (neutraler Prompt): Es bekommt die Eindrücke, das Profil und bis zu acht vorhandene Erinnerungen, die über Schlagworte oder Kategorie passen. Getrennt nach Kategorie, weil kleine Modelle sonst verschiedene Themen eines Chats (eine Prüfung und einen Umzug) in eine Erinnerung mischen.
- Vorher sortiert die App Eindrücke über das Gespräch selbst aus (der neutrale Prompt nennt die Persona immer „Gesprächspartner“, etwa „Der Nutzer fragt den Gesprächspartner, ob er sich erinnert …“); kleine Modelle würden sie sonst als Inhalt verdichten.
- Das Modell nennt zuerst ausdrücklich, welche Eindrücke es verwirft (Pflichtfeld), dann entscheidet es: Was zu einem bekannten Thema gehört, ergänzt dessen Erinnerung (der Text wird neu geschrieben, in zeitlicher Reihenfolge, wer was gesagt hat); ein neues Thema wird eine neue Erinnerung; feste Fakten über den Nutzer (Name, Wohnort, Menschen, Haustiere …) kommen ins Profil, ein geänderter Fakt ersetzt den alten; Belangloses wird vergessen.
- Die App filtert nach: Ins Profil kommen nur Fakten über das Leben des Nutzers (nichts über das Gespräch, die KI oder die Persona), doppelte Fakten werden zusammengelegt. Schlagworte über das Gespräch selbst („Frage“, „Gespräch“), Gefühlsnamen, Daten und die Kategorie fallen weg, weil sie sonst bei fast jeder Nachricht falsche Erinnerungen auslösen.
- Die App ergänzt den **Gefühlsverlauf** (pro Chat die stärksten Gefühle beider Seiten, höchstens acht Punkte), die Schlagworte, Zeitraum, Anzahl der Erwähnungen und die Chats. Danach sind die Eindrücke weg.
- Im Eingabefeld zeigt „Mira verdichtet Erinnerungen …“, dass es läuft. Wer weiterschreibt, unterbricht es; die Eindrücke bleiben und werden später verdichtet.
- Liefert das Modell nichts Brauchbares, bleiben die Eindrücke für den nächsten Versuch liegen.

**3. Langzeitgedächtnis**
- **Erinnerungen** sind Themen, die über Chats wachsen, z. B. „Statistik-Klausur“ mit dem Verlauf *Angst → Erleichterung*.
- **Gewicht**: starke Gefühle (45 %), Häufigkeit (25 %) und wie lange es her ist (30 %, halbiert sich grob alle zwei Monate). Unwichtiges rutscht so mit der Zeit nach hinten. Nichts wird von selbst gelöscht.
- **Profil**: Fakten über den Nutzer, immer im Kontext (bis etwa 5 % des Kontexts).
- **Letzte Gespräche**: Die Erinnerungen der letzten drei Chats mit der Persona und deren noch nicht verdichtete Eindrücke stehen immer im System-Prompt (bis etwa 15 % des Kontexts; sind es mehr, fallen die ältesten heraus).
- **Erinnern an Älteres**: Löst ein Wort der neuen Nachricht oder eines ihrer Schlagworte ein Schlagwort oder den Titel einer älteren Erinnerung aus, bekommt die Persona bis zu drei solcher Erinnerungen für diese eine Antwort, mit Gefühlsverlauf und der Anweisung, sich wie ein Mensch zu erinnern („Ich weiß noch, wie traurig du warst, als …“). Ein Wort löst aus, wenn es gleich ist, den Anfang bildet („Fit“, „Fitness“ → „Fitnesszentrum“), ab fünf Buchstaben darin vorkommt oder nur die Endung abweicht. Füllwörter wie „ich“, „heute“ oder „Woche“ zählen nicht. Gleiche Kategorie, mehrere Treffer und höheres Gewicht gehen vor.
- Gefühle stehen im Prompt als Wörter (leicht, mäßig, deutlich, stark, sehr stark) mit der Anweisung, nie Zahlen oder Skalen zu nennen; sonst übernimmt das Modell „9/10“ wörtlich.
- In der Kontext-Anzeige zählen Profil und letzte Gespräche zu „Erinnerungen“.

**Persona-Editor, Abschnitt „Thalamus“**: Profil (Fakten einzeln löschbar), Erinnerungen nach Gewicht sortiert (Kategorie, Titel, Gewicht als fünf Balken, Zeitraum, Erwähnungen, Text, Gefühlsverlauf pro Chat, Schlagworte; zum letzten Chat springen, löschen; weniger wichtige wirken etwas blasser), Filter nach Kategorie, Suche, die frischen Eindrücke zum Aufklappen, „Jetzt verdichten“ mit Fortschritt und Ergebnis, „Alle löschen …“.

**Ablage**: `…/Personas/<ID>/thalamus.json` mit Eindrücken, Erinnerungen, Profil und Aktivität pro Chat. Beim ersten Speichern im neuen Format bleibt die alte Datei als `thalamus-vor-verdichtung.json` liegen.

Das Einordnen kostet vor jeder Antwort einen zusätzlichen Aufruf des Modells (mit Gemma 4 E4B einige Sekunden, im Gesprächsmodus ebenso); das Verdichten läuft im Hintergrund, wenn der Chat still ist.

## Personas

Eine Persona ist ein Charakter, mit dem man chattet wie mit einem Menschen: Profilbild, Name, Biografie, Verhalten, eigene Stimme und eigene Dateien.

- **Anlegen**: Reiter „Personas“ in der Seitenleiste, dann + (⌥⇧⌘N). Im Editor stehen:
  - **Profilbild**: anklicken oder ein Bild darauf ziehen; Rechtsklick entfernt es. Das Bild wird quadratisch zugeschnitten (bei Hochformat eher oben, wo meist das Gesicht ist) und auf 512 px verkleinert. Seine Farbe färbt den Lichtschein im Gesprächsmodus.
  - **Name**, **Biografie** (wer sie ist: Herkunft, Lebensgeschichte, Beruf, Menschen im Leben) und **Verhalten** (wie sie ist und reagiert: Temperament, Sprechweise, Humor, Eigenheiten).
  - **Stimme**: eine der Qwen-TTS-Stimmen oder „Wie in den Einstellungen“, dazu optional eine Sprechweise (z. B. „ruhig und warm“), die als `instructions` an Qwen TTS geht. „Probehören“ spielt eine kurze Begrüßung. Eine Persona mit eigener Stimme spricht immer mit Qwen TTS (in der Modellgröße aus den Einstellungen), auch wenn dort die macOS-Stimme gewählt ist.
  - **Dateien** (PDF, Word, RTF, OpenDocument, HTML, Text, Markdown, CSV, Quelltext …): per Knopf oder Hineinziehen. Die App speichert eine Kopie und den ausgelesenen Text. Gescannte PDFs ohne Texterkennung werden abgelehnt.
  - Unten steht, wie viele Tokens Name, Biografie und Verhalten im System-Prompt belegen; über einem Viertel des geladenen Kontexts wird die Anzeige gelb.
- **Chatten**: „Chat starten“ im Editor, „Chat starten“ im Menü der Seitenleiste oder das Personen-Symbol im Eingabefeld (⇧⌘P). Die Persona legt man beim Start eines Chats fest. In einem laufenden Chat beginnt ein Klick auf eine Persona einen neuen Chat mit ihr.
- **Persona oder Skills**: Ein Chat läuft entweder mit einer Persona oder mit Skills. Wählt man eine Persona, werden vorher gewählte Skills abgeschaltet; im Chat mit einer Persona ist der Skill-Knopf gesperrt.
- **System-Prompt** eines Persona-Chats: allgemeiner System-Prompt aus den Einstellungen, dann „Du bist {Name} … Bleib in deiner Rolle“, die Biografie und das Verhalten. Danach folgen gegebenenfalls die Hinweise für Dateien, Web- und Wikipedia-Suche.
- **Dateien im Chat**: Die Dateien kommen nicht in den System-Prompt. Das Modell bekommt die Werkzeuge `search_files(query)` und `read_file(name, part)` und schlägt selbst nach, wenn eine Frage sie betreffen könnte:
  - Die Suche zerlegt die Texte in Abschnitte von etwa 700 Zeichen und gewichtet seltene Suchbegriffe stärker. Begriffe passen auch innerhalb längerer Wörter („Haus“ findet „Gartenhaus“). Sie liefert die vier besten Stellen mit Dateiname und Teilnummer.
  - `read_file` liest eine Datei in Teilen von etwa 3.000 Zeichen.
  - Über der Antwort zeigt „Dateien · 1 Suche · 1 Datei gelesen“ die Schritte; aufgeklappt öffnet ein Klick die Datei.
  - Das geht nur mit Modellen, die Werkzeuge beherrschen (z. B. Gemma 4, Qwen 3.5).
- **Im Chat** stehen Bild und Name der Persona über jeder Antwort, in der Seitenleiste vor dem Chat-Titel. Ein neuer Chat zeigt statt des Logos ihr Bild und den Anfang der Biografie. Kopieren und PDF-Export nennen ihren Namen statt des Modells.
- **Gesprächsmodus**: Statt der Welle erscheint das runde Profilbild. Spricht die Persona, laufen Lichtringe in der Farbe des Bildes nach außen, so hell wie die Stimme laut ist, und ein Schein wächst mit. Während die Antwort entsteht, kreist ein Lichtpunkt um das Bild; beim Zuhören atmet ein ruhiger Ring. Ein Klick auf das Bild wirkt wie ein Klick auf die Welle.
- **Löschen** entfernt die Persona mit Bild und Dateien. Ihre Chats bleiben erhalten und laufen ohne Persona weiter.
- **Gedächtnis**: siehe „Gedächtnis (Thalamus)“; im Persona-Editor im Abschnitt „Thalamus“.

## Formeln

LaTeX in Antworten wird mit [SwiftMath](https://github.com/mgriebling/SwiftMath) nativ gesetzt:

- Inline: `$…$` und `\(…\)`. Die Formel sitzt als Bild auf der Textgrundlinie. Geldbeträge wie „$5 und $10“ bleiben Text (TeX-Regel: nur das nächste `$` darf schließen).
- Abgesetzt: `$$…$$`, `\[…\]` sowie `\begin{equation|align|gather|cases|pmatrix…}`. `align`/`equation` werden auf die von SwiftMath unterstützten Umgebungen umgeschrieben (`MathRenderer.normalize`).
- Nicht unterstützte Befehle (z. B. `\underbrace`) erscheinen als LaTeX-Quelltext.

SwiftMath liegt als angepasste Kopie in `Vendor/SwiftMath` (Grund und Änderungen dort in der README). Kurz: SwiftPM sucht die Schriften sonst im Wurzelordner der `.app`, den die Codesignatur nicht erlaubt.

## Kopieren & PDF-Export

- **Unter jeder Antwort:** Kopieren und „Als PDF exportieren“. **Rechtsklick auf eine Antwort:** „Antwort kopieren“, „Antwort als PDF exportieren …“, „Markierten Text kopieren“.
- **Oben rechts im Chat:** ganzen Chat als Markdown kopieren oder als PDF exportieren.
- Das PDF wird mit LaTeX gesetzt (Latin Modern, deutsche Silbentrennung). Formeln aus der Antwort gehen unverändert ins LaTeX. Standard ist DIN A4; Seitenzahlen erscheinen erst ab zwei Seiten. Emojis fallen weg, weil die LaTeX-Schriften sie nicht enthalten.
- Einstellungen (⌘,) → PDF-Export: Papierformat, optionale Sprecherzeile (`{Modell} sagt:` → „Gemma sagt:“), PDF nach dem Export öffnen.
- Benötigt eine LaTeX-Engine. Gesucht werden `tectonic`, `xelatex`, `lualatex` in Homebrew-, MacTeX- und Cargo-Pfaden. Empfohlen:

  ```bash
  brew install tectonic
  ```

  Tectonic lädt beim allerersten Export die benötigten LaTeX-Pakete (ca. 2 Minuten), danach dauert ein Export etwa eine Sekunde.
- Lässt sich eine Formel nicht setzen, versucht der Export es erneut und druckt problematische Formeln als Code, statt ganz zu scheitern.

## Inhaltsverzeichnis, Lesezeichen & Titel

- **Inhaltsverzeichnis** (rechtes Panel, Reiter „Inhalt“, ⌥⌘I): Ab drei Antworten gliedert das Modell den Chat in Themen und Unterpunkte und aktualisiert das nach jeder neuen Antwort. Ein Klick springt zur Stelle und hebt sie kurz hervor. Verweise zeigen auf Nachrichten oder Überschriften darin; die App sortiert die Einträge nach ihrer Position im Chat, weil kleine Modelle die Reihenfolge nicht immer einhalten.
- **Export mit Inhaltsverzeichnis**: „Chat exportieren“ → „Chat mit Inhaltsverzeichnis exportieren …“ (⌥⇧⌘E) setzt vorne ein LaTeX-Inhaltsverzeichnis mit Seitenzahlen und Links.
- **Automatische Chat-Titel**: Mit dem Inhaltsverzeichnis schlägt das Modell einen Titel vor, der den Inhalt beschreibt. Selbst umbenannte Chats behalten ihren Titel (Kontextmenü in der Seitenleiste: „Automatischen Titel verwenden“ hebt das wieder auf).
- **Lesezeichen** (Reiter „Lesezeichen“): Text markieren, Rechtsklick → „Lesezeichen anlegen“ (ohne Markierung: ganze Nachricht). Im Chat zeigt ein Symbol am Rand die Stelle; im Panel springen, umbenennen, löschen.

## Abzweigen & Fragen bearbeiten

- **Abzweigen**: Unter jeder Antwort (Gabel-Symbol) oder per Rechtsklick → „Ab hier in neuem Chat abzweigen“. Der Chat wird bis zu dieser Antwort in einen neuen Chat kopiert, das Original bleibt unverändert. Lesezeichen, Websuche-/Wikipedia-/Denk-Schalter und Modell gehen mit.
- **Frage bearbeiten**: Stift unter der eigenen Frage (oder Rechtsklick → „Bearbeiten und abzweigen …“). Die Frage wird direkt in der Blase bearbeitet; angehängte Bilder lassen sich entfernen oder per ⌘V/Hineinziehen ergänzen. ⏎ schickt sie als neuen, abgezweigten Chat ab (alles davor wird übernommen), esc bricht ab.
- Abgezweigte Chats tragen in der Seitenleiste ein Gabel-Symbol. Eine Trennlinie im Chat zeigt, wo er abzweigt („Abgezweigt von „…“ · Frage bearbeitet“); ein Klick springt an die Stelle im Original.

## Bilder

- Anhängen über das Bild-Symbol im Eingabefeld (⇧⌘A), per ⌘V (z. B. Bildschirmfoto) oder durch Hineinziehen ins Fenster. Mehrere Bilder pro Nachricht sind möglich; Vorschaubilder lassen sich vor dem Senden wieder entfernen.
- Die App geht davon aus, dass das Modell Bilder versteht (Gemma 4, Qwen 3.5); es gibt keine Prüfung pro Modell.
- Bilder werden auf höchstens 1600 px verkleinert, als JPEG gespeichert und als `image_url` (Base64) an LM Studio geschickt, bei jeder Folgefrage erneut. Bei kleinem Kontext (Gemma mit 8K) kosten viele Bilder entsprechend Platz.
- Im Chat stehen die Bilder über der Frage; ein Klick öffnet sie in Vorschau. Der PDF-Export setzt sie mit ins Dokument.
- Bilder, die kein Chat mehr nutzt, löscht die App beim Start und beim Löschen eines Chats.

## Denkmodus

- **Einschalten** mit „Denken“ (Gehirn-Symbol) im Eingabefeld oder ⇧⌘T. Der Schalter gilt pro Chat; neue Chats übernehmen die letzte Wahl.
- **Gemma 4** denkt nur, wenn der System-Prompt mit dem Token `<|think|>` beginnt. LM Studio reicht `enable_thinking` über die OpenAI-Schnittstelle nicht an das Chat-Template weiter, deshalb setzt die App das Token selbst. Die Gedanken kommen dann roh im Text (`<|channel>thought … <channel|>`) und werden von der App abgetrennt. Bei leichten Fragen entscheidet Gemma E4B manchmal, nicht zu denken.
- **Qwen 3.5** denkt laut Chat-Template immer. Ausschalten lässt es sich über die Schnittstelle nicht; dafür müsste man in LM Studio das Prompt-Template des Modells ändern.
- **Anzeige**: Während das Modell denkt, zeigt eine Karte mit fester Höhe einen leuchtenden Orb, die Laufzeit, den aktuellen Denkschritt, eine „Gedankenspur“ (ein farbiges Segment pro Absatz, Breite nach Länge) und die letzten drei Zeilen der Gedanken. Der Chat wächst dabei nicht. Danach klappt sie zu „Nachgedacht · 12 s · 7 Schritte“ zusammen; ein Klick öffnet den ganzen Gedankengang als Zeitleiste in einem Popover (mit Kopieren).

## Folgefragen

Nach jeder Antwort schlägt das Modell drei Folgefragen vor; ein Klick stellt die Frage. Abschaltbar unter Einstellungen → Generierung.

## Websuche & Wikipedia

- **Einschalten** im Eingabefeld: der **Globus** für die Websuche, das **W** für Wikipedia. Beide gelten pro Chat, lassen sich kombinieren und werden mit dem Chat gespeichert; ein neuer Chat startet ohne Suche. Die Knöpfe sind nur aktiv, wenn LM Studio für das Modell `tool_use` meldet (z. B. Gemma 4, Qwen 3.5).
- Das Modell entscheidet selbst, wann es nachschlägt. Je nach Knopf bekommt es diese Werkzeuge über die OpenAI-kompatible Tool-Schnittstelle von LM Studio:
  - Globus: `web_search(query)` sucht bei DuckDuckGo ohne Konto und Schlüssel (`html.duckduckgo.com`, Ersatz `lite.duckduckgo.com`) und liefert 6 Treffer mit Titel, Adresse, Datum und Ausschnitt; die Region kommt aus den Systemeinstellungen (z. B. `de-de`). `open_page(url)` liest eine Seite oder ein PDF als Text (HTML wird ohne Browser auf den Hauptinhalt reduziert, PDFs über PDFKit).
  - W: `wikipedia_search(query, language)` und `wikipedia_article(title, language, section)` über die offizielle MediaWiki-API (ohne Schlüssel). Standard ist die Wikipedia in der Systemsprache; das Modell kann z. B. `en` wählen. Ein Artikel kommt als reiner Text mit der Liste seiner Abschnitte, einzelne Abschnitte lassen sich gezielt lesen; das spart Kontext.
  - Ist nur Wikipedia an, soll das Modell Sachfragen dort nachschlagen, bevor es antwortet.
- Bis zu 5 Runden mit je höchstens 3 Aufrufen, danach muss das Modell antworten. Wie viel Text die Ergebnisse haben dürfen, richtet sich nach der geladenen Kontextlänge (bei 8K etwa 4.000 Zeichen pro Seite).
- Über der Antwort zeigt z. B. „Wikipedia · 1 Suche · 1 Artikel gelesen“ die Schritte; aufgeklappt stehen dort alle Treffer, Seiten und Artikel als Links.
- In Folgefragen gehen die Adressen der genutzten Quellen mit, damit das Modell sie erneut öffnen kann.
- Seiten, die ohne JavaScript leer bleiben oder die App abweisen, liest auf Wunsch [Jina Reader](https://jina.ai/reader/) (`r.jina.ai`, ohne Schlüssel). Jina sieht dabei die Adresse. Abschaltbar unter Einstellungen → Websuche.
- DuckDuckGo hat keine offizielle API. Bei sehr vielen Anfragen in kurzer Zeit kann es eine Bot-Prüfung zeigen; die App meldet das dann als Fehler im Suchschritt.

## Sprache: Diktat & Vorlesen

- **Diktat** (⌘D oder Mikrofon im Eingabefeld, macOS 26): `SpeechAnalyzer` auf dem Gerät, Systemsprache. Der erkannte Text landet im Eingabefeld, noch unsichere Wörter stehen grau daneben. Senden beendet das Diktat und schickt alles ab. Beim ersten Mal fragt macOS nach dem Mikrofon; weil die App nur ad hoc signiert ist, kann das nach einem Neubau erneut passieren.
- **Vorlesen** (Lautsprecher unter jeder Antwort oder Rechtsklick): mit **Qwen TTS** (lokaler Dienst aus dem Projekt Auda, `http://127.0.0.1:8790`, Modell klein oder groß, 9 Stimmen) oder der **macOS-Stimme**. Code und Emojis werden übersprungen, Formeln in Worten gelesen („x hoch 2“, „a durch b“). Ist Qwen nicht erreichbar, liest die macOS-Stimme.
- Einstellungen → Sprache: Diktiermodus, Vorlese-Engine, Qwen-Stimme, Tempo, Pause im Gesprächsmodus.

## Gesprächsmodus

- **Starten**: Der dunkle Knopf mit der Welle links neben dem Senden-Pfeil im Eingabefeld (oder ⇧⌘D) startet das Gespräch. Vorher gewählte Persona oder Skills, Denkmodus und Suche gelten wie beim Tippen. Mit einer Persona zeigt das Fenster ihr Profilbild statt der Welle und spricht mit ihrer Stimme (siehe Personas). Im offenen Chat geht das Gespräch dort weiter, sonst entsteht ein neuer Chat.
- **Fenster**: Es wird schmal (beim ersten Mal 360 × 560 Punkte, danach in der zuletzt benutzten Größe), oben mittig an der alten Stelle. In der Mitte liegt eine animierte Welle: Sie schlägt aus, wenn das Modell spricht, beim eigenen Sprechen bleibt sie ruhig. Darunter steht, was die Spracherkennung verstanden hat. Beim Beenden bekommt das Fenster seine alte Größe zurück.
- **Ablauf**: Sprechen → nach einer Pause (Standard 1,2 s, einstellbar) geht der Text ab → das Modell antwortet und die App liest die Antwort vor, schon während sie geschrieben wird (satzweise, die Stimme erzeugt den nächsten Abschnitt, während der aktuelle läuft) → danach hört die App wieder zu. Während die Antwort läuft, ist das Mikrofon aus, damit die Stimme sich nicht selbst hört.
- **Steuerung**: Klick auf die Welle oder Leertaste: beim Zuhören sofort senden, während der Antwort unterbrechen und selbst sprechen. Mikrofon-Knopf: stummschalten. ✕ oder esc: Gespräch beenden.
- Für Antworten im Gespräch bekommt das Modell einen Zusatz im System-Prompt: kurz, natürlich, ohne Markdown, Listen, Tabellen oder Formeln. Folgefragen und Inhaltsverzeichnis werden währenddessen nicht erzeugt, damit das Modell frei ist; das Inhaltsverzeichnis folgt nach dem Gespräch. Alles Gesagte steht danach ganz normal im Chat.
- Erkennung wie beim Diktat (`SpeechAnalyzer`, macOS 26), Stimme wie beim Vorlesen (Qwen TTS oder macOS-Stimme, gleiches Tempo). Qwen braucht für den ersten Satz etwa 2 Sekunden; mit der macOS-Stimme beginnt die Antwort fast sofort.

## Writer Studio

Die erste der Applikationen (Menü „Applikationen“ rechts unter dem Eingabefeld; Presenter Studio und Notes folgen). Writer Studio ist eine Textverarbeitung, die als Markdown speichert.

- **Öffnen**: „Applikationen → Writer Studio“, das Dokument-Symbol oben in der Seitenleiste oder ⌃⌘N legen ein neues Dokument an. Der Chat löst sich auf, aus dem Eingabefeld wächst ein leuchtender Rahmen zur Seite auf, die Werkzeugleiste fällt Knopf für Knopf herein. ✕ oben rechts oder ein Klick auf einen Chat führt zurück.
- **Seitenleiste**: Dokumente stehen zwischen den Chats (mit Dokument-Symbol), lassen sich in Ordner ziehen, umbenennen und löschen. Der Titel folgt der ersten Zeile, bis man umbenennt. Ein neues Dokument, das leer bleibt, verschwindet wieder.
- **Seite**: dunkles Blatt oder, über den Schalter oben rechts, weißes Papier (gilt für alle Dokumente). Die Schrift des Dokuments und Schrift und Farbe einzelner Stellen siehe „Schriften, Farben & Sonderzeichen“.
- **Formatieren** (Werkzeugleiste oder Kürzel): Text, Kapitel, Überschrift 1–3, Code-Block, fett, kursiv, unterstrichen (gespeichert als `<u>…</u>`), durchgestrichen, Code im Text, Aufzählung, nummerierte Liste (mit Ein- und Ausrücken), Zitat, Link, Trennlinie.
- **Markdown beim Tippen**: `# `, `## `, `### `, `- `, `1. ` oder `> ` am Absatzanfang werden zur Überschrift, Liste oder zum Zitat. ⏎ in einem leeren Listenpunkt rückt aus bzw. beendet die Liste; ⌫ am Anfang eines formatierten Absatzes nimmt zuerst die Formatierung weg. Links öffnen sich mit ⌘-Klick.
- **Bilder** (Bild-Knopf in der Werkzeugleiste, Hineinziehen aus dem Finder oder Einfügen, z. B. ein Bildschirmfoto): Jedes Bild steht in einem eigenen Absatz, mittig, unter dem Absatz mit dem Cursor. Ein Klick wählt es aus und zeigt eine Leiste: Größe (Original, 33 %, 50 %, 75 %, 100 % der Spaltenbreite), Bildunterschrift, Entfernen. Doppelklick oder Rechtsklick bearbeitet die Unterschrift; im Rechtsklick-Menü auch „Im Finder zeigen“. Tippen hinter einem Bild beginnt einen neuen Absatz darunter, vor dem Bild einen darüber; ⌫ hinter einem Bild wählt es erst aus, der zweite Druck entfernt es. Die Dateien liegen in `Documents/Bilder/` (PNG und JPEG unverändert; HEIC, TIFF und sehr große Bilder werden zu PNG/JPEG umgewandelt) und gehen mit, wenn das letzte Dokument mit dem Bild gelöscht wird. Im Markdown: `![Unterschrift](Bilder/….png){width=50%}` (Pandoc-Schreibweise).
- **Tabellen** (Tabellen-Knopf: Raster zum Wählen der Größe, die erste Zeile ist der Kopf): Man schreibt direkt in die Zellen. ⇥ / ⇧⇥ springen zur nächsten / vorigen Zelle (⇥ in der letzten Zelle fügt eine Zeile an), ⏎ geht in die Zelle darunter und in der letzten Zeile aus der Tabelle heraus, ⇧⏎ bricht die Zeile innerhalb der Zelle (`<br>`). Mit dem Cursor in der Tabelle bietet der Knopf (und der Rechtsklick → „Tabelle“) Zeilen und Spalten einfügen oder löschen, die Ausrichtung der Spalte (links, zentriert, rechts) und „Tabelle löschen“. Löschen oder Einfügen über Zellgrenzen hinweg leert nur die Zellen, die Tabelle bleibt ganz; eine ganz markierte Tabelle verschwindet als Ganzes. Gespeichert wird eine Markdown-Tabelle mit Ausrichtung (`---:`).
- **Kopieren & Einfügen** innerhalb von Writer Studio behält die Formatierung (auch Bilder und Tabellen); aus anderen Programmen kommt reiner Text oder ein Bild. Ein einzeln ausgewähltes Bild geht auch als Bild in andere Programme.
- **Diktieren** (Mikrofon in der Werkzeugleiste, ⌘D oder Rechtsklick → „Hier diktieren“): Der Text landet an der Cursorposition. Was die Erkennung noch nicht sicher hat, steht grau im Text und wird nicht gespeichert. „Neuer Absatz“ oder „neue Zeile“ beginnen einen neuen Absatz. Unten auf der Seite zeigt eine Leiste den Pegel und einen Stopp-Knopf. Ohne offenes Dokument geht das Diktat wie bisher ins Eingabefeld des Chats.
- **Vorlesen** (Lautsprecher in der Werkzeugleiste, ⌥⌘L oder Rechtsklick): liest die Markierung, sonst ab dem Absatz mit dem Cursor, am Dokumentende das ganze Dokument. Code-Blöcke und Trennlinien werden übersprungen. Die Stelle, die gerade gelesen wird, ist hervorgehoben und scrollt mit: mit der macOS-Stimme der Satz, mit Qwen der Abschnitt. Kurze Absätze wie Listenpunkte fasst Qwen zusammen, damit nicht nach jeder Zeile eine neue Anfrage wartet. esc oder der Stopp-Knopf beenden. Stimme und Tempo kommen aus den Einstellungen. Diktieren und Vorlesen schließen sich aus, weil das Mikrofon sonst die Stimme hört.
- **Kapitel & Überschriften**: Über das Absatzformat (¶) oder ⌥⌘K wird ein Absatz zum Kapitel, die oberste Ebene über Überschrift 1–3. Im Markdown: `# Titel {.chapter}` (Pandoc-Schreibweise).
- **Inhaltsverzeichnis im Dokument** (Knopf in der Werkzeugleiste oder in der Seitenleiste): ein Block mit allen Kapiteln und Überschriften, der sich beim Schreiben selbst aktualisiert; ein Klick auf einen Eintrag springt hin. Sobald er im Dokument steht, ist das Dokument „formal“: Kapitel und Überschriften tragen Nummern (1, 1.1, 1.1.1 …), im Text links am Rand, im Block und in der Seitenleiste – und genau so im Export. Im Markdown: eine Zeile `[TOC]`.
- **Seitenleiste rechts** (⌥⌘I, wie im Chat): Reiter „Inhalt“ und „Lesezeichen“.
  - **Dynamisch**: Das gewählte Modell gliedert das Dokument in Themen mit Unterpunkten und einer Zusammenfassung (JSON-Schema wie beim Chat). Ab etwa 150 Wörtern entsteht es von selbst und wird neu erstellt, sobald nach einer Schreibpause genug Text dazugekommen ist; ↻ erstellt es jederzeit neu. Die Einträge springen zur Stelle, auch wenn sich der Text davor geändert hat (sie werden am Anfang ihres Absatzes wiedererkannt). Gespeichert im Kopf des Dokuments.
  - **Überschriften**: die eigenen Kapitel und Überschriften, eingerückt und (formal) nummeriert, sofort aktuell; die Überschrift, in der man gerade liest, ist markiert.
- **Dynamisches Inhaltsverzeichnis im Dokument**: Statt aus den Überschriften kann der Block im Dokument auch die Themen des Modells zeigen – über das Menü am Inhaltsverzeichnis-Knopf („Dynamisch – vom Modell gegliedert“), „Als Inhaltsverzeichnis einfügen“ in der Seitenleiste oder Rechtsklick auf den Block, wo man auch zwischen beiden Arten umschaltet. Es wird beim Einfügen erstellt und wächst danach mit dem Text (auch bei geschlossener Seitenleiste); Einträge springen zur Stelle. Überschriften werden dabei nicht nummeriert. Im PDF/LaTeX steht es an seiner Stelle mit Seitenzahlen und Links (vor dem Export wird es aktualisiert, wenn sich der Text geändert hat), im Markdown-Export als nummerierte Liste. Im Markdown: `[TOC]{.dynamic}`.
- **Lesezeichen** (⌥⌘B, Knopf in der Werkzeugleiste oder Rechtsklick → „Lesezeichen anlegen“): für die Markierung oder, ohne Markierung, den ganzen Absatz. Ein lila Zeichen rechts am Rand zeigt die Stelle. Die Liste in der Seitenleiste springt hin, benennt um und löscht. Lesezeichen wandern mit dem Text, weil sie im Markdown um die Stelle stehen: `<span id="lz-…" title="Name">…</span>`. Im Export und für die KI fallen sie weg.
- **Formeln** (Knopf √x, ⌥⌘E, Rechtsklick → „Formel einfügen“ oder `$$ ` am Zeilenanfang): ein visueller Formeleditor. In einer leeren Zeile entsteht eine abgesetzte Formel, mitten im Text eine Formel im Fließtext (umschaltbar). Ein Klick wählt eine Formel aus, ein Doppelklick öffnet sie wieder.
  - **Eingabe wie in MathQuill**: `/` macht aus dem Davorstehenden einen Bruch, `^` eine Hochzahl, `_` einen Index, `(`, `[`, `{` und `|` Klammern, die mitwachsen. Namen wie `sqrt`, `pi`, `alpha`, `sin`, `ln`, `sum`, `int` werden beim Tippen zu dem, was sie bedeuten; `\` beginnt einen beliebigen LaTeX-Befehl. Pfeiltasten wandern durch die Struktur (↑/↓ zwischen Zähler und Nenner, Hoch- und Tiefstellung, Matrixzeilen), ⇥ springt ins nächste leere Feld, ⌫ löscht in Strukturen hinein, ⇧⏎ beginnt eine neue Zeile, ⏎ übernimmt. Ein Klick in die Formel setzt den Cursor dorthin. ⌘Z/⌘⇧Z, ⌘C/⌘V (LaTeX) funktionieren im Editor.
  - **Palette** mit Grundlagen (Brüche, Wurzeln, Klammern, Betrag, Binomialkoeffizient …), Analysis (Summe, Produkt, Integrale, Grenzwert, Ableitungen), Funktionen, griechischen Buchstaben, Relationen und Pfeilen, Zahlenmengen, Matrizen, Vektoren, Determinante, Fallunterscheidung und Akzenten.
  - Das LaTeX ist darunter aufklappbar und editierbar; Formeln, die der Editor nicht zerlegen kann, bleiben unverändert.
  - Gezeichnet werden Formeln mit SwiftMath, im Markdown stehen sie als `$…$` bzw. `$$…$$`.
- **Plots** (im Formeleditor „Plot unter der Formel“, nur bei abgesetzten Formeln): Die Formel wird in numpy übersetzt und mit Python/matplotlib gezeichnet (eine Kurve pro Zeile, z. B. `f(x) = …` und `g(x) = …`). Bereich für x, y automatisch oder fest, Gitter, Breite und Bildunterschrift; freie Buchstaben wie `a` werden zu Parametern mit Regler. Die Vorschau folgt jeder Änderung, und wird die Formel später bearbeitet, wird der Plot neu gezeichnet. Im Dokument steht der Plot als Bild unter der Formel (auf dem dunklen Blatt in einer dunklen Fassung), im PDF als Vektorgrafik. Im Markdown: `![…](Bilder/plot-….png){width=70% .plot x=-5:5 y=auto …}`. Gebraucht wird Python 3 mit numpy und matplotlib (gesucht in `~/miniconda3`, `~/anaconda3`, Homebrew, `/usr/bin`). Summen, Integrale, Grenzwerte und Fakultäten werden noch nicht gezeichnet.
- **Speichern**: automatisch, kurz nach jeder Änderung, als Markdown-Datei mit kurzem Kopf (Titel, Schrift, Ordner, Art des Inhaltsverzeichnisses, dynamisches Inhaltsverzeichnis) in der geöffneten Bibliothek unter `Documents/<ID>.md`, Bilder und Plots daneben in `Bilder/`.
- **KI-Leiste**: Unten auf der Seite liegt immer eine schmale Eingabeleiste (⌘J). Die KI nutzt das gewählte Modell (unten links in der Seitenleiste).
  - **Ohne Markierung schreibt die KI an ihrem KI-Cursor**: eine lila Marke „KI“ im Seitenrand, mit Linie zur Stelle. Der Text streamt live ins Dokument und ist dabei hinterlegt. Danach steht der KI-Cursor am Ende ihres Textes, sodass „schreib weiter“ dort anknüpft, auch während man selbst woanders tippt. Anfangs sitzt er am Dokumentende; Rechtsklick → „KI-Cursor hierher setzen“ oder der Knopf links über der Leiste versetzen ihn. Je nach Stelle wird der Text ein neuer Absatz (am Absatzende, in einer leeren Zeile, vor einem Absatz) oder fließt in den Satz ein (mitten im Absatz). Der fertige Text ist ein einziger Rückgängig-Schritt (⌘Z).
  - **Mit Markierung** gehört die Markierung zur Anweisung: Die KI überarbeitet sie als Vorschlag, der in einer Karte über der Leiste erscheint (Ersetzen, Darunter einfügen, Nochmal, Vorlesen, Verwerfen). Die Originalstelle bleibt markiert, bis man entscheidet.
  - **Fragen** („Stimmt das?“, „Was meint …“, alles mit Fragezeichen oder Fragewort) beantwortet die KI in einer Karte, ohne das Dokument zu ändern; mit Markierung bezogen auf die Markierung. Die Antwort lässt sich vorlesen, kopieren oder am KI-Cursor einfügen.
  - Was mit der Anweisung passiert, zeigt die Leiste schon beim Tippen („schreibt am KI-Cursor“, „überarbeitet Markierung“, „antwortet“). Ihr Menü legt es fest und schaltet „Antworten vorlesen“ ein.
  - Das Mikrofon an der Leiste (oder ⌘D, wenn die Leiste den Fokus hat) diktiert die Anweisung; Senden während des Diktats wartet auf die letzten Worte.
- **Schnellaktionen** (über der Leiste und per Rechtsklick): Mit Markierung Umformulieren (neu, kürzer, länger, lockerer, formeller, einfacher), Ausformulieren (Stichpunkte → Fließtext), Prüfen und „Frage zur Markierung“. Ohne Markierung Weiterschreiben am KI-Cursor und das ganze Dokument prüfen.
- **Prüfen**: „Rechtschreibung & Grammatik“ oder „Plausibilität“ (falsche Fakten, Widersprüche, unlogische Schlüsse) für die Markierung oder das ganze Dokument. Das Modell bekommt den Text in Abschnitten (für Rechtschreibung kürzer, weil kleine Modelle in langen Stücken mehr übersehen) und antwortet per JSON-Schema. Die Fundstellen erscheinen in einem Panel rechts: Art, Original durchgestrichen, Korrektur, Erklärung, „Übernehmen“ oder „Ignorieren“, oben „Alle übernehmen“. Darüberfahren markiert die Stelle im Text. Fundstellen, die so nicht im Text stehen, verwirft die App.
- **Exportieren** (Teilen-Symbol oben rechts): als PDF (mit LaTeX gesetzt, wie der Chat-Export, Papierformat aus den Einstellungen), als LaTeX-Quelltext (.tex) oder als Markdown (.md, ohne den Kopf mit Titel und Schrift; Farben und Schriften bleiben als HTML-Spans) oder als reines Markdown (ohne sie). Unterstrichen wird in LaTeX zu `\uline{…}`. Bilder werden zu Abbildungen an ihrer Stelle, in ihrer Breite und mit nummerierter Unterschrift („Abbildung 1: …“); Tabellen behalten die Ausrichtung ihrer Spalten. Bei .tex und .md landen die Bilder in einem Ordner neben der Datei (`<Name>-Bilder/`). Formale Dokumente bekommen `\tableofcontents` und nummerierte Abschnitte, Dokumente mit Kapiteln werden als `report` mit `\chapter` gesetzt. Plots gehen als PDF in LaTeX; im Markdown-Export wird `[TOC]` zu einer verlinkten Liste der Überschriften.
- **Inhaltsanalyse** (Reiter „Dokument | Inhaltsanalyse“ oben neben dem Titel, ⌥⌘A wechselt): Das gewählte Modell liest das ganze Dokument und zeigt, was darin steht. Zuerst ein Überblick (Textsorte, Thema, Zusammenfassung, Kernaussagen, Schlüsselbegriffe), dann je nach Textsorte:
  - **Argumentation**: Hauptthese, jedes Argument in Standardform (Prämissen P1, P2 … über dem Strich, Konklusion darunter, Schlussart wie deduktiv, induktiv, kausal), fehlende Prämissen ergänzt das Modell als „implizit“; Einwände mit der Erwiderung des Textes und eine kurze Einschätzung (Stärken, Schwächen). Dazu eine **Argumentkarte**: Prämissen → Konklusion → Hauptthese, Einwände rot, Erwiderungen grün.
  - **Figuren & Handlung** (Erzählungen): Erzählperspektive, Zeit, Konflikt, die Figuren mit Rolle und Beschreibung, Schauplätze und Motive; als Diagramme die **Figurenkonstellation** (Beziehungen als beschriftete Pfeile) und der **Handlungsverlauf** (Ereignisse in Textreihenfolge, nach Schauplätzen zu Szenen gruppiert).
  - **Gliederung** (Beschreibungen, Anleitungen, Berichte): der Gegenstand mit seinen Bereichen, Punkten und Aufzählungen als Baum, Abläufe als Schrittfolge und Zusammenhänge zwischen Begriffen als Netz.
  - Die Teile oben in der Leiste: vorhandene springen hin, fehlende („+ Argumentation“ …) werden ergänzt, auch wenn die Textsorte sie nicht nahelegt. „Neu analysieren“ erstellt alles neu; hat sich der Text seit der Analyse geändert, sagen das ein Punkt am Reiter und ein Hinweis.
  - Ein Klick auf ein Kästchen im Diagramm, eine Prämisse, eine Figur oder einen Einwand springt zur Stelle im Dokument. Jedes Diagramm lässt sich vergrößern (Zoom mit dem Trackpad) und sein Mermaid-Code kopieren.
  - So funktioniert es: Jeder Teil ist eine Anfrage mit eigenem JSON-Schema (Reihenfolge der Felder festgelegt); das Modell liefert nur Inhalte mit Absatznummern, die Diagramme baut die App daraus als [Mermaid](https://mermaid.js.org)-Code, damit sie immer gültig sind. Gezeichnet wird mit dem mitgelieferten mermaid.js (11.17.2, MIT) in einer unsichtbaren Web-Ansicht, ohne Internet. Das Dokument steht vor der Aufgabe, damit LM Studio es für den nächsten Teil nicht neu lesen muss. Passt das Dokument nicht in den Kontext des Modells, werden die Absätze gekürzt (Hinweis oben). Gespeichert wird die Analyse neben dem Dokument in `Documents/Inhaltsanalysen/<ID>.json`.
- **Schriften, Farben & Sonderzeichen**:
  - **Schrift** (Knopf „Aa“ links in der Werkzeugleiste): Ein Umschalter wählt, ob die Schrift für die **Auswahl** (oder den Text ab dem Cursor) oder für das **ganze Dokument** gilt; die Liste zeigt jede Schrift in sich selbst. Zur Wahl stehen die Systemschriften (New York, SF Pro, SF Pro Rounded, SF Mono) und, soweit auf diesem Mac vorhanden, Georgia, Palatino, Charter, Baskerville, Hoefler Text, Times New Roman, Cochin, Didot, Arial, Gill Sans, Optima, Futura, Verdana, Courier New, American Typewriter und Monaco. „Wie das Dokument“ nimmt eine Schrift der Stelle wieder weg.
  - **Farbe** (Knopf „A“ mit Farbbalken): neun Farben, die auf dunklem Papier heller erscheinen als im Druck (die gespeicherte Farbe ist die für weißes Papier, auf dunklen Folien und dunklem Blatt wird sie aufgehellt, damit sie lesbar bleibt), „Standardfarbe“ und „Eigene Farbe“ für jede beliebige. Gilt in Dokumenten, Folien und Tabellenzellen; Code hat keine eigene Farbe.
  - **Gespeichert** wird beides als HTML im Markdown: `<span style="color:#C0392B;font-family:'Georgia'">…</span>` (die Systemschriften als `ui-serif`, `system-ui`, `ui-rounded`, `ui-monospace`). Andere Markdown-Programme zeigen das meist an oder ignorieren es; Lesezeichen und Farben dürfen sich ineinander verschachteln. Die Schrift des ganzen Dokuments steht im Kopf (`font:`).
  - **Zurück zu reinem Markdown**: Teilen → „Als reines Markdown (ohne Farben, Schriften) …“ schreibt den Text ohne diese Spans (auch ohne Lesezeichen und ohne `<u>`); „Als Markdown (.md)“ behält sie.
  - **Sonderzeichen** (Knopf neben der Trennlinie, ⌃⌘Leertaste): macOS' Zeichenpalette mit Pfeilen, griechischen Buchstaben, Mathesymbolen und Emoji. Im LaTeX-Druck setzen Griechisch, Pfeile und mathematische Symbole die Mathe-Schrift, Emoji fallen weg.
- **Drucken** (⌘P, Ablage → „Drucken …“ oder Teilen → „Drucken …“): Ein Dokument wird zuerst mit LaTeX gesetzt, genau wie der PDF-Export, und dann im macOS-Druckfenster gezeigt – mit Vorschau, Drucker, Seiten pro Blatt und „Als PDF sichern“. So erscheinen Schrift, Farben, Formeln und eingefärbter Code im Druck wie auf dem Bildschirm. Eine Präsentation druckt die Folien (Querformat) – mit „Seiten pro Blatt“ im Druckfenster entsteht ein Handzettel.
- **LaTeX: was unterstützt wird** (Satz mit Tectonic oder XeLaTeX):
  - **Schriften**: jede auf dem Mac installierte Schrift wird über ihren Namen geladen (`fontspec`), im PDF erscheint also dieselbe Schrift wie im Editor, auch die Schrift einzelner Stellen (`\llmdfont…`). Fett und kursiv kommen aus der Schriftfamilie. Nur die Systemschriften (New York, SF Pro, SF Pro Rounded, SF Mono) lassen sich nicht laden, weil sie variable Schriften sind; sie werden in Iowan Old Style, Helvetica Neue, Avenir Next und Menlo gesetzt (die Liste nennt es: „im Druck: …“). Fehlt eine Schrift, bleibt LaTeX' eigene (Latin Modern). Code steht in Menlo.
  - **Farben**: `\textcolor[HTML]{…}` (xcolor), auch in Listen, Tabellen und Überschriften; Unterstreichen und Fett laufen sauber über Absatzteile hinweg.
  - **Formeln**: Der Formeleditor erzeugt LaTeX, das unverändert in den Satz geht (amsmath, `unicode-math`, Latin Modern Math). Der Editor zeigt Formeln mit SwiftMath, das nicht jeden Befehl kennt; im PDF funktioniert auch, was er nur als Quelltext zeigt. Formeln, die LaTeX ablehnt, werden als Code gesetzt, damit das PDF immer entsteht.
  - **Code**: Python und SQL werden farbig gesetzt (Verbatim mit `fvextra`; Zeilen brechen an Leerzeichen).
  - **Bilder, Plots, Flussdiagramme** als Abbildungen mit Unterschrift; Plots und Flussdiagramme als Vektorgrafik (PDF).
  - **Nicht** unterstützt: eigene LaTeX-Befehle im Text (Markdown-Zeichen wie `\` und `$` werden geschützt, damit nichts versehentlich als Befehl gilt), Farben in Formeln, Schriftgrößen pro Stelle.
- **Code** (Python und SQL): In einem Code-Block (⌥⌘C) wählt der Knopf neben dem Absatzformat die Sprache; ohne Wahl erkennt die App eindeutigen Python- und SQL-Code selbst. Die Sprache steht hinter dem Zaun (```` ```python ````).
  - **Einfärben**: Schlüsselwörter, Zeichenketten, Zahlen, Kommentare, Funktionen, Dekoratoren, eingebaute Namen; auf dunklem Blatt, hellem Papier, in Folien und im LaTeX-Druck. Zwei Code-Blöcke hintereinander bleiben zwei, jeder mit seiner Sprache.
  - **Einrücken**: ⏎ rückt die nächste Zeile wie die vorige ein, in Python nach einem Doppelpunkt oder einer öffnenden Klammer eine Stufe weiter, nach `return`, `pass`, `break`, `continue` und `raise` eine zurück. ⇥ rückt auf den nächsten Vierer-Schritt ein, bei Markierung alle Zeilen; ⇧⇥ rückt aus. ⏎ in einer Zeile, die nur Einrückung enthält, beendet den Block.
  - **Formatieren** (⌥⇧⌘F, Rechtsklick oder das Menü neben der Sprache): Python bekommt Einrückung in Vierer-Schritten, keine Tabs und Leerzeichen am Zeilenende, höchstens zwei Leerzeilen hintereinander (Zeichenketten und Klammerinhalt bleiben unberührt); SQL bekommt Schlüsselwörter in Großbuchstaben und eine Zeile je Klausel (`SELECT`, `FROM`, `JOIN`, `WHERE`, `GROUP BY`, …), Spalten untereinander, eingerückte `AND`/`OR` und Unterabfragen in Klammern.
- **Formel → Python**: Rechtsklick auf eine Formel → „In Python-Code übersetzen“, oder im Formeleditor der Schalter „Python-Code unter der Formel“ (mit Vorschau). Aus `E = m c^2` wird `def E(m, c): return m * c ** 2`; die Funktion heißt wie die linke Seite, freie Buchstaben werden Parameter (in der Reihenfolge ihres Auftretens), griechische Buchstaben und Indizes werden zu Namen (`x_{1,2}` → `x_1`/`x_2`, `\lambda` → `lambda_`). Verstanden werden Brüche, Wurzeln, Potenzen, Betrag, Fakultät und Binomialkoeffizient, Winkel- und Exponentialfunktionen (`math`), Summen und Produkte, Integrale (`scipy.integrate.quad`), Fallunterscheidungen und ± (zwei Ergebnisse); mehrere Zeilen werden zu den Schritten einer Funktion, `f(x) = …` zu einer eigenen. Der Code steht als Python-Block unter der Formel (und ihrem Plot); eine erneute Übersetzung ersetzt ihn. Was die Übersetzung nicht versteht (Grenzwerte, Matrizen, Ableitungen), meldet sie, statt zu raten. Im Formeltext kommt nur im Docstring etwas aus dem Dokument vor, nie als Code. Gilt auch für Folien.
- **Code-Ablauf in der Inhaltsanalyse**: Hat ein Dokument (oder eine Präsentation) Python- oder SQL-Blöcke, steht in der Inhaltsanalyse – auch ohne Analyse und ohne Modell – der Teil „Code-Ablauf“ mit **Flussdiagrammen: was passiert im Code?**
  - **Python**: das Hauptprogramm und jede Funktion (und Methode) als eigenes Diagramm: Anweisungen, Verzweigungen (`if`/`elif`/`else`, Ja/Nein), Schleifen (`for`, `while`, mit `break` und `continue`), `try`/`except` (der `try`-Teil in einem Kasten, Pfeile „Fehler: …“), Ein- und Ausgabe, `return` und `raise`. Der Code wird gelesen (Einrückung), nicht ausgeführt.
  - **SQL**: ein Diagramm je Anweisung, wie die Datenbank sie abarbeitet: Tabellen, Joins, Filter (`WHERE`), Gruppieren, `HAVING`, Spalten, Sortieren, Begrenzen; Common Table Expressions und Unterabfragen in Kästen; `UNION`, `INSERT`, `UPDATE`, `DELETE`, `CREATE`.
  - **Übernehmen**: „Ins Dokument übernehmen“ legt das Diagramm als Bild unter den Code-Block (hell und dunkel für das Blatt, als Vektorgrafik für LaTeX; eine Unterschrift „Ablauf: …“; im Markdown `{… .diagram}`); nochmaliges Übernehmen ersetzt es. In einer Präsentation entsteht dafür eine neue Folie hinter der Folie mit dem Code, das Diagramm auf weißem Grund, damit es auf jedem Hintergrund lesbar ist.
- **Präsentation aus Dokument** (Ablage → „Präsentation aus Dokument …“ ⌥⌘P, oder Teilen → „Präsentation aus diesem Dokument …“): aus einem Dokument der Bibliothek oder einer Datei (Markdown, Text, Word, RTF, PDF, HTML) wird eine Präsentation.
  - **Gliederung**: Aus den Überschriften werden Kapitel und Folien – Kapitel (`{.chapter}`) sind Kapitelfolien, Überschrift 1 (oder 2) Folien, tiefere Überschriften gehören zur Folie darüber. Ein Text ohne brauchbare Überschriften gliedert das Modell selbst in Kapitel und Folien über nummerierte Absätze. Word- und RTF-Dateien verlieren ihre Formatvorlagen; große oder fette kurze Zeilen werden dort zu Überschriften.
  - **Inhalt**: Das Modell fasst den Text jedes Abschnitts in 3 bis 5 Stichpunkten zusammen (nur, was im Text steht). Die ersten **Formeln, Code-Blöcke und Tabellen** eines Abschnitts und sein erstes **Bild** kommen unverändert auf seine Folie (abschaltbar); mit solchen Objekten bleiben es höchstens drei Stichpunkte.
  - **Moderatorenkarten**: Zu jeder Folie schreibt das Modell einen Sprechtext, gestützt auf den Text des Abschnitts, nicht nur auf die Stichpunkte.
  - **Automatisch präsentieren**: Auf Wunsch startet danach das Vorführen im Vollbild, die KI trägt Folie für Folie vor und schaltet selbst weiter.
  - Die Präsentation ist sofort offen, die Folien füllen sich nacheinander; „Stopp“ hält an, „Rückgängig“ räumt auf.
- **Geplant**: Citations Studio.

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `Sources/LLMDesigner/App` | App-Einstieg, Menübefehle, Fenster-Konfiguration, geöffnete Bibliothek und Wechsel (`LibrarySession`) |
| `Sources/LLMDesigner/Core` | `AppLibrary` (Bibliothek: Paket, Einstellungen, Liste der zuletzt geöffneten, Übernahme alter Daten), `AppModel` (Zustand, Generierung mit Tool-Runden, Abzweigen, Export), `AppModel+Context` (Kontextlänge laden, Belegung schätzen), `AppModel+Thalamus`, `Thalamus` und `ThalamusConsolidation` (Gedächtnis: einordnen, verdichten, Profil, Erinnern), `AppModel+Library` (Ordner, Skills), `Library` (Datenmodell und Ablage von Ordnern und Skills), `AppModel+Personas` und `Persona` (Personas: Datenmodell, Ablage, Profilbild, Text aus Dokumenten), `PersonaFileTools` (Suchen und Lesen in den Dateien einer Persona), `LMStudioClient`, `ChatStore`, Writer Studio (`WriterDocument`: Dokument und Ablage, `WriterMarkdown`: Markdown ↔ formatierter Text samt Tabellenzellen, `WriterImages`: Bild-Syntax, Bildablage und Bild-Attachment, `WriterEmbeds`: Formel- und Inhaltsverzeichnis-Attachment, Überschriften und Nummerierung, Lesezeichenliste, `DocumentOutline`: dynamisches Inhaltsverzeichnis, Inhaltsanalyse (`ContentAnalysis`: Datenmodell und Ablage, `ContentAnalysisBuilder`: Anfragen, Schemas, Antworten, `ContentAnalysisDiagrams`: Mermaid-Code und Farben, `MermaidRenderer`: SVG aus mermaid.js, `AppModel+Analysis`), `WriterPrompts`: Prompts, Prüf-Schema und Aufräumen der KI-Antworten, `AppModel+Writer`), Formeleditor (`Math/MathTree`: Formelbaum, LaTeX lesen und schreiben, `Math/MathEditing`: Eingaberegeln und Cursor, `Math/MathPlot`: Übersetzung nach numpy und Zeichnen mit matplotlib), Applikationen (`StudioApplication`), Bildablage (`Attachments`), Datenmodelle, Markdown-Parser, Formel-Erkennung, LaTeX-Export, Inhaltsverzeichnis, Folgefragen, Lesezeichen, Web- und Wikipedia-Suche (`WebTools`, `WebSearch`, `Wikipedia`) |
| `Sources/LLMDesigner/Core/Speech` | Diktat (`SpeechAnalyzer`), Vorlesen (Qwen TTS / `AVSpeechSynthesizer`), Text für die Sprachausgabe, Gesprächsmodus (`ConversationSession`: Gesprächsablauf und Satzende-Erkennung; `ConversationVoice`: Sprachausgabe während des Schreibens mit Lautstärkeverlauf für die Welle) |
| `Sources/LLMDesigner/UI/Writer` | Writer Studio: Bildschirm mit Werkzeugleiste, Öffnungsanimation und Audio-Leiste (`WriterScreen`), Diktat, Vorlese-Skript und Kontextmenü (`WriterTextView+Speech`), KI-Cursor, Schreiben in den Text, Vorschläge und Fundstellen (`WriterTextView+Assistant`), der Assistent (`WriterAssistant`) mit Leiste, Karten und Prüf-Panel (`WriterAssistantViews`), Editor (`WriterTextView`: Seite, Befehle, Tasten, Kopieren; Tabellen mit Zellschutz `WriterTextView+Tables`; Bilder mit Leiste und Zeichnung `WriterTextView+Images`; Formeln und Plots `WriterTextView+Math`; Gliederung, Inhaltsverzeichnis-Block, Sprünge und Lesezeichen `WriterTextView+Outline`; Formeleditor `FormulaEditor`; Seitenleiste `DocumentPanel`; Inhaltsanalyse `ContentAnalysisView`, ihre Leiste und der Reiter `ContentAnalysisToolbar`, Diagramme `MermaidDiagramView`; `WriterLayoutManager` zeichnet Aufzählungszeichen, Zitatbalken und Code-Hintergrund), Aussehen aus der Bedeutung (`WriterStyle`), Anbindung an SwiftUI (`WriterEditor`) |
| `Sources/LLMDesigner/UI` | Seitenleiste (Chats, Skills, Personas, Ordner), Skill-Editor (`SkillLibraryScreen`), Skill-Auswahl im Composer (`SkillPicker`), Persona-Editor (`PersonaLibraryScreen`), Gedächtnis- und Kontext-Kapsel unter dem Eingabefeld (`ChatSetupBar`), Thalamus über der Antwort und im Persona-Editor (`ThalamusViews`), Profilbild und Persona-Auswahl (`PersonaViews`), Lichtschein im Gesprächsmodus (`PersonaHalo`), Chat, Composer, Gesprächsansicht mit Welle (`ConversationView`), Bildansichten, Denk-Anzeige (`ThinkingView`), Modell-Auswahl, Markdown- und Formel-Renderer, Einstellungen |
| `Vendor/SwiftMath` | Angepasste Kopie von SwiftMath (LaTeX-Satz) |
| `Resources/Mermaid` | mermaid.js 11.17.2 (`dist/mermaid.min.js`, MIT) für die Diagramme der Inhaltsanalyse; `build-app.sh` legt es ins App-Paket |

Alle Daten liegen in der geöffneten Bibliothek (siehe „Bibliotheken“): Chats als JSON in `Chats/`, angehängte Bilder in `Attachments/`, Chat-Ordner in `ChatFolders.json`, Skills samt ihren Ordnern in `Skills.json`. Jede Persona hat einen eigenen Ordner `Personas/<ID>/` mit `persona.json`, dem Profilbild, `files/` (Kopien ihrer Dateien), `text/` (ausgelesener Text) und `thalamus.json` (Datenbank des Gedächtnisses).

## Tastenkürzel

| Kürzel | Aktion |
| --- | --- |
| ⏎ / ⇧⏎ | Senden / neue Zeile |
| ⌘N | Neuer Chat |
| ⌃⌘N | Neues Dokument (Writer Studio) |
| ⌥⌘N / ⌥⇧⌘N / ⇧⌘N | Neuer Skill / neue Persona / neuer Ordner |
| ⌘1 / ⌘2 / ⌘3 | Seitenleiste: Chats / Skills / Personas |
| ⇧⌘P | Persona für den Chat wählen |
| ⇧⌘K | Skills für den Chat wählen |
| ⌃⌘S | Seitenleiste ein-/ausblenden |
| ⌘. | Generierung stoppen |
| ⇧⌘R | Antwort neu generieren |
| ⌘R | Modelle aktualisieren |
| ⌘D | Diktieren / Diktat beenden |
| ⇧⌘D | Gesprächsmodus starten / beenden |
| Leertaste / esc | Im Gesprächsmodus: sofort senden bzw. unterbrechen / Gespräch beenden |
| ⇧⌘A | Bilder anhängen |
| ⇧⌘T | Denkmodus ein/aus |
| esc | Bearbeiten einer Frage abbrechen |
| ⇧⌘E / ⌥⇧⌘E | Chat exportieren / mit Inhaltsverzeichnis |
| ⌥⌘I | Inhaltsverzeichnis-Panel ein-/ausblenden (Chat und Writer Studio) |
| ⌘B / ⌘I / ⌘U / ⇧⌘X | Writer Studio: fett / kursiv / unterstrichen / durchgestrichen |
| ⌘E / ⌘K | Writer Studio: Code im Text / Link |
| ⌥⌘0 / ⌥⌘K / ⌥⌘1–3 / ⌥⌘C | Writer Studio: Text / Kapitel / Überschrift 1–3 / Code-Block |
| ⌥⌘E | Writer Studio: Formel einfügen oder bearbeiten |
| ⌥⌘B | Writer Studio: Lesezeichen anlegen / entfernen |
| ⇧⌘8 / ⇧⌘7 / ⇧⌘9 | Writer Studio: Aufzählung / nummerierte Liste / Zitat |
| ⇥ / ⇧⇥ | Writer Studio: Listenpunkt ein- / ausrücken; in Tabellen nächste / vorige Zelle |
| ⏎ / ⇧⏎ in Tabellen | Writer Studio: Zelle darunter (letzte Zeile: aus der Tabelle) / Zeilenumbruch in der Zelle |
| ⌘D / ⌥⌘L / esc | Writer Studio: ins Dokument diktieren / vorlesen / Vorlesen stoppen |
| ⌘J | Writer Studio: in die KI-Leiste (esc zurück in den Text) |
| ⌥⌘A | Writer Studio: zwischen Dokument und Inhaltsanalyse wechseln |
| ⌘P | Drucken (Writer Studio: mit LaTeX gesetzt; Presenter Studio: die Folien) |
| ⌥⌘P | Präsentation aus einem Dokument oder einer Datei erstellen |
| ⌥⇧⌘F | Writer Studio: Code-Block formatieren (Python, SQL) |
| ⌃⌘Leertaste | Writer Studio: Zeichenpalette (Sonderzeichen, Symbole, Emoji) |
| ⇥ / ⇧⇥ im Code | Writer Studio: auf den nächsten Vierer-Schritt einrücken / ausrücken |
