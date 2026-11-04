# CLI-Konzept: `llmd`

_Status: **aus dem Implementierungsplan abgeleitet**, weil das Original beim Start nicht vorlag. Bitte gegen das Original prüfen. Die Abschnittsnummern entsprechen den Verweisen im Plan._

## 1. Idee

`llmd` ist ein dünner Client. Er spricht über einen Unix-Socket mit der laufenden App, die alle Actions ausführt. Die Befehle entstehen aus den Schemas der Registry, das Werkzeug kennt keine Action fest.

## 2. Grundbefehle

```bash
llmd status                         # Version, Bibliothek, Modell
llmd actions [--module writer]      # alle Actions
llmd describe writer.format.bold    # Schema und Beispiel
llmd call writer.doc.list --json    # Action nach ID, Parameter als Optionen oder --args '{…}'
llmd batch < schritte.jsonl         # mehrere Actions, eine Undo-Gruppe
llmd watch                          # Ereignisse
llmd completion zsh                 # Tab-Vervollständigung
llmd mcp [--profile core]           # MCP-Server über stdio
```

## 3. Dynamische Befehle

`llmd writer format bold --doc X --match "Wort"` entspricht `writer.format.bold`. Punkte werden zu Wörtern, `camelCase` zu `--kebab-case`, Pflichtparameter dürfen als Positionsparameter stehen. Werte von Listen und Objekten gehen als JSON.

## 4. Globale Optionen

| Option | Bedeutung |
|---|---|
| `--json` | Ergebnis als JSON |
| `--quiet` | keine Ausgabe, nur Exit-Code |
| `--stdin` | größter Textparameter (oder `--stdin-to name`) kommt von der Standardeingabe |
| `--no-launch` | App nicht starten, wenn sie nicht läuft |
| `--run <id>` | Lauf-Kennung (auch `LLMD_RUN`), siehe Sicherheitskonzept 4.3 |

## 5. Ausgabe

Für Menschen knapp und lesbar, mit `--json` das unveränderte Ergebnis. Fehler gehen nach stderr.

## 6. Exit-Codes

| Code | Bedeutung |
|---|---|
| 0 | Erfolg |
| 1 | Allgemeiner Fehler |
| 2 | Falsche Parameter oder unbekannte Action |
| 3 | App nicht erreichbar |
| 4 | Verweigert oder nicht freigegeben |
| 5 | Nicht gefunden oder mehrdeutig |
| 6 | Versionskonflikt (`ifVersion`) |

## 7. Schema-Cache

Das Schema liegt je App-Version in `~/Library/Caches/LLMDesigner/llmd-actions-<version>.json`. Es enthält nur Beschreibungen, keine Daten.

## 8. Beispiele

```bash
DOC=$(llmd writer doc create --title "Bericht" --json | jq -r .id)
llmd writer text insert-markdown --doc "$DOC" --markdown "# Titel

Ein **Absatz**."
llmd writer format italic --doc "$DOC" --match "Absatz" --state on
llmd writer export --doc "$DOC" --format pdf --json
cat kapitel.md | llmd writer text insert-markdown --doc "$DOC" --stdin
```

## 9. Sicherheit

Socket im Ordner `~/Library/Application Support/LLMDesigner/` (Ordner 0700, Socket 0600), Peer-UID-Prüfung, Token-Datei 0600. Keine Netzwerkports.
