# Learning-Actions

Learning Studio: Disziplinen, Kurse, Karten, Lernen, Pausen, Material, Modell-Hilfe. Kurse lesen gilt als fremd (Material aus PDFs, Karten von Agenten). Speicherformat: [Speicherformate › Learning Studio](../speicherformate.md#learning-studio).

| Action | Was sie tut | Art | Sicherheit |
|---|---|---|---|
| `learning.overview` | Lernfortschritt im Überblick: Disziplinen mit Wachstum ihres Baums, Kurse mit fälligen und gelernten Karten, Tage in Folge, Pausen | read | `learningRead` |
| `learning.discipline.create` | Legt eine Disziplin an (ein Baum im Garten), z. B. Psychologie | write | `.localWrite` |
| `learning.discipline.update` | Ändert Name, Baumart oder Farbe einer Disziplin | write | `.localWrite` |
| `learning.discipline.delete` | Entfernt eine Disziplin; ihre Kurse bleiben ohne Disziplin erhalten | destructive | `.destructive` |
| `learning.course.list` | Listet Kurse mit Karten, Fälligen, Fortschritt und Prüfungstermin | read | `learningRead` |
| `learning.course.create` | Legt einen Kurs an, auf Wunsch in einer Disziplin (die es noch nicht gibt, entsteht) und mit Prüfungstermin | write | `.localWrite` |
| `learning.course.read` | Liest einen Kurs: Statistik, Material, Verknüpfungen und (mit cards) die Karten | read | `learningRead` |
| `learning.course.update` | Ändert Name, Beschreibung, Disziplin, Prüfungstermin oder Abschluss eines Kurses | write | `.localWrite` |
| `learning.course.delete` | Legt einen Kurs mit Karten und Material in den Papierkorb | destructive | `.destructive` |
| `learning.card.add` | Legt eine Karteikarte an (Vorderseite: Frage, Rückseite: Antwort) | write | `.localWrite` |
| `learning.card.addMany` | Legt viele Karten an: als Liste {front, back} oder als Text mit einer Karte je Zeile (Frage ; Antwort) | write | `.localWrite` |
| `learning.card.update` | Ändert eine Karte, stellt sie zurück (suspended) oder setzt ihren Lernstand zurück (reset) | write | `.localWrite` |
| `learning.card.delete` | Löscht eine Karte mit ihrem Lernverlauf | destructive | `.destructive` |
| `learning.due` | Was jetzt zu lernen ist (in Reihenfolge); ohne answers nur die Vorderseiten, so kann der Chat abfragen und dann mit learning.review bewerten | read | `learningRead` |
| `learning.review` | Bewertet die Antwort auf eine Karte (nochmal, schwer, gut, leicht oder 1–4) und plant sie neu | write | `.localWrite` |
| `learning.stats` | Statistik eines Kurses: Karten je Stand, Behaltensrate, Antworten der letzten 30 Tage, Fälligkeiten der nächsten 14 | read | `learningRead` |
| `learning.pause` | Plant eine Lernpause (Urlaub) für alles, eine Disziplin oder einen Kurs; danach rücken die Karten um die Pausenlänge weiter | write | `.localWrite` |
| `learning.resume` | Beendet alle laufenden Lernpausen jetzt; die Karten rücken um die Pausenlänge weiter | write | `.localWrite` |
| `learning.settings` | Zeigt oder ändert den Lernalgorithmus (fsrs, sm2), die Behaltensrate und die Tagesgrenzen | write | `.localWrite` |
| `learning.material.add` | Hinterlegt Material: einen Link (YouTube wird erkannt), eigenen Text oder eine Quelle aus Citation Studio (Citekey) | write | `.localWrite` |
| `learning.link.add` | Verknüpft ein Dokument, eine Präsentation, ein Note, einen Chat, ein Projekt oder einen Teil einer Romanwelt mit einem Kurs | write | `.localWrite` |
| `learning.ai.cards` | Lässt das lokale Modell Karteikarten aus Material des Kurses (oder dem ganzen Kurs) erstellen | write | `ActionSecurity(readsUntrusted: true` |
| `learning.ai.sheet` | Lässt das lokale Modell einen Lernzettel (Writer-Dokument) aus Material des Kurses schreiben; er wird mit dem Kurs verknüpft | write | `ActionSecurity(readsUntrusted: true` |
| `learning.studio.open` | Öffnet Learning Studio: den Garten oder einen Kurs, auf Wunsch gleich zum Lernen | read | `.plainRead` |
| `learning.studio.close` | Schließt Learning Studio | read | `.plainRead` |
