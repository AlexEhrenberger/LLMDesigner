# Weiterentwicklung: Was LLM Designer als Nächstes mehr Wert gibt

_Vorschlag von Claude Code · Stand: 08.11.2026 · Basis-Commit: `6405152`_
_Status: **entschieden am 08.11.2026**. Die Umsetzung steht in [Epics](Epics.md): E1 Agentenzentrale, E2 Tempo, E3 Projektseite mit Rezepten, E4 IU-Paket._

---

## 0. Kurzfassung

LLM Designer kann inzwischen sehr viel: rund 100 000 Zeilen Swift, vier Studios, 489 Actions, Terminal, MCP und Werkzeuge im Chat. Was fehlt, ist kaum noch ein weiteres Werkzeug. Es fehlt der **Rahmen, in dem die Werkzeuge ohne dich zusammenarbeiten**: Aufträge, die einen Neustart überleben, Freigaben, die warten können, und ein Ort, an dem alles liegt, was zu einem Vorhaben gehört.

**Die Top 3:**

1. **Agentenzentrale.** Aufträge statt einzelner Aufrufe, ein Freigaben-Eingang statt modaler Dialoge, ein Verlauf mit Schnappschüssen und eine gemeinsame Warteschlange für das Modell. Das ist das Fundament für alles Unbeaufsichtigte (nachts, unterwegs, später der Hub) und beantwortet die Frage nach der Übersicht über Agenten.
2. **IU-Paket für Writer, Citation und Presenter.** Vorlagen für Hausarbeit, Fallstudie und Bachelorarbeit, Titelblatt, nummerierte Abbildungen und Tabellen mit Quellenzeile, Verzeichnisse, ein IU-Zitierstil und eine Formalprüfung vor der Abgabe. Das bringt dir im Studium sofort etwas und läuft ohne großes Modell.
3. **Projekte mit Rezepten.** Eine Projektmappe für ein Vorhaben (Dokumente, Folien, Quellen, Chats, Termine, später Mails) und feste Abläufe wie „Recherche → Quellen → Dokument → Präsentation → Podcast“, die als Aufträge laufen.

**Unterwegs:** Eine iOS-App lohnt sich jetzt noch nicht. Zuerst ein **Briefkasten über iCloud Drive mit Kurzbefehlen** (0 €, kein offener Port, keine iOS-App), später mit dem Hub eine Weboberfläche über Tailscale. Eine native App kostet mindestens 99 US-Dollar im Jahr und braucht Xcode (Abschnitt 5).

---

## 1. Was ich im Code gesehen habe

| Bereich | Befund | Fundstelle |
|---|---|---|
| Aktivität | Das Aktivitätsfenster zeigt eine flache Tabelle von Action-Aufrufen, nur im Speicher (500 Einträge), ohne Gruppierung nach Lauf, ohne Fortschritt und ohne Verweis auf das Ergebnis. Die Spalten zeigen Action-IDs und die Buchstaben A/B: Das passt für die Fehlersuche, aber nicht zum Verstehen, was ein Agent gerade tut. | `Actions/ActionLog.swift`, `UI/Actions/ActionViews.swift` |
| Freigaben | Die Rückfrage ist ein modaler `NSAlert`. Ein Agent, der nachts läuft, bleibt an der ersten Frage stehen, und vom iPhone aus lässt sie sich nicht beantworten. | `Actions/ActionApproval.swift:46` |
| Rückgängig | „Antwort rückgängig“ gilt nur, solange die App läuft. Für unbeaufsichtigte Läufe fehlt ein Zustand, auf den man auch morgen noch zurückgehen kann. | `docs/actions.md` |
| Modell | 14 Dateien rufen das Modell direkt auf, eine gemeinsame Warteschlange gibt es nicht. Auf 16 GB kämpfen Thalamus, Gliederung, Themenstapel, Writer-KI, Agent und Qwen TTS um dieselbe GPU. Einige lange Aufgaben (Verdichtung, Gliederung, Moderatorenkarten) weichen, wenn du schreibst, aber eine gemeinsame Regel für alle gibt es nicht. | `grep -rln ".complete(" Core UI Actions`, `AppModel.swift:685` |
| Tempo | Nach jeder Tipp-Pause (350 ms) wandelt der Editor das **ganze** Dokument in Markdown und schreibt es in `documents[i]`. Alles, was `app.documents` liest (Seitenleiste, Power-Panel, Menüs), wird dadurch ungültig. Das ist dasselbe Muster, das beim Streaming schon `LiveAnswer` nötig gemacht hat. Beim Start lädt die App außerdem alle Chats und Dokumente vollständig. | `UI/Writer/WriterEditor.swift:536`, `Core/AppModel+Writer.swift:138`, `Core/AppModel.swift:597` |
| Zitieren | Der Stil heißt „APA 7 deutsch“ und schreibt „Müller u. a.“. Der IU-Leitfaden verlangt ab drei Autor:innen „et al.“ und bei direkten **und** indirekten Zitaten eine Seitenangabe. | `Core/Citations/CitationModel.swift:454` |
| Writer | Es gibt keine Dokumentvorlagen, kein Titelblatt, keine nummerierten Beschriftungen („Abb. 3“), kein Abbildungs- oder Tabellenverzeichnis, keine Querverweise, keine römischen Seitenzahlen und keine Versionen. Eigene Seitenformate, Kopf- und Fußzeilen sowie Arial sind schon da. | `Core/WriterPageSetup.swift`, `Core/WriterFonts.swift` |
| Presenter | Am Ende einer Präsentation entsteht kein Literaturverzeichnis (die IU verlangt eines). Der Vortrag mit Stimme läuft nur live: Es gibt weder Audiodatei noch Video. | `Core/Presenter/`, `UI/Presenter/` |
| Citation | Anhänge öffnen im Programm Vorschau. Einen eingebauten PDF-Leser, in dem Markieren einen Wissensbaustein mit Seite ergibt, gibt es nicht; der Entwurf vom 15.10. hatte ihn vorgesehen. | `UI/Citations/CitationSourceDetail.swift:372` |
| Stories | Die Abschnitts-Dokumente lassen sich nicht zum Manuskript zusammenführen, es gibt keine Wortziele, und die KI-Actions `stories.ai.*` sind zurückgestellt. | `Actions/Stories/` |

**Stark sind:** die native Oberfläche, dass alles lokal bleibt, die Sicherheitsregel im Code statt im Prompt, der Präfix-Cache, der Power-Zugriff und die Suchleiste. Auf dieser Grundlage lohnt es sich weiterzubauen; ein Umbau ist nicht nötig.

---

## 2. Bewertung nach deinen Fragen

### 2.1 Ist die Oberfläche optimal?

Einzeln sind die Teile gut, als Ganzes wird es langsam unübersichtlich. Viele Funktionen findet man nur, wenn man weiß, in welchem Menü sie stehen. Vorschläge:

- **Startseite „Heute“**, wenn nichts geöffnet ist: laufende Aufträge, offene Freigaben, zuletzt bearbeitet, nächste Abgabetermine (aus den Projekten). Heute ist die Mitte dann leer oder zeigt den letzten Chat.
- **Befehlspalette im Fenster (⌘K)**: Alle 489 Actions haben schon Namen, Beschreibung und Schema. Daraus lässt sich fast ohne neuen Code eine Palette machen („Literaturverzeichnis einfügen“, „Folie teilen“, „Als PDF exportieren“). Das ist die billigste Abhilfe dafür, dass man Funktionen nicht findet. (⌘⇧K ist schon für Zitate belegt.)
- **Ein Ort für Hintergrundarbeit**: Gliederung, Bildgenerierung, Vorlesen, Verdichtung und Agenten zeigen ihren Zustand heute jeweils an einer anderen Stelle. Das sollte in die Agentenzentrale (Top 1).
- **Einstellungen mit Suche**, sobald sie weiter wachsen.

### 2.2 Lässt sich die Oberfläche beschleunigen?

Ja, aber zuerst messen. Die Kandidaten sind Vermutungen aus dem Code, keine Messungen:

1. **Dokumenttext aus dem beobachteten Array nehmen.** Wie beim Streaming (`LiveAnswer`) sollte der Text des offenen Dokuments in einem eigenen Objekt liegen. `documents` bekommt nur noch Titel und Datum, und das nicht bei jeder Pause. Messen: ein Dokument mit 60 Seiten, tippen, `sample <pid>` während der Pausen.
2. **Nur den geänderten Block umwandeln.** Die Actions tun das schon („nur der betroffene Block wird umgewandelt“). Der Editor wandelt nach jeder Pause noch alles. Bei einer Bachelorarbeit macht das bei jeder Pause zehntausende Zeichen.
3. **Chats beim Start nur mit Kopfdaten laden** (Titel, Datum, Ordner), die Nachrichten erst beim Öffnen. Das hilft beim Start und beim Speicher, und 16 GB sind mit Modell und TTS knapp.
4. **Eine Warteschlange für das Modell** (Teil von Top 1): Wenn nicht drei Aufrufe gleichzeitig auf der GPU landen, antwortet der Chat schneller, obwohl das Modell gleich schnell bleibt.

### 2.3 Habe ich die Agenten optimal im Blick?

Nein, das ist der größte Hebel. Das Protokoll beantwortet die Frage „Welche Action lief um 14:02?“. Wer einen Agenten arbeiten lässt, will aber wissen: **Was macht er gerade, was hat er fertig, worauf wartet er, und wie nehme ich das zurück?** Details in Abschnitt 4.1.

### 2.4 Writer Studio und ein anderer Ansatz

Für Romane und freie Texte passt der Ansatz „WYSIWYG auf Markdown“. Für wissenschaftliche Arbeiten schlage ich **zusätzlich** einen anderen Arbeitsweg vor, den **Belege-Schreibtisch**:

1. Forschungsfrage und Gliederung (höchstens drei Ebenen, wie die IU es verlangt).
2. Zu jedem Abschnitt eine Kernaussage und die passenden Wissensbausteine aus Citation Studio, per Ziehen oder von der KI vorgeschlagen.
3. Die KI formuliert **einen Abschnitt** aus genau diesen Belegen, mit Zitations-Pillen.
4. Du überarbeitest; die Belegprüfung (Abschnitt 3, Rang 4) sagt, ob jede Pille zur Aussage passt.

Das passt gut zu kleinen Modellen: Jeder Aufruf sieht nur einen Abschnitt und seine Belege, nie das ganze Dokument. Es passt auch zur IU-Regel, dass jedes Zitat nachprüfbar sein muss.

Außerdem für Writer:

- **Vorschlagsmodus**: Änderungen der KI oder eines Agenten erscheinen als Vorschläge, die du annimmst oder ablehnst, statt direkt im Text zu landen. Für unbeaufsichtigte Läufe ist das sicherer als Rückgängig.
- **Versionen**: ein Schnappschuss vor jedem Agentenlauf und auf Knopfdruck („Stand vor der Abgabe“), mit Vergleich.
- **Querverweise** („siehe Abb. 3“, „Kapitel 2.1“), die sich beim Umsortieren mitnummerieren.

### 2.5 Presenter Studio

- **Literaturfolie automatisch** aus den Zitations-Pillen der Folien. Die IU verlangt auf den Folien Kurzbelege und am Ende ein Literaturverzeichnis.
- **Vertonte Präsentation als Datei**: Jede Folie bekommt ihre gesprochene Moderation als Audiodatei. Daraus wird ein Video (MP4 über AVFoundation, ohne Fremdabhängigkeit) oder ein Podcast. Qwen TTS braucht auf dem M1 etwa so lange, wie der Text dauert, plus 2 s je Stück. Das gehört deshalb als Auftrag in die Nacht.
- **Probemodus** mit Stoppuhr je Folie und Zielzeit (Referate haben Zeitvorgaben).
- **Präsentation ⇄ Dokument in beide Richtungen** mit Herkunftsverknüpfung: Ändert sich das Dokument, zeigt die Präsentation „veraltet“ (Teil der Projekte, Top 3).

### 2.6 Stories Studio: Ist alles drin?

Die Weltverwaltung ist sehr vollständig. Es fehlt der Weg **von der Welt zum Buch**:

- **Manuskript zusammenführen**: die Writer-Dokumente aller Abschnitte (`manuscriptID`) in Reihenfolge als ein Buch, Export als PDF und ePub.
- **Wortziele und Fortschritt** je Abschnitt, Kapitel und Buch, mit einer Schreibstatistik pro Tag.
- **Kontinuitätsprüfung**: Der Manuskripttext wird abschnittsweise gegen die Welt geprüft (Augenfarbe, Alter, wer wann was weiß, Zeitleiste). Das Ergebnis kommt als strukturierte Funde, nicht als Fließtext. Das geht schon mit 9B, wenn jeder Aufruf nur einen Abschnitt und die beteiligten Figuren sieht.
- **Szenen-Pinnwand**: die Abschnitte als Karten, die man umsortiert, neben der Gantt-Zeitleiste.
- Die zurückgestellten `stories.ai.*` brauchen zuerst deine Entscheidung zur Entwurfsmarkierung. Der Vorschlagsmodus aus 2.4 wäre diese Markierung.

### 2.7 Citation Studio und die IU

Der offizielle **Allgemeine Zitierleitfaden der IU** (Prüfungsamt, Stand 01.10.2025) erlaubt APA 7 in einer deutschen Fassung, **mit ausdrücklich genannten Abweichungen**. Für die App wichtig:

| IU-Regel | Was die App heute tut |
|---|---|
| Seitenangabe bei direkten **und** indirekten Zitaten; ohne Seite nur, wenn das ganze Werk gemeint ist | Seite ist freiwillig |
| Ab drei Autor:innen „et al.“, auch im deutschen Text | „u. a.“ |
| Ersatz für die Seite: Kap., Abs., Abschnitt, Zeitstempel | Freitext geht („Kap. 2“ bleibt) |
| Abbildungen und Tabellen: Überschrift „Abb. n“ bzw. „Tab. n“ mit Titel, darunter „Quelle: Eigene Darstellung / in Anlehnung an / (geändert) in Anlehnung an / auf der Basis von / Übernommen aus …“ | keine Beschriftungen |
| KI-generierte Bilder: „Erstellt mit dem Prompt „…“ durch …“ unter der Abbildung | Die App kennt den Prompt aus Draw Things, schreibt ihn aber nicht dazu |
| Skripte, Vorlesungsfolien und Webinare sind keine Quellen; Wikipedia und KI als Informationsquelle sind nicht zitierfähig | keine Warnung |
| Präsentationen: Kurzbelege auf den Folien, Literaturverzeichnis am Ende | kein Literaturverzeichnis im Presenter |
| Literaturverzeichnis: ein einziges Verzeichnis, keine Reihentitel, erste Auflage nicht nennen; deutsch ohne Komma vor „&“ (ein Komma aus einem Programm wird laut Leitfaden nicht schlechter bewertet) | ein Verzeichnis ja; kein Feld für Reihentitel; eine eingetragene 1. Auflage wird mitgedruckt; Komma vor „&“ |

Die **Formvorgaben** stehen im Prüfungsleitfaden in myCampus (P-Guide), den ich nicht einsehen konnte. Ein Ratgeber (fernstudi.net, nach den IU-Richtlinien vom 01.10.2025) nennt für die Hausarbeit: Arial oder Calibri 11 pt, Zeilenabstand 1,5, Blocksatz, 2 cm Rand ringsum, Überschriften 16/14/11 pt fett, höchstens drei Gliederungsebenen, mindestens zwei Unterpunkte je Ebene, römische Seitenzahlen vor dem Textteil und arabische ab der Einleitung, Titelblatt ohne Nummer, Abbildungs- und Tabellenverzeichnis ab je drei Einträgen und einen Textteil von 7–10 Seiten im Bachelor. Abgegeben wird über Turnitin in myCampus, die eidesstattliche Erklärung separat. **Diese Werte gehören deshalb in eine bearbeitbare Vorlage mit Stand-Datum, nicht fest in den Code**, und du gleichst sie einmal mit dem P-Guide ab.

Weitere Ideen für das Citation Studio:

- **Eingebauter PDF-Leser** (PDFKit ist schon im Einsatz): Markieren ergibt einen Wissensbaustein mit Seite. Die Seite ist dann nie vergessen, und die IU-Regel ist automatisch erfüllt.
- **Belegprüfung**: Jede Pille im Text wird gegen den gespeicherten Baustein bzw. die Anhangsseite geprüft („passt“, „passt nur teilweise“, „Seite fehlt“, „Quelle ist ein Skript“). Dazu kommt eine Suche nach **unbelegten Aussagen**: Absätze mit Zahlen oder Behauptungen ohne Pille.
- **Weitere Stile über CSL**: Laut Leitfaden können Module eigene Stile vorgeben. Die App hat schon einen CSL-Export (`CitationCSL`); ein CSL-Formatierer wäre der saubere Weg, ist aber eine größere Arbeit (citeproc-js wäre eine neue Abhängigkeit).
- **Import aus der IU-Bibliothek** (LIS): Ein Export von dort als RIS oder BibTeX geht vermutlich schon über den BibTeX-Import. Das wäre zu prüfen, bevor man etwas baut.

### 2.8 Hardware: heute 16 GB, später 64 GB

**Heute (M1 Pro, 16 GB):** Es läuft immer nur ein Sprachmodell, TTS bremst es spürbar, und das Prefill ist langsam (120–180 Token/s gemessen). Daraus folgen feste Regeln: eine Warteschlange, Hintergrundarbeit nur im Leerlauf, kleine Kontexte je Aufruf (Belege-Schreibtisch, abschnittsweise Prüfungen), feste Rezepte statt freier Agenten.

**Später (M5 Pro, 64 GB, Qwen 3.8 27B, dann Qwen 4):** Ein 27B-Modell braucht in 4 Bit etwa 15–16 GB für die Gewichte, dazu den Cache für den Kontext. Daneben passen ein kleines Modell, Qwen TTS und Draw Things. Damit der Umstieg kein Umbau wird, schlage ich **Modell-Rollen** vor (Rang 9): Jede Aufgabe fragt nach einer Rolle statt nach einem Modell, zum Beispiel *schnell* (Einordnen, Titel, Themen), *gründlich* (Schreiben, Agent), *prüfen* (Belegprüfung, Kontinuität), *Bild* und *Stimme*. Heute zeigen alle Rollen auf Qwen 3.5 9B, später *gründlich* und *prüfen* auf das 27B-Modell. Die Rezepte bleiben dieselben, nur die freien Agentenläufe werden mit dem großen Modell brauchbar.

### 2.9 E-Mail

Am 16.10. hast du entschieden, dass Kalender, Mail und iMessage bei Persephone (Callisto) bleiben. Ich würde das so lassen und in LLM Designer nur zwei Dinge bauen:

- **Mail-Entwürfe als Dokumentart in einem Projekt**: Die KI schreibt den Entwurf mit Bezug auf Projekt, Dokumente und Quellen. „In Mail öffnen“ legt den Entwurf in Apple Mail an, und abschicken tust du selbst. Nach der Sicherheitsregel ist Versand Wirkung nach außen und läuft deshalb nie automatisch.
- **Mails an ein Projekt hängen**: Eine Mail landet als Datei (.eml) im Projekt und gilt als fremd (A). Das genaue Verhalten beim Ziehen aus Mail muss man vorher ausprobieren.

Das Postfach lesen, sortieren und beantworten ist Persephones Aufgabe. Sie kann über MCP auf die Projekte in LLM Designer zugreifen.

---

## 3. Priorisierte Liste

Aufwand in Claude-Code-Sitzungen wie im Implementierungsplan. „16 GB“: läuft sinnvoll auf dem heutigen Mac.

| Rang | Feature | Bereich | Nutzen für dich | Aufwand | 16 GB | Hängt ab von |
|---|---|---|---|---|---|---|
| **1** | **Agentenzentrale**: Aufträge, Freigaben-Eingang, Verlauf mit Schnappschüssen, Modell-Warteschlange | App, Actions | sehr hoch: Grundlage für alles Unbeaufsichtigte | 4–5 | ja | – |
| **2** | **IU-Paket**: Vorlagen, Titelblatt, Beschriftungen, Verzeichnisse, IU-Stil, Formalprüfung, Literaturfolie | Writer, Citation, Presenter | sehr hoch, sofort im Studium | 4–6 | ja (fast ohne Modell) | – |
| **3** | **Projekte mit Rezepten**: Projektmappe und feste Abläufe Recherche → Quellen → Dokument → Folien → Podcast | App, alle Studios | sehr hoch: deine wiederkehrenden Arbeiten | 5–7 | ja, mit festen Rezepten | 1 |
| 4 | PDF-Leser mit Markieren → Baustein, Belegprüfung, unbelegte Aussagen | Citation, Writer | hoch (Studium, akademische Redlichkeit) | 3 | ja, abschnittsweise | (2) |
| 5 | Unterwegs, Stufe 1: iCloud-Briefkasten und Kurzbefehle | App | hoch, 0 € | 2 | ja | 1 |
| 6 | Audio-Studio: vertonte Präsentation als Datei, MP4, Podcast aus Dokument (zwei Stimmen) | Presenter, Speech | hoch (Lernen unterwegs) | 3–4 | ja, als Nachtauftrag | 1 |
| 7 | Learning Studio (dein Plan: Karten, Prüfungsfragen, eigener Planer) | neu | hoch (Prüfungen) | 5+ | ja | Entwurf mit dir, 3 |
| 8 | Belege-Schreibtisch (Abschnitt aus Bausteinen schreiben) | Writer, Citation | mittel bis hoch | 2–3 | ja, gerade dafür | 4 |
| 9 | Modell-Rollen | LLMClient, Einstellungen | mittel heute, hoch ab dem Hub | 1–2 | ja | – |
| 10 | Tempo-Paket: messen, Dokumenttext aus `documents`, Block-Umwandlung im Editor, Chats träge laden | Writer, Kern | mittel bis hoch bei langen Texten | 2 | ja | – |
| 11 | Befehlspalette ⌘K und Startseite „Heute“ | Oberfläche | mittel, macht alles auffindbar | 1–2 | ja | (1, 3) |
| 12 | Writer: Vorschlagsmodus, Versionen, Querverweise | Writer | mittel | 3 | ja | (1) |
| 13 | Stories: Manuskript, Wortziele, Kontinuitätsprüfung, Pinnwand, ePub | Stories | mittel (Hobby) | 3–4 | ja | (12) |
| 14 | Mail-Entwürfe an Projekten | Projekte | mittel | 1–2 | ja | 3 |
| 15 | Unterwegs, Stufe 2: Weboberfläche über Tailscale | App, Server | mittel, erst mit dem Hub | 3–4 | eher Hub | 1, 5 |
| 16 | DOCX-Export für Lehrende, die Word wollen | Writer | niedrig bis mittel | 2 | ja | – |
| 17 | Unterwegs, Stufe 3: native iOS-App | neu | niedrig, solange 5 und 15 reichen | 6+ | – | 15, Xcode |

**Kleine Sofortgewinne** (je unter einer Sitzung, auch einzeln machbar):
- IU-Stil als Variante: „et al.“ statt „u. a.“ und kein Komma vor „&“ im Deutschen.
- Bei Pillen ohne Seite einen Hinweis zeigen.
- Unter Draw-Things-Bildern die Quellenzeile „Erstellt mit dem Prompt „…“ durch Draw Things (Qwen Image)“ anbieten.
- Literaturfolie im Presenter.
- Seitenzähler „Textteil“ (ab der Einleitung, ohne Verzeichnisse und Anhang) in der Statuszeile.
- Im Aktivitätsfenster nach Lauf gruppieren und lesbare Namen statt Action-IDs zeigen.

---

## 4. Die Top 3 im Detail

### 4.1 Agentenzentrale

**Ziel:** Du gibst einen Auftrag (im Chat, in der Suchleiste, per `llmd`, MCP oder später vom iPhone), gehst weg, und wenn du wiederkommst, siehst du, was fertig ist, was wartet und was du zurücknehmen kannst.

**Bausteine:**

1. **Auftrag** als gespeichertes Objekt in der Bibliothek (`Aufträge/<id>.json`): Titel, Auftraggeber (Kanal), Rezept oder freier Lauf, Schritte mit Zustand (wartet, läuft, fertig, Fehler, wartet auf Freigabe), Ergebnisse als Verweise (Dokument, Präsentation, Audiodatei), Herkunftszustand A/B. Ein Auftrag überlebt einen Neustart und setzt nach dem letzten fertigen Schritt wieder auf.
2. **Freigaben-Eingang** statt `NSAlert`: Eine Frage hält nur ihren Auftrag an, nicht die App. Sie zeigt wie bisher Action, Ziel, gekürzte Daten und Grund und kann warten. Dazu eine Mitteilung von macOS und ein Zähler in der Titelleiste. Wenn du gerade selbst im Chat arbeitest, darf die Frage wie bisher sofort erscheinen.
3. **Verlauf mit Schnappschüssen**: Vor dem ersten schreibenden Schritt eines Auftrags sichert die App die betroffenen Dokumente, Präsentationen und Welten (sie liegen schon als Dateien vor). „Auftrag zurücknehmen“ funktioniert dann auch nach einem Neustart. Agenten nehmen damit nur zurück, was sie selbst angelegt haben; das war eine Lehre aus Callisto.
4. **Modell-Warteschlange**: Alle 14 Aufrufstellen gehen über einen Dienst mit Vorrang: *du* (Chat, Writer-KI) vor *Auftrag* vor *Hintergrund* (Gliederung, Themen, Verdichtung). Hintergrund weicht, sobald du schreibst, wie heute schon Verdichtung und Gliederung. TTS und Draw Things kommen in dieselbe Liste, weil sie auf 16 GB dieselbe GPU brauchen.
5. **Fenster „Agentenzentrale“**, das das Aktivitätsfenster ersetzt: links die Aufträge (läuft, wartet auf dich, fertig heute), rechts der gewählte Auftrag als Zeitleiste seiner Schritte in Sätzen („Hat 6 Quellen gefunden und 4 übernommen“), mit Links zu den Ergebnissen. Die technische Tabelle bleibt als Reiter „Protokoll“ für die Fehlersuche.

**Warum zuerst:** Rezepte (Top 3), Briefkasten (Rang 5), Nachtaufträge (Rang 6) und später der Hub mit Persephone setzen genau das voraus. Gleichzeitig wird die Oberfläche auf 16 GB ruhiger, weil Modellaufrufe nicht mehr gegeneinander laufen.

**Sicherheit:** Die Rule of Two bleibt unverändert in `ActionPolicy`. Neu ist nur, *wann* gefragt wird: Die Frage wartet, statt zu blockieren. Ein Auftrag kann seine eigenen Freigaben weiterhin nicht ändern.

**Erste Schritte:** (1) Warteschlange für das Modell mit Vorrang; (2) Auftrag als Datenmodell, `ActionRegistry` schreibt Schritte hinein; (3) Freigaben-Eingang; (4) Schnappschüsse; (5) Fenster.

### 4.2 IU-Paket

**Ziel:** Eine Hausarbeit von der Vorlage bis zur geprüften PDF, ohne Formatierungsarbeit am Ende.

**Bausteine:**

1. **Vorlagen** als Dokumente in der Bibliothek (`Vorlagen/`), mit Stand-Datum und Quelle: IU Hausarbeit, Fallstudie, Projektbericht, Bachelorarbeit, Präsentation. Jede Vorlage bringt Seitenformat (2 cm Rand, Arial 11 pt, 1,5 Zeilen, Blocksatz), Überschriftengrößen, Gliederungsgerüst und Titelblatt mit. Neue Vorlagen kannst du selbst aus jedem Dokument machen („Als Vorlage sichern“).
2. **Titelblatt** als Block mit Feldern (Hochschule, Prüfungsform, Kurs, Studiengang, Titel, Name, Matrikelnummer, Betreuer:in, Abgabedatum). Name und Matrikelnummer stehen einmal in den Einstellungen der Bibliothek. Die Matrikelnummer gilt als privat und ist für MCP gesperrt.
3. **Wissenschaftlicher Apparat**: Beschriftungen für Abbildungen und Tabellen mit Nummer und Quellenzeile (die Auswahl folgt dem IU-Muster), Abbildungs-, Tabellen- und Abkürzungsverzeichnis als Blöcke wie `[Literatur]`, Anhang mit Anhangsverzeichnis, Querverweise, römische Seitenzahlen vor dem Textteil und arabische ab der Einleitung (im Editor und im LaTeX-Export).
4. **IU-Zitierstil** als zweiter Stil neben „APA 7 deutsch“: „et al.“, kein Komma vor „&“, nur das Jahr der aktuellen Ausgabe, Seite als Pflichtfeld mit Hinweis.
5. **Formalprüfung vor der Abgabe** (deterministisch, ohne Modell): Umfang des Textteils, höchstens drei Ebenen, keine Ebene mit nur einem Unterpunkt, jede Abbildung und Tabelle mit Quelle, ab drei Einträgen das Verzeichnis, jede Pille mit Seite, jede zitierte Quelle im Literaturverzeichnis und keine ungenutzte, Warnung bei Skripten, Folien, Wikipedia und KI als Quelle. Das Ergebnis ist eine Liste mit Sprung zur Stelle.
6. **Presenter**: IU-Präsentationsvorlage, Literaturfolie, Quellenzeile unter Bildern.
7. **KI-Nutzung offenlegen**: Die App weiß, welche Bilder generiert und welche Absätze von der KI formuliert wurden. Ein Bericht „Eingesetzte KI-Hilfsmittel“ hilft beim Abgleich mit der KI-Richtlinie der IU. Was dort genau verlangt ist, kenne ich nicht; das müsstest du prüfen.

**Warum jetzt:** Es hilft dir bei der nächsten Abgabe, braucht kaum Modellleistung und baut auf vorhandenen Teilen auf (Seitenformate, Kopf- und Fußzeilen, `[Literatur]`-Block, LaTeX-Export, Citation-Formatierer).

**Erste Schritte:** (1) IU-Stil und Sofortgewinne; (2) Beschriftungen und Verzeichnisse; (3) Titelblatt, Seitenzählung, Vorlagen; (4) Formalprüfung; (5) Presenter-Teil.

### 4.3 Projekte mit Rezepten

**Ziel:** Ein Vorhaben („Hausarbeit Statistik 2“, „Vortrag Predictive Coding“) ist ein Objekt, an dem alles hängt, und wiederkehrende Abläufe laufen per Knopfdruck oder Auftrag.

**Bausteine:**

1. **Projekt** in der Bibliothek: Titel, Ziel, Termine (Abgabe, Referat), Verknüpfungen zu Dokumenten, Präsentationen, Quellen-Ordnern, Chats, Welten und später Mails und Lernräumen. Die Dinge bleiben in ihren Ordnern; das Projekt verweist nur (wie „Dazugehörige Dokumente“ im Stories Studio). In der Seitenleiste ist ein Projekt ein eigener Stapel.
2. **Abstammung**: Was aus etwas anderem entsteht (Präsentation aus Dokument, Handout aus Präsentation, Podcast aus Dokument), merkt sich die Herkunft. Ändert sich die Vorlage, steht beim Abkömmling „veraltet, neu erzeugen?“. Das ist das Themen-Objekt aus dem Konzept vom 16.10.
3. **Rezepte** als feste, von der App gesteuerte Schrittfolgen, deren Schritte Actions sind. Dadurch laufen sie mit 9B zuverlässig:
   - *Recherche*: Fragen zerlegen → Web und Wikipedia → Kandidaten als Quellen (fremd) → Bausteine mit Fundstelle → Recherchebericht mit Pillen.
   - *Dokument → Präsentation → Moderatorenkarten → vertonte Präsentation.*
   - *Dokument → Podcast* (Skript für zwei Stimmen, Qwen TTS, Audiodatei).
   - *Abgabe vorbereiten*: Formalprüfung, Belegprüfung, PDF in den Exportordner.
   - später *Dokument → Karteikarten* (Learning Studio).
   Jedes Rezept kann einen **Prüfschritt** bekommen: strukturierte Funde und mit dem Hub ein stärkeres Prüfmodell.
4. **Projektkontext für Agenten**: Ein Auftrag „im Projekt“ sieht nur dessen Dinge. Das hält den Kontext klein und begrenzt, was ein Agent anfassen kann.
5. **MCP**: Projekte als Resource (`llmd://project/{id}`) und Rezepte als grobe Tools. Genau das braucht Persephone, die pro Takt eine Aktion wählt.

**Warum als drittes:** Das ist der Kern deiner „Suite, die wiederkehrende Arbeit automatisiert“. Ohne die Agentenzentrale wäre ein Rezept aber nur ein langer Chat, der an der ersten Rückfrage hängen bleibt.

**Offen für dich:** Wie viel ein Projekt sein soll (nur Verweise oder auch eigene Notizen und Aufgaben), und ob ein IU-Modul automatisch ein Projekt ist (Kurs → Prüfungsleistung → Termin).

---

## 5. Unterwegs: Optionen, Kosten, Absicherung

Vorab: Der Mac muss wach und LM Studio bzw. Kapitsa erreichbar sein. Ein zugeklapptes MacBook schläft. Für Unterwegs-Nutzung heißt das heute: Netzteil und Energie-Einstellungen anpassen. Richtig gut wird es erst mit dem Hub (Mac mini).

| Weg | Kosten | Was geht | Risiko | Empfehlung |
|---|---|---|---|---|
| **Stufe 1: iCloud-Briefkasten + Kurzbefehle** | 0 € | Auftrag diktieren (Kurzbefehl legt JSON in `iCloud Drive/LLM Designer/Eingang`), Ergebnisse (PDF, MP3, Markdown) in `…/Ausgang` in der Dateien-App lesen und hören, Status als kleine Datei | kein offener Port; iCloud Drive ist ohne „Erweiterten Datenschutz“ nicht Ende-zu-Ende verschlüsselt | **jetzt**, nach Top 1 |
| **Stufe 2: Weboberfläche über Tailscale** | 0 € (Personal-Plan, privat) | Chat, Aufträge starten, Freigaben erteilen, Ergebnisse ansehen im Browser des iPhones, als Web-App auf dem Home-Bildschirm | braucht einen lauschenden Dienst, also eine bewusste Ausnahme von der Regel „Keine Netzwerkports“ | **mit dem Hub** |
| Öffentliche Webseite (eigene Domain, Cloudflare Tunnel o. Ä.) | etwa 10–15 € im Jahr für die Domain | wie Stufe 2, von überall ohne VPN | die App mit Agent und Dateizugriff wäre aus dem Internet erreichbar | **nicht** |
| **Stufe 3: native iOS-App** | 99 US-Dollar im Jahr Apple Developer Program, dazu Xcode (kostenlos, aber groß; heute sind nur die Command Line Tools installiert) | alles aus Stufe 2, dazu Mitteilungen, Diktat, Widgets und Kurzbefehle aus der App | wie Stufe 2 oder über CloudKit ganz ohne Port | **später**, wenn Stufe 1/2 zeigen, was du unterwegs wirklich brauchst |

**Absicherung, je Stufe:**

- **Stufe 1:** Der Briefkasten ist ein **neuer Kanal** „Unterwegs“ mit eigener Freigabestufe in `ActionPolicy`. Weil jeder, der dein iCloud-Konto erreicht, dort Dateien ablegen könnte, gilt: Aufträge aus dem Eingang dürfen lesen und lokal schreiben (in Projekte, mit Schnappschuss), aber **nichts löschen, nichts nach außen geben und keine privaten Daten lesen**. Solche Schritte warten im Freigaben-Eingang, bis du am Mac bist. Freigaben per Datei gibt es bewusst nicht. Ins Ausgang kommt nur, was der Auftrag ausdrücklich als Ergebnis nennt.
- **Stufe 2:** Der Webdienst hört nur auf `127.0.0.1`; `tailscale serve` reicht ihn ins private Tailnet weiter, nie ins Internet (kein Funnel). Dazu kommt eine eigene Anmeldung (Passkey oder Gerätetoken), eine Prüfung der Tailscale-Identität, kurze Sitzungen und ein Protokoll jeder Anmeldung. Freigaben vom iPhone sind dann möglich, aber nur mit erneuter Bestätigung (Face ID über Passkey).
- **Stufe 3:** Mit CloudKit (private Datenbank deines Apple-Kontos) lässt sich der Briefkasten aus Stufe 1 sauber als App bauen, weiterhin ohne Port. Ein Nebeneffekt des Developer Programs: Mit einer echten Signatur vergisst macOS die Bildschirmaufnahme-Erlaubnis nicht mehr nach jedem Neubau.

**Meine Empfehlung:** Stufe 1 direkt nach der Agentenzentrale. Sie kostet nichts, braucht keine iOS-Entwicklung und zeigt dir in ein paar Wochen, was du unterwegs wirklich tust. Danach entscheidest du mit dem Hub zwischen Stufe 2 und 3.

---

## 6. Offene Fragen an dich

1. Reihenfolge der Top 3 so, oder zuerst das IU-Paket, weil eine Abgabe ansteht?
2. Agentenzentrale: Sollen Aufträge über einen Neustart hinweg weiterlaufen (Vorschlag: ja, ab dem letzten fertigen Schritt)?
3. IU: Welche Prüfungsformen brauchst du konkret (Hausarbeit, Fallstudie, Projektbericht, Portfolio, Präsentation, Bachelorarbeit)? Kannst du den aktuellen Prüfungsleitfaden aus myCampus als Datei geben, damit die Vorlage stimmt?
4. Projekte: nur Verweise oder auch eigene Notizen und Aufgaben? Ist ein IU-Modul ein Projekt?
5. Unterwegs: Ist Stufe 1 (iCloud und Kurzbefehle) für den Anfang genug? Nutzt du den „Erweiterten Datenschutz“ für iCloud?
6. Mail: Bleibt es bei der Entscheidung vom 16.10. (Postfach bei Persephone, in LLM Designer nur Entwürfe)?

---

## Quellen

- IU Internationale Hochschule, Prüfungsamt: [Allgemeiner Zitierleitfaden der IU](https://res.cloudinary.com/iugroup/image/upload/v1764593394/Zitierleitfaden-IU_yl1quy.pdf), Stand 01.10.2025 (Kap. 2.1, 2.2.1, 2.2.4, 2.2.5, 2.3.1).
- IU-Magazin: [Richtig zitieren](https://www.iu.de/magazin/richtig-zitieren/) (Leitfaden liegt im P-Guide in myCampus).
- fernstudi.net: [Vorlage Hausarbeit IU](https://www.fernstudi.net/magazin/vorlage-hausarbeit-iu), aktualisiert 30.06.2026. Das ist ein Ratgeber, keine IU-Quelle, und muss mit dem Prüfungsleitfaden abgeglichen werden.
- Apple Developer Program, 99 US-Dollar im Jahr, nötig für TestFlight und App Store: zum Beispiel [Adalo: The Apple Developer Program (2026)](https://studio.adalo.com/blog/apple-developer-program-guide). Das ist keine Apple-Quelle; der Preis ist vor dem Beitritt auf developer.apple.com zu prüfen.
- Tailscale Personal-Plan, privat kostenlos, seit April 2026 laut mehreren Quellen bis 6 Nutzer und unbegrenzt viele Geräte: [Activepieces: Tailscale Pricing 2026](https://www.activepieces.com/blog/tailscale-pricing-plans-costs-and-features-2026). Ältere Seiten nennen 3 Nutzer; maßgeblich ist tailscale.com/pricing.
- Speicherbedarf eines 27B-Modells in 4 Bit (etwa 15–16 GB Gewichte): [LM Studio: qwen3.6-27b-mlx-4bit](https://lmstudio.ai/froggeric/qwen3.6-27b-mlx-4bit), [lilting.ch: Qwen3.6-27B auf M1 Max](https://lilting.ch/en/articles/qwen36-27b-dense-vs-35b-moe-mlx-ollama). Die Zahlen gelten für Qwen 3.6; für Qwen 3.8 und Qwen 4 ist die Modellkarte maßgeblich.
