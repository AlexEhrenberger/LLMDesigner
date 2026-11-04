# MCP-Schicht

_Status: **aus dem Implementierungsplan abgeleitet**, weil das Original beim Start nicht vorlag. Bitte gegen das Original prüfen. Die Abschnittsnummern entsprechen den Verweisen im Plan._

## 1. Tools

`llmd mcp` ist ein stdio-Adapter vor derselben Registry. `tools/list` kommt aus `actions.list`: Namen mit Unterstrich (`writer_format_bold`), `inputSchema` (JSON Schema 2020-12), `outputSchema`, Annotationen aus Art und Wirkung, feste Reihenfolge. `tools/call` führt `action.run` aus; das Ergebnis kommt als `structuredContent` plus Kurztext, Fehler als `isError`.

**Profile:** `core`, `writer`, `presenter`, `citation`, `stories`, `chat`, `full`. Dazu die Meta-Tools `llmd_search_actions` und `llmd_run_action`, damit kleine Modelle nicht alle Tools laden müssen.

## 2. Resources, Prompts, Abonnements

| Art | Inhalt |
|---|---|
| Resources | `llmd://writer/doc/{id}`, `llmd://presenter/deck/{id}`, `llmd://citation/source/{key}`, `llmd://stories/world/{id}` |
| Prompts | aus Skills; Skills mit Herkunft `fremd` nur nach Bestätigung |
| Abonnements | Änderungen aus `events.subscribe` |

## 3. Sicherheit

Der Kanal heißt `mcp`. Er gilt als fremd, sensible Gruppen sind gesperrt, `outbound` nur mit Freigabe (Sicherheitskonzept Abschnitt 5).

## 4. Einrichtung

```bash
claude mcp add llmd -- "/Applications/LLM Designer.app/Contents/Helpers/llmd" mcp --profile core
```
