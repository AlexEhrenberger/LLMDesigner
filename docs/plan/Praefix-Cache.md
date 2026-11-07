# Implementierungsplan: Stabiler Prompt-Anfang für den Präfix-Cache

_Vorschlag von Claude Code · Stand: 07.11.2026 · Basis-Commit: `60354a5`_
_Status: **zur Entscheidung**. Gebaut wird erst nach deinem Ja._

---

## 1. Warum

Kapitsa und LM Studio merken sich den Anfang eines Prompts (Präfix-Cache). Stimmt der Anfang der nächsten Anfrage Zeichen für Zeichen überein, liest das Modell nur das Neue. Ab der ersten Abweichung liest es alles danach neu.

Auf diesem Mac liest Qwen 3.5 9B in Kapitsa nur 120–180 Token/s (gemessen am 25.10.: 13K Token in 72 s). Ein Chat mit 8 000 Token Verlauf wartet bei verfehltem Cache also **etwa 50 s** auf das erste Wort, bei Treffer **etwa 2 s**. Kapitsa hebt Gespräche außerdem auf der SSD auf, auch über einen Neustart hinweg (`~/.cache/kapitsa/prefix-cache`, gerade 24 GB, 75 Gespräche). Davon hat die App nur etwas, wenn sie denselben Anfang wieder schickt.

---

## 2. Was den Cache heute bricht

Gefunden im Code, mit Ort und Wirkung:

| # | Ursache | Ort | Wann | Wirkung |
|---|---|---|---|---|
| 1 | **Uhrzeit** im System-Prompt („Heute ist …, 14:35 Uhr.“) | `WebTools.systemHint`, `WebTools.swift:86` | jeder Chat mit Web oder Wikipedia, jede Minute | ganzer Verlauf neu |
| 2 | **Erinnerungen der Runde** werden ans Ende des System-Prompts gehängt | `AppModel.generate` → `adding(_:toSystemOf:)`, `AppModel.swift:1411` | Persona mit Gedächtnis, sobald ein Schlagwort passt (ein Treffer genügt) | ganzer Verlauf neu |
| 3 | **„vor 20 Minuten“** in „Deine letzten Gespräche“ | `ThalamusRecall.relative` mit `RelativeDateTimeFormatter`, `Thalamus.swift:549` | Persona mit Gedächtnis, wenn ein anderes Gespräch kurz zurückliegt | ganzer Verlauf neu, solange Minuten und Stunden zählen |
| 4 | **Schlüsselreihenfolge im JSON** der Werkzeuge ändert sich bei jedem Start der App | `LLMClient.streamChat`: `JSONEncoder()` ohne `.sortedKeys` | jeder Chat mit Werkzeugen, nach jedem Neustart | Werkzeuge und Verlauf neu, falls Kapitsa die Reihenfolge übernimmt (Phase 0 klärt das) |
| 5 | **Hinweis für gesprochene Antworten** am Ende des System-Prompts | `AppModel.generate`, `ConversationSession.systemHint` | Wechsel zwischen Tippen und Sprechen im selben Chat | ganzer Verlauf neu |

Zu Nr. 4, heute gemessen: dasselbe Wörterbuch, viermal mit `JSONEncoder` geschrieben, ergab vier verschiedene Reihenfolgen. Auch die Felder von Structs kamen in wechselnder Reihenfolge heraus, nicht in der Reihenfolge, in der der Code sie schreibt. Swift würfelt die Hash-Reihenfolge pro Prozess neu. Fest wird die Reihenfolge nur mit `.sortedKeys`.

**Kein Problem**, weil es nur das Ende betrifft: neue Nachrichten, Werkzeugrunden innerhalb einer Antwort, und dass die vorige Antwort ohne ihre Werkzeugschritte wiederkommt (`WebTools.historyContent`). Auch zugeschaltete Werkzeuggruppen in der Suchleiste brechen den Cache nur einmal, und die Gruppen kommen in fester Reihenfolge aus der Registry.

---

## 3. Lösung

Die Regel: **Was sich pro Runde ändert, gehört an das Ende, nie in den System-Prompt.**

| # | Änderung |
|---|---|
| 1 | Der System-Prompt nennt nur das **Datum**. Die Uhrzeit fällt weg (Entscheidung 1). Das Datum wechselt einmal am Tag. |
| 2 | Die Erinnerungen der Runde kommen **vor die neueste Nachricht**, in derselben Nachricht und deutlich gerahmt („Woran du dich gerade erinnerst, nicht von deinem Gegenüber geschrieben“). Gespeichert wird nichts davon, wie heute. Eine zweite System-Nachricht mitten im Verlauf wäre unsicher: Die Vorlagen von Qwen und Gemma sind für System-Text am Anfang gebaut, manche brechen sonst mit einem Fehler ab. |
| 3 | Relative Zeiten in Erinnerungen **nach Kalendertagen**: „heute“, „gestern“, „vor 3 Tagen“, „vor 2 Wochen“. Das genaue Datum steht ohnehin dabei. |
| 4 | Die Anfrage an den Chat geht mit `.sortedKeys` hinaus, damit dieselben Werkzeuge immer dieselben Zeichen ergeben, auch nach einem Neustart. `complete()` bekommt dasselbe über `JSONSerialization` mit `.sortedKeys`; das geordnete Schema (`orderedSchema`) wird erst danach eingesetzt und behält seine Reihenfolge. Folge: Die Parameter der Werkzeuge stehen alphabetisch, heute stehen sie zufällig. |
| 5 | Der Hinweis für gesprochene Antworten wandert ebenfalls vor die neueste Nachricht. |
| 6 | **Messen statt raten:** Die App liest `usage.prompt_tokens_details.cached_tokens` (Kapitsa liefert es) und zeigt unter der Antwort neben Token/s: „8 412 Token gelesen, 8 120 aus dem Cache“. |

Damit das so bleibt, wird der Zusammenbau der Anfrage aus `AppModel.generate` (heute etwa 40 Zeilen mitten in der Funktion) in einen eigenen, reinen `ChatPayloadBuilder` gezogen. Dessen Verhalten ist sonst unverändert, aber er lässt sich ohne Netz und ohne Fenster testen.

---

## 4. Phasen

### Phase 0 – Messinstrument und Messung vorher (klein)

| # | Aufgabe |
|---|---|
| 0.1 | `StreamChunk.Usage` liest `promptTokensDetails.cachedTokens`; `StreamEvent.usage` reicht es weiter; `GenerationStats` bekommt das optionale Feld `cachedPromptTokens` (Entscheidung 3). Anzeige in der Infozeile unter der Antwort (`MessageViews.swift:365`). |
| 0.2 | Messung gegen Kapitsa auf einer Wegwerf-Bibliothek mit neutralen Testdaten, je zwei Runden: (a) Chat mit Web, Runden über eine Minute auseinander; (b) Persona mit Gedächtnis; (c) Chat mit Werkzeugen vor und nach einem Neustart der App; (d) wie (a) mit Gemma in LM Studio; (e) mit Inhaltsverzeichnis und Folgefragen nach der Antwort (verdrängen diese Aufrufe den Platz des Chats in Kapitsas zwei Slots?). Festgehalten werden gelesene und gecachte Token sowie die Zeit bis zum ersten Token. |
| 0.3 | Ergebnis vorlegen. Zeigt (c) keinen Verlust, weil Kapitsa die Reihenfolge selbst ordnet, bleibt Nr. 4 trotzdem drin (LM Studio, ein Zeichen Aufwand), wird aber nicht als Gewinn gezählt. |

### Phase 1 – Die Korrekturen (klein bis mittel)

| # | Aufgabe |
|---|---|
| 1.1 | `ChatPayloadBuilder` aus `AppModel.generate` herauslösen: System-Prompt, Hinweise, `<\|think\|>`, Verlauf, Bilder, dazu der Platz für den Text der Runde. `generate` ruft ihn auf; die Erinnerungen setzt nach dem Thalamus-Lauf derselbe Builder ein, statt `adding(_:toSystemOf:)`. |
| 1.2 | Nr. 1: `WebTools.systemHint` ohne Uhrzeit, mit eingespeistem `now` wie heute. |
| 1.3 | Nr. 2 und 5: Text der Runde vor die neueste Nachricht. |
| 1.4 | Nr. 3: `ThalamusRecall.relative` nach Kalendertagen. |
| 1.5 | Nr. 4: `.sortedKeys` in `streamChat` und `complete()`. |
| 1.6 | **Präfix-Tests** (Swift Testing, ohne Modell): Runde n und Runde n+1 werden mit verschiedenen Uhrzeiten, verschiedenen Erinnerungen und gesprochen/getippt zusammengebaut; bis zur vorletzten Nachricht müssen die Bytes gleich sein. Werkzeug-JSON aus zwei verschieden aufgebauten Wörterbüchern muss byte-gleich sein. Ein Test prüft, dass `orderedSchema` seine Reihenfolge behält. Ein bestehender `FakeLLMServer`-Test schaut, dass die Erinnerung tatsächlich in der Anfrage steht. |
| 1.7 | Antwortqualität mit Gedächtnis: dieselbe Testpersona und drei Fragen, vorher und nachher, mit Qwen 3.5 9B. Greift die Persona die Erinnerung noch so auf wie heute? Wenn nicht: Rahmen anpassen, bevor committet wird. |

### Phase 2 – Messung nachher und Doku (klein)

| # | Aufgabe |
|---|---|
| 2.1 | Messung 0.2 wiederholen, Vorher/Nachher-Tabelle hier eintragen. |
| 2.2 | `docs/architektur.md`, Abschnitt „Sprachmodelle“: die Regel aus Abschnitt 3 und warum. Vorschlag: dieselbe Regel als eine Zeile in `CLAUDE.md` (Entscheidung 4), damit spätere Funktionen den Cache nicht wieder brechen. |

**Umfang:** eine Sitzung; geschätzt 250–400 Zeilen einschließlich Tests, davon der größte Teil Tests und das Herauslösen in 1.1.

---

## 5. Risiken

| Risiko | Gegenmittel |
|---|---|
| Ohne Uhrzeit beantworten Modelle „wie spät ist es“ nicht mehr | heute eher ein Nebeneffekt; wenn gewünscht, kommt die Uhrzeit an die neueste Nachricht (Entscheidung 1) |
| Erinnerungen in der Nachricht des Nutzers verwechselt das Modell mit dessen Worten | deutlicher Rahmen, Prüfung in 1.7 |
| Alphabetische Parameter verwirren kleine Modelle | heute ist die Reihenfolge zufällig; fällt 1.7 oder ein Werkzeugtest auf, kommen Pflichtparameter zuerst (eigene Ausgabe statt `.sortedKeys`) |
| Inhaltsverzeichnis, Folgefragen und Thalamus-Aufrufe verdrängen den Chat aus dem Cache | gemessen am 07.11.: tun sie nicht |

---

## 6. Offene Entscheidungen

1. **Uhrzeit:** ganz weglassen (empfohlen) oder als kurze Zeile an die neueste Nachricht hängen?
2. **Erinnerungen der Runde** an die neueste Nachricht statt in den System-Prompt: einverstanden? Ohne das bleibt der Cache in Gedächtnis-Chats wirkungslos.
3. **Neues optionales Feld** `cachedPromptTokens` in den Statistiken jeder Antwort (Chat-JSON). Alte Chats bleiben lesbar.
4. **Regel in `CLAUDE.md`** aufnehmen?

---

## 7. Fortschritt

| Phase | Status | Datum | Notizen |
|---|---|---|---|
| 0 | fertig | 07.11.2026 | Messinstrument gebaut (`cachedPromptTokens`, Anzeige unter der Antwort, Test `ChatMoreActionTests.cachedPromptTokens`, `FakeLLMServer.usage`); 593 Tests grün. Messung siehe unten. LM Studio (d) nicht gemessen, weil es nicht lief. |
| 1 | fertig | 07.11.2026 | Entscheidungen: Uhrzeit fällt weg, Erinnerungen der Runde an die neueste Nachricht. `ChatPayloadBuilder` neu; `WebTools.systemHint` nur mit Datum; `ThalamusRecall.relative` nach Kalendertagen; `LLMClient.requestBody` und `complete()` mit sortierten Schlüsseln. `PromptPrefixTests` (6 Tests) und `ChatMoreActionTests.turnNotesGoWithTheQuestion`; 601 Tests grün. Qualität (1.7) und Messung nachher siehe unten. |
| 2 | teilweise | 07.11.2026 | `docs/architektur.md` und `docs/code.md` nachgetragen. Offen: Entscheidung 4 (Regel in `CLAUDE.md`), Messung mit LM Studio. |

### Messung vorher (07.11.2026, Kapitsa 0.2.15, Qwen 3.5 9B, Denken aus)

Direkt gegen Kapitsa, je zwei Runden eines neutralen Gesprächs mit rund 2 200 Token; jeder Fall mit eigener Kennung am Anfang, damit sich die Fälle nicht gegenseitig bedienen. Skript im Scratchpad der Sitzung (`cache_probe.py`).

| Fall | Runde 2: Prompt | aus dem Cache | neu gelesen | erstes Token nach |
|---|---|---|---|---|
| Kontrolle, nichts ändert sich | 2 210 | 2 175 | 35 | 0,26 s |
| Nr. 1 Uhrzeit 14:35 → 14:36 | 2 249 | **0** | 2 249 | 11,1 s |
| Nr. 1 gelöst: nur Datum | 2 226 | 2 191 | 35 | 0,29 s |
| Nr. 2 Erinnerung der Runde im System-Prompt | 2 252 | **0** | 2 252 | 11,1 s |
| Nr. 3 „vor 20 Minuten“ → „vor 21 Minuten“ | 2 241 | **0** | 2 241 | 11,6 s |
| Nr. 4 Werkzeuge, gleiche Reihenfolge | 2 723 | 2 688 | 35 | 0,27 s |
| Nr. 4 Werkzeuge, Reihenfolge wie nach Neustart | 2 726 | **0** | 2 726 | 13,3 s |
| drei Nebenaufrufe (Gliederung, Folgefragen …) zwischen den Runden | 2 211 | 2 176 | 35 | 0,41 s |

Befunde:
- **Eine Abweichung kostet alles**, nicht nur den Teil dahinter: Selbst der gleiche Anfang vor der Uhrzeit (rund 40 Token) kam nicht aus dem Cache. Wo im System-Prompt etwas wechselt, ist also gleichgültig.
- **Nr. 4 ist echt:** Kapitsa übernimmt die Schlüsselreihenfolge. Nach jedem Neustart der App liest ein Chat mit Werkzeugen alles neu, und der SSD-Cache hilft dann nicht.
- **Nebenaufrufe verdrängen den Chat nicht** (zwei Slots plus SSD-Cache). Das Risiko aus Abschnitt 5 fällt weg.
- Prefill hier etwa 200 Token/s; mit Cache kommt das erste Token nach 0,3 statt 11 s, bei 8 000 Token Verlauf wären es rund 40 s.

Gegenprobe in der echten App (frisch gebaut, Wegwerf-Bibliothek, Kapitsa, Fragen über eine Minute auseinander):

| Chat | Runde | Prompt | aus dem Cache | erstes Token nach |
|---|---|---|---|---|
| mit Websuche | 2 | 2 306 | **0** | 15,4 s |
| ohne Websuche | 2 | 1 699 | 1 620 | 3,4 s |

### Nachher (07.11.2026, gleicher Aufbau, App neu gebaut)

| Chat | Runde | Prompt | aus dem Cache | erstes Token nach |
|---|---|---|---|---|
| mit Websuche | 2 | 2 278 | **2 208** | 2,6 s |
| ohne Websuche | 2 | 1 683 | 1 620 | 3,1 s |

Die übrigen Fälle (Erinnerung der Runde, „vor … Minuten“, Werkzeuge nach Neustart) laufen über `llmd` nicht nach, weil eine Runde aus einer Action ohne Werkzeuge läuft und Erinnerungen erst nach mehreren Chats auslösen. Ihre Lösung ist durch die Direktmessung oben (Nr. 1 gelöst, Nr. 4 gleiche Reihenfolge) und die Präfix-Tests belegt.

**Qualität mit Gedächtnis (1.7):** Eine Testpersona (Bergführerin, erfundene Erinnerungen an Ätna, Knie, Nachbarshund) bekam drei Fragen, je mit der Erinnerung im System-Prompt und gerahmt vor der Frage (Qwen 3.5 9B, Temperatur 0,7, je ein Lauf). In beiden Fassungen greift sie die Erinnerung natürlich auf; der Rahmen „Hinweis der App“ taucht in keiner Antwort auf. Die Schwächen des kleinen Modells (es tut so, als wäre es mit auf dem Ätna gewesen) zeigen beide Fassungen. Ein Lauf je Frage ist eine Stichprobe, kein Beweis.
