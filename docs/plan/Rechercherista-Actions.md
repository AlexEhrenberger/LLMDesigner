# Rechercherista-Actions

Recherchen lesen gilt als fremd (Webseiten, Abstracts). Starten und Antworten wirken nach außen, weil Suchwörter den Mac verlassen; die App fragt deshalb nach. Speicherformat: [Speicherformate › Rechercherista](../speicherformate.md#rechercherista).

| Action | Was sie tut | Art | Sicherheit |
|---|---|---|---|
| `research.list` | Listet die Recherchen mit Phase, Fortschritt, Zahl der Teilfragen und Quellen | read | `.plainRead` |
| `research.read` | Liest eine Recherche: Rückfrage, Fragenbaum mit Zusammenfassungen, Quellen und Bericht | read | `researchRead` |
| `research.start` | Startet eine gründliche Recherche (Deep Research) zu einer Frage oder setzt eine fort; sie läuft im Hintergrund. Aus dem Chat öffnet sie Rechercherista. | destructive | `.outbound` |
| `research.answer` | Beantwortet die Rückfrage einer Recherche (was gemeint ist); sie läuft dann weiter | destructive | `.outbound` |
| `research.stop` | Hält eine laufende Recherche an; research.start mit research setzt sie fort | write | `.localWrite` |
| `research.source.set` | Nimmt eine Quelle einer Recherche an (accepted true), verwirft sie (false) oder lässt sie offen | write | `.localWrite` |
| `research.report` | Gibt den Bericht einer fertigen Recherche als Markdown mit Quellenverzeichnis | read | `researchRead` |
| `research.toDocument` | Macht aus dem Bericht ein Writer-Dokument (mit Quellen); für eine Präsentation danach presenter.fromDocument | write | `.localWrite` |
| `research.toPodcast` | Legt einen Podcast über die Recherche an (ihr Bericht wird sein Material) und öffnet PodcastStudio | write | `.localWrite` |
| `research.delete` | Legt eine Recherche in den Papierkorb | destructive | `.destructive` |
| `research.studio.open` | Öffnet Rechercherista, auf Wunsch bei einer Recherche | read | `.plainRead` |
| `research.studio.close` | Schließt Rechercherista | read | `.plainRead` |
