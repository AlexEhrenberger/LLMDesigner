# PodcastStudio – Action-Katalog

_Teil der Action-Schicht · Grundlagen (Registry, Adressierung, Arten L/S/D) siehe `WriterStudio-Actions.md`_
_Stand: 11.11.2026 · alle Actions gebaut und über die Registry getestet (`PodcastActionTests`)_

Legende Art: **L** lesen · **S** schreiben (rückgängig machbar) · **D** destruktiv (Bestätigung je nach Freigabestufe)

---

## 0. Besonderheiten

**Datenmodell eines Podcasts:** Titel, Frage oder Thema, Länge (5, 10 oder 15 Minuten), Sprache, Sprachmodell (Qwen TTS `klein` oder `gross`, Vorgabe `klein`), Denkmodus, Ton (`sachlich` … `hitzig`), eigene Quellen (Webadressen, PDFs, „nur diese“), Teilnehmer, Referenzen, Recherche (Faktenblatt und gelesene Quellen), Gliederung, Skript (Zeilen mit Sprecher:in, Text und Dauer), Phase. Format: [Speicherformate](../speicherformate.md#podcasts).

**Teilnehmer:** genau eine Moderation und eine oder mehrere Diskutant:innen (höchstens fünf Personen). Jede Person hat einen Namen, mit dem die anderen sie ansprechen, eine Beschreibung (wer sie ist), eine Qwen-TTS-Stimme und einen Standpunkt. Ohne Angabe bekommt ein neuer Podcast eine Moderation und zwei Diskutant:innen mit verschiedenen Stimmen; `podcast.participants.suggest` lässt das Modell die Runde aus der Frage ableiten.

**Erzeugen:** `podcast.generate` startet im Hintergrund und kehrt sofort zurück; den Stand liefert `podcast.status`. Es läuft immer nur ein Podcast, weitere warten (`wartet`). Die Schritte:

0. **Eigene Quellen** werden zuerst gelesen (Webseiten über den Seitenleser, PDFs als Text). Mit `onlySources` entsteht das Faktenblatt allein aus ihnen, ohne Werkzeuge, und das Skript darf nichts behaupten, was dort nicht steht.
1. **Recherche** (bis zu acht Runden): Das Modell schlägt mit Denkmodus in Wikipedia und im Web nach. Antwortet es nach weniger als drei Nachschlagen schon, wird es einmal gebeten weiterzusuchen. Es gelten die Regeln des Chats: `open_page` öffnet nur Adressen aus der Frage oder aus Suchergebnissen, Gefundenes kommt als fremdes Material gerahmt zum Modell. Hat ein referenzierter Chat Persona-Dateien gelesen, gibt es nur Wikipedia.
2. **Skript:** erst die Gliederung (3, 5 oder 7 Abschnitte je nach Länge), dann jeder Abschnitt mit seinem Anteil an etwa 140 Wörtern pro Minute. Ein Abschnitt unter 60 % seines Anteils wird einmal fortgesetzt. Zeilen kommen als „Name: Text“; Regieanweisungen, Links und Markdown fallen weg, kurze Zeilen derselben Person werden zusammengelegt (Qwen TTS kippt bei wenigen Wörtern in eine andere Sprache).
3. **Sprachaufnahme:** Jede Zeile wird mit der Stimme ihrer Person gesprochen (lange Zeilen in Stücken), als `Schnipsel/<zeile>.wav` abgelegt und am Ende zu `Podcast.m4a` zusammengefügt.

`from` wählt den Einstieg: `fortsetzen` (Vorgabe: was fehlt – Recherche, Skript oder nur die noch nicht gesprochenen Zeilen), `alles`, `skript` (neues Skript auf der vorhandenen Recherche), `audio` (alle Zeilen neu sprechen). Wer eine Zeile ändert, löscht nur deren Schnipsel; `fortsetzen` spricht dann nur sie neu.

**Adressierung:**
- `--podcast <id|titel>` (Titel muss eindeutig sein)
- `--participant <id|name>`
- `--line` als ID oder Nummer ab 1 (wie in `podcast.read`)
- Referenzen als `--doc <id|titel>` (Dokument oder Präsentation), `--chat <id|titel>` oder `--world <id|titel>` mit optionalem `--part <id|Pfad>`

**Sicherheit:** Ein Podcast enthält, was die Recherche im Web gefunden hat. Lesen (`list`, `read`) zählt deshalb als fremd (A). `podcast.generate` meldet in der Vorprüfung fremdes Material und, wenn ein referenzierter Chat private Daten berührt, auch das (B). Export schreibt eine Datei und ist nach außen wirkend (C), im Exportordner gilt die Stufe „schreiben“. Während ein Podcast erzeugt wird, lehnen ändernde Actions ab; erst `podcast.stop`.

---

## 1. Podcasts

| Action | Parameter | Art |
|---|---|---|
| `podcast.list` | `query?` (Titel, Frage, Namen, Skript) | L |
| `podcast.create` | `question?`, `title?`, `minutes?`, `speechModel?`, `thinking?`, `tone?`, `urls?`, `onlySources?`, `participants?` (`[{role, name, description, voice, position}]`), `doc?`/`chat?`/`world?`+`part?`, `open?` | S |
| `podcast.read` | `podcast`, `research?` (Faktenblatt und Quellen), `script?` (Vorgabe ja), `format: json\|text` | L |
| `podcast.update` | `podcast`, `title?`, `question?`, `minutes?`, `speechModel?`, `language: de\|en`, `thinking?`, `tone: sachlich\|lebhaft\|kontrovers\|polemisch\|hitzig`, `onlySources?` | S |
| `podcast.toDocument` | `podcast`, `open?`: neues Writer-Dokument mit Frage, Teilnehmern, Gespräch, Faktenblatt und Quellen (Herkunft fremd, wenn recherchiert) | S |
| `podcast.delete` | `podcast` (Ordner mit Audio in den Papierkorb) | D |

Mit einer Referenz und ohne Frage schlägt `podcast.create` eine Frage zum Material vor („Worum geht es in „Bachelorarbeit“, und was ist davon zu halten?“).

## 2. Erzeugen

| Action | Parameter | Art |
|---|---|---|
| `podcast.generate` | `podcast`, `from: fortsetzen\|alles\|skript\|audio` | S |
| `podcast.status` | `podcast`: Phase, Prozent, laufender Schritt, Fehler, Platz in der Warteschlange, Audio aktuell, Wörter und Zielwörter | L |
| `podcast.stop` | `podcast` | S |

## 3. Teilnehmer und Referenzen

| Action | Parameter | Art |
|---|---|---|
| `podcast.participant.add` | `podcast`, `name`, `role?`, `description?`, `voice?`, `position?` | S |
| `podcast.participant.update` | `podcast`, `participant`, `name?`, `role?`, `description?`, `voice?`, `position?` | S |
| `podcast.participant.remove` | `podcast`, `participant` (nicht, solange die Person im Skript spricht) | S |
| `podcast.participants.suggest` | `podcast`, `count?` (2–4, Vorgabe 3) | S |
| `podcast.reference.add` | `podcast`, `doc`/`chat`/`world`+`part?` | S |
| `podcast.reference.remove` | `podcast`, `doc`/`chat`/`world`+`part?` (auch die ID von Gelöschtem) | S |
| `podcast.voices.list` | – : Stimmen des Qwen-TTS-Dienstes und Sprachmodelle | L |
| `podcast.source.add` | `podcast`, `url` **oder** `pdf` (Pfad; wird kopiert, aus Chat und MCP nur mit Freigabe), `onlySources?` | S |
| `podcast.source.remove` | `podcast`, `source` (Nummer ab 1, Adresse oder Titel); die PDF-Kopie wird gelöscht | D |

Wird jemand Moderation, wird die bisherige Moderation Diskutant:in.

## 4. Skript, Audio, Studio

| Action | Parameter | Art |
|---|---|---|
| `podcast.line.update` | `podcast`, `line`, `text?`, `speaker?` | S |
| `podcast.line.delete` | `podcast`, `line` | S |
| `podcast.export` | `podcast`, `path?` (ohne: Exportordner), `overwrite?` | D |
| `podcast.play` | `podcast`, `at?` (Sekunde) oder `line?`, `pause?` | L |
| `podcast.studio.open` | `podcast?` | L |
| `podcast.studio.close` | – | L |

---

## 5. Chat, MCP, Suchleiste

- Chat-Werkzeuggruppe `podcast.core`: `list`, `create`, `read`, `status`, `generate`, `participant.add`, `participant.update`, `participants.suggest`, `reference.add`, `source.add`, `toDocument`, `play`.
- MCP-Profil `podcast`; Resource `llmd://podcast/podcast/{id}` (wie `podcast.read --research`); Ereignis `podcast.changed` meldet Änderungen an Abonnenten.
- Die Suchleiste nimmt die Gruppe bei Wörtern wie „Podcast“, „Hörspiel“, „Gesprächsrunde“, „vertonen“.

```bash
llmd podcast create --question "Was ist Predictive Coding, und ist das ein zeitgemäßes Paradigma?" --minutes 10
llmd podcast participants suggest --podcast "Predictive Coding"
llmd podcast generate --podcast "Predictive Coding"
llmd podcast status --podcast "Predictive Coding"
llmd podcast export --podcast "Predictive Coding"
```
