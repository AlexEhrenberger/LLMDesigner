# Epics: Agentenzentrale, Tempo, Projektseite, IU-Paket

_Von Claude Code · Stand: 08.11.2026 · Basis-Commit: `6405152` · Grundlage: [Weiterentwicklung](Weiterentwicklung.md)_
_Status: **beschlossen**, gebaut wird ab Mittwoch, 11.11.2026. Für E1 hast du freie Hand gegeben._

---

## 0. Überblick

| Epic | Was du davon hast | Sitzungen | Wann |
|---|---|---|---|
| **E1 Agentenzentrale** | Du gibst einen Auftrag, gehst weg und siehst später, was fertig ist, was auf dich wartet und wie du es zurücknimmst. | 4–5 | nächste Coding-Sitzung |
| **E2 Tempo** | Tippen bleibt auch in einer langen Arbeit flüssig, die Seitenleiste zuckt nicht, die App startet schneller. | 2 | direkt nach E1, vor E3 |
| **E3 Projektseite mit Rezepten** | Ein Projekt hat ein eigenes Symbol in der Seitenleiste und eine Seite mit Stand, Diagrammen, To-dos und Verknüpfungen. Wiederkehrende Abläufe startest du dort per Knopf. | 5–7 | nächste Woche |
| **E4 IU-Paket** | Hausarbeit, Fallstudie oder Bachelorarbeit von der Vorlage bis zur geprüften PDF, formal nach IU-Leitfaden. | 4–6 | danach |

**Warum E2 vor E3:** Die Projektseite legt weitere Ansichten auf die Liste aller Dokumente. Was E2 dort an unnötigem Neuzeichnen beseitigt, würde sie sonst vervielfachen.

**Abhängigkeiten:** Die Rezepte in E3 laufen als Aufträge aus E1. Die Projektseite selbst (E3, Teil A) braucht E1 nicht. Wird E1 nicht rechtzeitig fertig, kommt Teil A zuerst. Die Formalprüfung aus E4 wird später ein Rezept in E3.

### Regeln für alle Epics

- Es gilt `CLAUDE.md`: Daten in die Bibliothek, Oberfläche deutsch, keine Fremdabhängigkeiten, jede neue Funktion auch als Action mit Test über die Registry, Testdaten neutral erzeugt.
- **Neue Dateiformate stehen in diesem Dokument.** Mit deinem Ja zu den Epics sind sie bestätigt. Weicht ein Format beim Bauen ab, frage ich nach, statt es still zu ändern.
- Am Ende jeder Sitzung: Tests grün, Fortschritt in Abschnitt 6 eintragen, `docs/*.md` nachziehen, Commit nach deiner Rückfrage.

---

## E1 Agentenzentrale

### Was du am Ende hast

Ein Abend, wie er danach aussieht:

> Du tippst in die Suchleiste: „Recherchiere Predictive Coding für Einsteiger, leg die Quellen an und mach mir eine Präsentation mit Karten.“ Dann klappst du den Mac nicht zu, sondern gehst.
>
> Die App macht daraus einen **Auftrag**. In der Titelleiste erscheint ein kleiner Zähler. Während der Auftrag läuft, kannst du im Hauptfenster weiterschreiben: **Dein Chat hat Vorrang**, der Auftrag wartet so lange.
>
> Bei Schritt 5 will der Agent eine Webseite öffnen, nachdem er vorher eine fremde PDF gelesen hat. Die Sicherheitsregel verlangt eine Rückfrage. Früher wäre hier ein Dialog aufgegangen, der alles anhält. Jetzt landet die Frage im **Freigaben-Eingang**, nur dieser Auftrag pausiert, und macOS zeigt eine Mitteilung.
>
> Am Morgen öffnest du die Agentenzentrale: „Fertig: Präsentation *Predictive Coding* (12 Folien, 6 Quellen)“ und „1 Frage offen“. Du gibst die Frage frei, der Auftrag läuft zu Ende. Gefällt dir das Ergebnis nicht, stellt **„Auftrag zurücknehmen“** den Stand von vorher wieder her, auch nach einem Neustart.

Der Gewinn in einem Satz: **Du kannst Agenten Arbeit geben, ohne danebensitzen zu müssen, und behältst trotzdem jederzeit den Überblick und das letzte Wort.**

### So sieht es aus

```
┌ Agentenzentrale ─────────────────────────────────────────────────────────────────┐
│ Modell: Qwen 3.5 9B · arbeitet für: Chat „Statistik“ · danach: 1 Auftrag, 2 im Hintergrund │
├──────────────────────────────┬───────────────────────────────────────────────────┤
│ WARTET AUF DICH (1)          │ Präsentation Predictive Coding                    │
│ ● Predictive Coding     ⏸    │ aus der Suchleiste · gestartet 22:14 · 38 min     │
│                              │                                                   │
│ LÄUFT (0)                    │ ✓ Fragen zerlegt (4 Teilfragen)                   │
│                              │ ✓ 9 Treffer gesucht, 6 Quellen angelegt  [Quellen]│
│ FERTIG HEUTE (3)             │ ✓ 14 Wissensbausteine mit Fundstelle              │
│ ✓ Gliederung „Bericht“       │ ✓ Präsentation angelegt, 12 Folien    [öffnen]    │
│ ✓ Themen sortiert            │ ⏸ Möchte öffnen: arxiv.org/abs/…                 │
│ ✓ Bild „Titelfolie“          │   Grund: Der Lauf hat fremde Inhalte gelesen.     │
│                              │   [Einmal erlauben] [Ablehnen] [Auftrag anhalten] │
│ FRÜHER                       │ ○ Moderatorenkarten                               │
│ …                            │                                                   │
│                              │ Ergebnisse: Präsentation · 6 Quellen              │
│                              │ [Auftrag zurücknehmen]              Reiter: Protokoll │
└──────────────────────────────┴───────────────────────────────────────────────────┘
```

Dazu kommen:
- ein Zähler in der Titelleiste des Hauptfensters (offene Fragen und laufende Aufträge); ein Klick öffnet die Zentrale
- Mitteilungen von macOS bei „wartet auf dich“ und „fertig“
- im Chat dieselbe Frage als Karte unter der Antwort, wenn der Auftrag aus diesem Chat kommt.

### Was ich baue

| # | Baustein | Inhalt | Wo |
|---|---|---|---|
| E1.1 | **Modell-Warteschlange** | Jeder Modellaufruf (heute 14 Dateien) geht über `ModelQueue` mit drei Vorrangstufen: *du* (Chat, Writer-KI, Suchleiste) vor *Auftrag* vor *Hintergrund* (Gliederung, Themen, Verdichtung, Folgefragen). Je Modellserver läuft eine Erzeugung zugleich; der Wert lässt sich für den Hub auf 2 stellen. Hintergrund bricht ab und kommt später wieder, sobald du tippst; das gilt dann einheitlich, nicht nur für Verdichtung und Gliederung. Qwen TTS und Draw Things stehen als „schwere Arbeit“ in derselben Übersicht. Auf 16 GB läuft schwere Arbeit nie neben einer Erzeugung im Hintergrund. | `Core/ModelQueue.swift`, `LLMClient` |
| E1.2 | **Auftrag** | Jeder Lauf von Chat-Werkzeugen, Suchleiste, `llmd --run` und MCP wird ein Auftrag oder hängt sich an einen. Die Registry schreibt jeden Schritt hinein: Action, Ziel, Ergebnis als Satz, Entscheidung der Regel. Die Sätze kommen aus einem neuen, freiwilligen Feld des Descriptors (`step: "Text eingefügt in „{doc}“"`); fehlt es, nimmt die App die Zusammenfassung. Aufträge liegen als Datei in der Bibliothek und überleben einen Neustart. | `Actions/Jobs/AgentJob.swift`, `JobStore`, `ActionRegistry` |
| E1.3 | **Freigaben-Eingang** | `ActionApproval` öffnet keinen `NSAlert` mehr, sondern legt eine offene Frage an und lässt **nur diesen Lauf** warten. Antworten gibt es nur in der Oberfläche (Zentrale, Chat-Karte, Mitteilung); kein Agent und kein Kanal außer der Oberfläche kann eine Frage beantworten. Bleibt eine Frage 24 Stunden offen, gilt sie als abgelehnt, und der Auftrag steht auf „angehalten“. | `ActionApproval`, `UI/Agents/` |
| E1.4 | **Schnappschüsse** | Bevor ein Auftrag ein Dokument, eine Präsentation, eine Romanwelt oder eine Quelle zum ersten Mal ändert, kopiert die App deren Datei in den Ordner des Auftrags. „Auftrag zurücknehmen“ legt die Kopien zurück und verschiebt, was der Auftrag neu angelegt hat, in den Papierkorb. Hast du danach selbst etwas geändert, zeigt die App das vorher und fragt. Aufbewahrt werden die letzten 50 Aufträge oder 30 Tage; danach verschwinden die Kopien, der Eintrag bleibt. | `Actions/Jobs/JobSnapshots.swift` |
| E1.5 | **Fenster Agentenzentrale** | Es ersetzt „Aktivität von Terminal und Agenten“. Links stehen die Aufträge in Gruppen, rechts die Schritte als Zeitleiste in Sätzen, die Frage, die Ergebnisse als Links und „Zurücknehmen“. Die heutige Tabelle bleibt als Reiter „Protokoll“, für die Fehlersuche. Oben eine Leiste mit Modell, Auftraggeber und Warteschlange. Dazu kommen der Zähler in der Titelleiste und die Mitteilungen. | `UI/Agents/AgentCenterView.swift` |
| E1.6 | **Actions** | `jobs.list`, `jobs.read`, `jobs.cancel`, `jobs.undo` (destruktiv, mit Freigabe), `approvals.list` (nur lesen). Ein Agent sieht seine eigenen Aufträge, kann aber keine Fragen beantworten. MCP bekommt `llmd://jobs/{id}` als Resource, damit Persephone später sieht, was fertig ist. | `Actions/Jobs/` |
| E1.7 | **Tests und Doku** | Reihenfolge und Vorrang der Warteschlange mit `FakeLLMServer`; Auftrag über einen simulierten Neustart; Zurücknehmen stellt das Markdown byte-genau wieder her; eine Frage hält nur ihren Lauf an; kein Kanal außer der Oberfläche kann antworten. `docs/actions.md`, `docs/architektur.md`, `docs/speicherformate.md`. | `Tests/LLMDesignerTests/Jobs/` |

### Datenformat (neu)

```
Name.llmdlibrary/
└── Aufträge/
    ├── <id>.json          der Auftrag
    └── <id>/vorher/       Schnappschüsse: Kopien der Dateien vor der ersten Änderung
```

```json
{
  "id": "…", "titel": "Präsentation Predictive Coding",
  "kanal": "chat", "auftraggeber": "Suchleiste", "chatID": "…",
  "zustand": "wartet",            // läuft | wartet | angehalten | fertig | fehler | zurückgenommen | unterbrochen
  "gestartet": "2026-11-12T22:14:03Z", "beendet": null,
  "herkunft": { "fremd": true, "sensibel": false },
  "schritte": [
    { "action": "presenter.deck.create", "ziel": "Predictive Coding", "satz": "Präsentation angelegt, 12 Folien",
      "regel": "erlaubt", "zeit": "…", "fehler": null }
  ],
  "frage": { "action": "open_page", "ziel": "arxiv.org/abs/…", "grund": "Der Lauf hat fremde Inhalte gelesen.", "seit": "…" },
  "ergebnisse": [ { "art": "praesentation", "id": "…" }, { "art": "quelle", "id": "…" } ],
  "schnappschuesse": [ { "art": "dokument", "id": "…", "datei": "vorher/<id>.md", "version": "…" } ],
  "angelegt": [ { "art": "quelle", "id": "…" } ]
}
```

Wie im heutigen Protokoll stehen dort **keine Inhalte**: nur Titel, Ziele, Sätze und Verweise. Die Schnappschüsse sind Kopien deiner eigenen Dateien und liegen in derselben Bibliothek.

### Was ein Neustart mit einem Auftrag macht

- **Freie Läufe** (Chat mit Werkzeugen, Suchleiste) lassen sich nicht fortsetzen: Der Gesprächszustand des Modells ist weg. Nach einem Neustart stehen sie auf „unterbrochen“, mit allem, was fertig war, und mit „Zurücknehmen“.
- **Rezepte** (aus E3) setzen nach dem letzten fertigen Schritt wieder an, weil die App ihre Schritte selbst steuert.

### Nicht Teil von E1

Rezepte (E3), der iCloud-Briefkasten und die Weboberfläche (eigenes Thema), Aufträge zu einer Uhrzeit.

### Abnahme

- Ein Chat mit Werkzeugen, der drei Schritte macht, steht als Auftrag mit drei Sätzen in der Zentrale, auch nach einem Neustart der App.
- „Auftrag zurücknehmen“ stellt das Dokument byte-genau her und verschiebt neu angelegte Dinge in den Papierkorb.
- Wartet ein Auftrag auf eine Freigabe, bleibt die App bedienbar, und ein zweiter Chat antwortet derweil.
- Zwei Modellaufrufe gleichzeitig laufen nacheinander, dein Chat zuerst; Hintergrund weicht, sobald du tippst.
- Alle Tests grün; 5.6 aus dem Implementierungsplan (Probe mit echtem Claude Code) ist nachgeholt.

---

## E2 Tempo

### Was du am Ende hast

Auch in einer Arbeit mit 60 Seiten fühlt sich Tippen an wie in einem leeren Dokument. Die Seitenleiste bleibt beim Schreiben ruhig, und die App ist nach dem Start schneller bedienbar. Wie viel schneller, steht nach der Messung als Zahl vorher und nachher im Fortschritt.

### Was ich baue

| # | Baustein | Inhalt |
|---|---|---|
| T1 | **Messen** | Ein neutral erzeugtes Testdokument mit 60 Seiten (Text, Tabellen, Bilder, Zitate) und eine Testbibliothek mit 500 erzeugten Chats. Gemessen wird die Zeit des Hauptthreads je Tipp-Pause (`os_signpost` plus `sample`), die Startzeit bis zur bedienbaren Seitenleiste und der Speicher nach dem Start. Die Zahlen kommen in den Fortschritt. |
| T2 | **Dokumenttext aus der Liste nehmen** | Den Text bekommt ein eigener Speicher (`DocumentTexts`), den Editor, Actions, Suche und Export lesen. `documents` ändert sich nur noch, wenn sich etwas für die Liste Sichtbares ändert: Titel, Ordner, und das Datum höchstens einmal pro Minute. Das ist dasselbe Prinzip wie `LiveAnswer` beim Streaming. Viele Stellen lesen heute `document.markdown`; die Umstellung geht Stelle für Stelle, und die Rundlauf- und Action-Tests sichern ab. |
| T3 | **Nur geänderte Blöcke umwandeln** | Der Editor merkt sich, welche Absätze sich seit der letzten Meldung geändert haben, und wandelt nur diese in Markdown. Den Rest nimmt er aus einem Zwischenspeicher je Block. Ein Rundlauftest vergleicht bei jedem Testdokument „alles neu“ mit „nur Blöcke“. |
| T4 | **Chats träge laden** (nach Messung) | Beim Start lädt die App nur Kopfdaten (Titel, Datum, Ordner, Persona). Die Nachrichten kommen beim Öffnen, für Suche und Themenstapel im Hintergrund. Die Kopfdaten stehen in `Chats/Index.json`, einem Zwischenspeicher, den die App aus den Chatdateien jederzeit neu bauen kann. Das lohnt sich nur, wenn T1 beim Start eine spürbare Zeit misst; sonst lasse ich es weg und schreibe das in den Fortschritt. |

### Abnahme

Die Messwerte vorher und nachher stehen im Fortschritt. Das Ziel lege ich nach T1 fest; die Richtschnur ist, dass eine Tipp-Pause den Hauptthread kürzer als ein Bild (16 ms) belegt. Die Rundlauftests sind grün, und kein Action-Test ändert sein Ergebnis.

---

## E3 Projektseite mit Rezepten

_Zu deiner Idee der „Projektpage“ habe ich weder in der Doku noch in den Notizen oder früheren Sitzungen etwas gefunden. Dieses Epic beruht auf deiner Beschreibung vom 08.11. Hast du eine Skizze, gilt die._

### Was du am Ende hast

> Du legst ein Projekt „Hausarbeit Statistik 2“ an. In der Seitenleiste gibt es dafür ein eigenes Symbol neben Chats, Skills und Personas. Du ziehst die Gliederung, den Quellen-Ordner und den Chat mit deinen Notizen hinein. Auf der Projektseite siehst du:
> - den Stand (12 von 20 To-dos, 3 400 von 4 000 Wörtern, Abgabe in 9 Tagen)
> - wie sich das in den letzten Wochen entwickelt hat
> - was noch offen ist.
>
> Unter „Rezepte“ drückst du „Abgabe vorbereiten“. Ein Auftrag prüft die Formalien, setzt die PDF und legt die Funde als To-dos an. Ist die Präsentation älter als das Dokument, aus dem sie entstand, steht dort „veraltet“, mit einem Knopf zum Neuerzeugen.

Der Gewinn: **Ein Ort pro Vorhaben, der dir den Stand zeigt und die wiederkehrende Arbeit übernimmt.** Für Agenten, später auch für Persephone, ist das Projekt der Rahmen: Sie sehen nur, was dazugehört.

### So sieht es aus

```
Seitenleiste: [💬 Chats] [✨ Skills] [👤 Personas] [▣ Projekte]

┌ Hausarbeit Statistik 2 ───────────────────────────────────── Abgabe 20.11. · noch 9 Tage ┐
│ Ziel: Regressionsanalyse an einem offenen Datensatz, 7–10 Seiten Textteil             │
├─────────────────────┬─────────────────────┬─────────────────────┬──────────────────┤
│  ◕ To-dos 12 / 20   │  Wörter 3 400/4 000 │  Quellen 14         │  Status: im Plan │
├─────────────────────┴─────────────────────┴─────────────────────┴──────────────────┤
│  Verlauf ▁▂▃▃▅▆▇  erledigte To-dos und Wörter je Tag          Termine ──●──────◆──▶   │
├──────────────────────────────────────────┬──────────────────────────────────────────┤
│ TO-DOS                                   │ VERKNÜPFT                                │
│ ☐ Kapitel 3 Ergebnisse        bis 15.11. │ 📄 Hausarbeit (Hauptdokument)            │
│ ☐ Abb. 2 Quelle ergänzen  ← Formalprüfung│ 📊 Referat  ⚠ veraltet  [neu erzeugen]   │
│ ☐ Literatur prüfen           ← vorgeschl.│ 📚 Ordner „Statistik 2“ (14 Quellen)     │
│ ☑ Gliederung                             │ 💬 Chat „Fragen an Prof.“                │
│ [+ To-do]                                │ [+ verknüpfen]   oder hineinziehen       │
├──────────────────────────────────────────┴──────────────────────────────────────────┤
│ REZEPTE   [Recherche] [Dokument → Präsentation] [Podcast] [Abgabe vorbereiten]        │
│ AUFTRÄGE  ✓ Abgabe vorbereiten (gestern, 4 Funde) · ✓ Recherche (Mo, 6 Quellen)         │
│ NOTIZEN   …                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

In schmalen Fenstern rutschen die Spalten untereinander. Die Seite hält die Regeln aus dem Stories Studio ein: Felder sind `NSTextView` und melden nicht jeden Tastendruck, und die Kurzformen der Leisten werden aus der Breite berechnet.

### Was ich baue

**Teil A – die Projektseite (braucht E1 nicht)**

| # | Baustein | Inhalt |
|---|---|---|
| P1 | **Datenmodell** | `Project`: Titel, Ziel, Status (geplant, läuft, pausiert, fertig), Termine (Abgabe, Referat, eigene), Hauptdokument, Wortziel, Verknüpfungen (Art + ID: Dokument, Präsentation, Quellen-Ordner, Quelle, Chat, Romanwelt), To-dos, Notizen und ein Verlauf mit einem Eintrag pro Tag. Lenient decoding wie im Stories Studio. Gelöschte Projekte kommen in den Papierkorb; die verknüpften Dinge bleiben unberührt. |
| P2 | **Seitenleiste** | Vierter Modus „Projekte“ mit eigenem Symbol. Die Liste ist nach Status gruppiert, mit dem nächsten Termin. Im Neu-Menü gibt es „Neues Projekt“; Dokumente, Präsentationen und Chats bekommen im Kontextmenü „Zu Projekt hinzufügen …“, und sie lassen sich auch auf ein Projekt ziehen. Die Zugehörigkeit erscheint als kleines Abzeichen in der Liste. |
| P3 | **Projektseite** | Kopf mit Ziel und Termin-Countdown, Kennzahlen-Kacheln, To-dos, Verknüpfungen (ein Klick öffnet), Notizen. Dazu der Abschnitt „Aufträge“: die Aufträge dieses Projekts aus E1, fehlt er noch, bleibt der Abschnitt leer. |
| P4 | **Diagramme** | Mit Swift Charts (Systemframework, keine Abhängigkeit): ein Ring für die To-dos, der Verlauf der erledigten To-dos und der Wörter im Hauptdokument gegen das Ziel, eine Zeitleiste der Termine. Den Verlauf schreibt die App einmal am Tag und bei Änderungen, als kleine Zahlen (offen, erledigt, Wörter) und nie als Text. |
| P5 | **To-dos** | Mit Fälligkeit, Verknüpfung zu einem Dokument und einer Herkunft: von dir, „vorgeschlagen“ (von der KI, erst nach deinem Annehmen echt) oder „aus Formalprüfung“. Wird ein Fund behoben, hakt die nächste Prüfung ihn selbst ab. |

**Teil B – Rezepte (braucht E1)**

| # | Baustein | Inhalt |
|---|---|---|
| P6 | **Abstammung und „veraltet“** | Was aus etwas anderem entsteht (Präsentation aus Dokument, Handout, Podcast), merkt sich Quelle und `version` beim Erzeugen. Ändert sich die Quelle, zeigt die Projektseite „veraltet“ mit Knopf „neu erzeugen“. |
| P7 | **Rezepte** | Feste Schrittfolgen, die die App steuert. Jeder Schritt ist eine Action oder ein Modellaufruf mit festem Schema. Sie laufen als Auftrag (E1) mit Projekt-ID, setzen nach einem Neustart am letzten fertigen Schritt wieder an, und ihre Ergebnisse verknüpft die App selbst mit dem Projekt. Vier zum Start: **a) Recherche** (Fragen zerlegen → Web/Wikipedia → Quellen als fremd → Bausteine mit Fundstelle → Recherchebericht mit Pillen), **b) Dokument → Präsentation** (mit Karten), **c) Podcast** (Skript für ein oder zwei Stimmen aus Dokument oder Präsentation, Qwen TTS als Audiodatei im Projekt), **d) Abgabe vorbereiten** (Literatur und fehlende Seiten prüfen, PDF in den Exportordner; mit E4 dazu die Formalprüfung). |
| P8 | **Projektrahmen für Agenten** | Ein Rezept im Projekt sieht nur die verknüpften Dinge; was es anlegt, kommt ins Projekt. Ein freier Chat „im Projekt“ bekommt die Liste der Verknüpfungen als Kontext, nicht deren Inhalt. |
| P9 | **Actions und MCP** | `project.create/list/read/update/link/unlink`, `project.todo.add/done`, `project.recipe.list/run`; Resource `llmd://project/{id}`. Das sind genau die groben Werkzeuge, die Persephone braucht. |

### Datenformat (neu)

```
Name.llmdlibrary/
└── Projekte/
    ├── <id>.json         ein Projekt mit To-dos, Notizen und Verlauf
    └── Audio/<id>/       Ergebnisse von Rezepten, die keine Dokumente sind (Podcast-Dateien)
```

```json
{
  "id": "…", "titel": "Hausarbeit Statistik 2", "ziel": "…", "status": "laeuft",
  "termine": [ { "titel": "Abgabe", "datum": "2026-11-20" } ],
  "hauptdokument": "…", "wortziel": 4000,
  "verknuepft": [ { "art": "dokument", "id": "…" }, { "art": "quellenordner", "id": "…" } ],
  "todos": [ { "id": "…", "text": "Kapitel 3", "faellig": "2026-11-15", "erledigt": false,
               "herkunft": "ich", "ziel": { "art": "dokument", "id": "…" } } ],
  "notizen": "…",
  "verlauf": [ { "tag": "2026-11-12", "offen": 8, "erledigt": 12, "woerter": 3400 } ],
  "abstammung": [ { "ergebnis": { "art": "praesentation", "id": "…" }, "quelle": { "art": "dokument", "id": "…" }, "version": "…" } ]
}
```

### Abnahme

- **Teil A:** Ein Projekt anlegen, drei Dinge per Ziehen verknüpfen, To-dos abhaken: Die Diagramme zeigen es, und alles ist nach einem Neustart noch da. Ein verknüpftes Dokument zu löschen hinterlässt im Projekt einen Hinweis statt eines Absturzes.
- **Teil B:** „Dokument → Präsentation“ läuft als Auftrag, das Ergebnis hängt am Projekt, und nach einer Änderung am Dokument steht „veraltet“. „Recherche“ läuft mit Qwen 3.5 9B auf einer Wegwerf-Bibliothek durch. Ein Rezept, das mitten im Lauf durch einen Neustart unterbrochen wurde, setzt beim nächsten Schritt fort.

---

## E4 IU-Paket

Umsetzung wie in [Weiterentwicklung, 4.2](Weiterentwicklung.md#42-iu-paket). Grundlage ist der Allgemeine Zitierleitfaden der IU (Stand 01.10.2025). **Vorher brauche ich von dir den aktuellen Prüfungsleitfaden aus myCampus (P-Guide)**, weil die Formvorgaben bisher nur aus einem Ratgeber stammen.

### Was du am Ende hast

Unter „Neu aus Vorlage → IU Hausarbeit“ entsteht ein Dokument, das schon richtig eingerichtet ist:
- Titelblatt mit deinen Daten
- Arial 11 pt, 1,5 Zeilen, 2 cm Rand
- Verzeichnisse an der richtigen Stelle
- römische Seitenzahlen vor der Einleitung, arabische ab dort.

Du schreibst nur noch. Bilder und Tabellen bekommen per Klick „Abb. 3“ und eine Quellenzeile nach IU-Muster, KI-Bilder ihren Prompt. Vor der Abgabe zeigt die Formalprüfung, was fehlt, mit Sprung zur Stelle. Die PDF ist dann so, wie die IU sie haben will.

### Was ich baue

| # | Baustein | Inhalt |
|---|---|---|
| I1 | **IU-Zitierstil** | Ein Stil je Dokument wählbar: „APA 7 deutsch“ oder „IU (APA 7 mit IU-Regeln)“. Der IU-Stil schreibt „et al.“ ab drei Autor:innen und kein Komma vor „&“, eine eingetragene 1. Auflage entfällt, und eine Pille ohne Seite bekommt einen Hinweis. |
| I2 | **Beschriftungen** | Abbildungen und Tabellen bekommen eine Überschrift „Abb. n“ bzw. „Tab. n“ mit Titel und darunter die Quellenzeile. Die Art wird aus dem IU-Muster gewählt (Eigene Darstellung, in Anlehnung an, geändert, auf der Basis von, Übernommen aus), die Quelle als Pille. Bilder aus Draw Things bekommen „Erstellt mit dem Prompt „…“ durch …“ vorgeschlagen. Nummeriert wird automatisch. |
| I3 | **Verzeichnisse** | Abbildungs-, Tabellen- und Abkürzungsverzeichnis sowie das Anhangsverzeichnis als Blöcke wie `[Literatur]`. Die Abkürzungen kommen aus einer Liste im Dokument. |
| I4 | **Querverweise** | „siehe Abb. 3“, „Kapitel 2.1“ als Verweise, die beim Umsortieren mitnummerieren. |
| I5 | **Seitenzählung** | Eine Marke „Textteil beginnt hier“: davor römisch, ab dort arabisch, das Titelblatt zählt als I ohne Nummer. Gilt im Editor, im Druck und im LaTeX-Export. |
| I6 | **Titelblatt** | Ein Block mit Feldern: Hochschule, Prüfungsform, Kurs, Studiengang, Titel, Name, Matrikelnummer, Betreuer:in, Datum. Name und Matrikelnummer stehen einmal in den Einstellungen der Bibliothek, gelten als privat (B) und sind für MCP gesperrt. |
| I7 | **Vorlagen** | Ordner `Vorlagen/` in der Bibliothek. Mitgeliefert: IU Hausarbeit, Fallstudie, Projektbericht, Bachelorarbeit und Präsentation, jeweils mit Stand-Datum und Quelle. Dazu „Als Vorlage sichern“ für jedes Dokument und „Neu aus Vorlage“ im Neu-Menü. |
| I8 | **Formalprüfung** | Deterministisch, ohne Modell. Sie prüft: Umfang des Textteils, höchstens drei Ebenen, keine Ebene mit nur einem Unterpunkt, Quelle bei jeder Abbildung und Tabelle, die Verzeichnisse ab drei Einträgen, Seite bei jeder Pille, Literaturverzeichnis vollständig und ohne Überzähliges, Warnung bei Skripten, Folien, Wikipedia und KI als Quelle. Das Ergebnis ist eine Liste mit Sprung zur Stelle, die Funde werden auf Wunsch To-dos (E3), und das Ganze gibt es auch als Action. Dazu kommt ein Seitenzähler „Textteil“ in der Statuszeile. |
| I9 | **Presenter** | IU-Präsentationsvorlage, die Literaturfolie entsteht automatisch aus den Pillen, und unter Bildern steht die Quellenzeile. |
| I10 | **KI-Hilfsmittel** | Ein Bericht, welche Bilder generiert und welche Absätze von der KI formuliert wurden, für den Abgleich mit der KI-Richtlinie der IU. Dafür merkt sich die KI-Leiste die Herkunft ihrer Absätze. |

**Speicherformat (Vorschlag, wird mit I2 festgelegt):** Beschriftung und Quellenzeile stehen im Markdown direkt am Bild bzw. an der Tabelle, in der Art der bestehenden Erweiterungen (Pandoc-Attribute mit eigener ID), damit Verweise und Verzeichnisse sie finden. Bevor ich etwas schreibe, das alte Dokumente anders lesen würde, lege ich dir das genaue Format vor.

### Abnahme

Eine neutral erzeugte Test-Hausarbeit aus der Vorlage ergibt eine PDF mit:
- Titelblatt ohne Nummer, römischen Seiten bis zur Einleitung und arabischen ab dort
- „Abb. 1–3“ mit Quellenzeilen und dem Abbildungsverzeichnis
- dem Literaturverzeichnis im IU-Stil.

Die Formalprüfung findet absichtlich eingebaute Fehler: eine Pille ohne Seite, eine Abbildung ohne Quelle, ein einzelnes Unterkapitel.

---

## 5. Startanweisungen für Claude Code

**E1 (nächste Sitzung)**
> Lies `docs/plan/Epics.md` (E1), `docs/actions.md`, `docs/architektur.md` und `docs/plan/Sicherheitskonzept-Prompt-Injection.md`. Setze E1.1 bis E1.7 in dieser Reihenfolge um, jeweils mit Tests. Du hast freie Hand. Die Rule of Two in `ActionPolicy` bleibt unverändert, und Freigaben beantwortet nur die Oberfläche. Am Ende jedes Bausteins Fortschritt in Abschnitt 6 eintragen.

**E2**
> Lies `docs/plan/Epics.md` (E2). Beginne mit T1 und trage die Messwerte ein, bevor du etwas änderst. Danach T2 und T3; T4 nur, wenn T1 beim Start eine spürbare Zeit misst.

**E3**
> Lies `docs/plan/Epics.md` (E3) und `docs/plan/Weiterentwicklung.md` Abschnitt 4.3. Zuerst Teil A (P1 bis P5), dann Teil B (P6 bis P9), falls E1 fertig ist. Schmale Fenster und die Eingaberegeln aus dem Stories Studio beachten.

**E4**
> Lies `docs/plan/Epics.md` (E4) und `docs/plan/Weiterentwicklung.md` Abschnitt 2.7 und 4.2. Gleiche die Formwerte mit dem Prüfungsleitfaden ab, den ich dir gebe. Lege mir das Markdown-Format für Beschriftungen vor, bevor du I2 baust.

---

## 6. Fortschritt

| Epic | Baustein | Status | Datum | Notizen |
|---|---|---|---|---|
| E1 | – | offen | | |
| E2 | – | offen | | |
| E3 | – | offen | | |
| E4 | – | offen | | wartet auf den Prüfungsleitfaden aus myCampus |
