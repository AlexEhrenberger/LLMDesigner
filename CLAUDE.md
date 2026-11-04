# LLM Designer

Native macOS-App (SwiftUI + AppKit) auf lokalen Sprachmodellen. Swift Package ohne Xcode-Projekt.

## Befehle

```bash
scripts/build-app.sh release --open   # baut build/LLM Designer.app inkl. llmd und startet sie
scripts/test.sh                       # alle Tests (Swift Testing, ~1 min)
scripts/test.sh --filter ActionPolicyTests
```

Immer `scripts/test.sh` statt `swift test`: Die Command Line Tools brauchen die Suchpfade für Swift Testing.

## Dokumentation

- `docs/architektur.md`, `docs/code.md`, `docs/speicherformate.md`, `docs/funktionen.md`
- `docs/plan/Implementierungsplan.md`: Action-Schicht → CLI `llmd` → MCP, mit Fortschritt in Abschnitt 8
- `docs/plan/*-Actions.md`: Action-Kataloge, `docs/plan/Sicherheitskonzept-Prompt-Injection.md`: Sicherheitsregeln
- `docs/actions.md`: Registry, Regeln, CLI und MCP im Überblick

## Regeln

- Swift 6 Toolchain, `swiftLanguageMode(.v5)`, macOS 15. Zustand auf dem Main Actor, Netz und Prozesse in `Task`s.
- Oberfläche und Fehlermeldungen deutsch; Code und Kommentare englisch, Kommentare erklären das Warum.
- Bestehende Funktionen aus `AppModel+*.swift` wiederverwenden. Actions sind dünne Hüllen.
- Daten und Einstellungen gehören in die Bibliothek (`AppLibrary.current`), nie nach Application Support oder `UserDefaults`. Ausnahme: Socket und Token von `llmd` sind Laufzeitdateien ohne Daten.
- Keine neuen Fremdabhängigkeiten ohne Rückfrage.

## Sicherheit

- Schutz entsteht durch Regeln im Code, nie durch Anweisungen im Prompt.
- Jede Action deklariert `readsUntrusted`, `sensitive` und `effect`.
- Keine Netzwerkports. Der Socket gehört nur dem eigenen Benutzer.
- API-Schlüssel nie in Ergebnissen, Protokoll oder Fehlermeldungen.
- Art D läuft immer durch die Freigabeprüfung.

## Tests

- Jede Action hat einen Test, der sie direkt über die Registry ausführt, ohne Socket und ohne Fenster.
- `TestApp.model()` liefert einen `AppModel` auf einer Wegwerf-Bibliothek. Tests suchen, was sie angelegt haben, nicht ganze Listen.
- Testdaten sind neutral erzeugt, nie Dateien des Nutzers.
- Bei Unklarheit (besonders bei Datenformaten) anhalten und fragen.
