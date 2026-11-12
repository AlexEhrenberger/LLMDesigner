# Data-Actions

Data Studio: Datenblöcke (`{{kürzel.feld}}`), Vorlagen und Masterfolien. Werte lesen ist privat (`sensitiveRead`), Namen und Kürzel nicht. Speicherformat: [Speicherformate › Data Studio](../speicherformate.md#data-studio).

| Action | Was sie tut | Art | Sicherheit |
|---|---|---|---|
| `data.block.list` | Listet die Datenblöcke mit Kürzel, Gruppe und Feldnamen (ohne Werte) | read | `.plainRead` |
| `data.block.read` | Liest einen Datenblock mit allen Werten und seinem Platzhalter {{kürzel.feld}} je Feld (private Daten) | read | `dataValuesRead` |
| `data.block.create` | Legt einen Datenblock an: aus einer Struktur (person, organisation, anschrift, kontakt, bank, frei) mit values {feld: wert} und/oder eigenen Feldern | write | `.localWrite` |
| `data.block.update` | Ändert Name, Gruppe, Darstellung oder Notiz eines Datenblocks; key ändert das Kürzel und mit rewrite alle Texte, die es nutzen | write | `.localWrite` |
| `data.block.delete` | Legt einen Datenblock in den Papierkorb; Texte, die ihn nutzen, zeigen dann ihren Platzhalter | destructive | `.destructive` |
| `data.field.set` | Setzt Werte eines Datenblocks: field + value (und name, kind, key) für ein Feld oder values {feld: wert} für mehrere; fehlende Felder entstehen | write | `.localWrite` |
| `data.field.remove` | Entfernt ein Feld aus einem Datenblock (rückgängig machbar) | write | `.localWrite` |
| `data.resolve` | Setzt in einen Text die Werte seiner Platzhalter {{kürzel.feld}} ein und nennt die, die es nicht gibt (private Daten) | read | `dataValuesRead` |
| `data.block.usages` | Nennt die Dokumente, Präsentationen und Notes, die einen Datenblock verwenden | read | `.plainRead` |
| `data.structure.list` | Listet die Strukturen für neue Datenblöcke mit ihren Feldkürzeln und die Feldarten | read | `.plainRead` |
| `data.template.list` | Listet die Vorlagen: Dokumentvorlagen (writer, z. B. Brief DIN 5008, Lebenslauf) und Masterfolien (presenter) | read | `.plainRead` |
| `data.template.read` | Liest eine Vorlage: Rollen, Text mit Platzhaltern oder Master (Logo, Kopf- und Fußzeile) | read | `.plainRead` |
| `data.template.create` | Legt eine Vorlage an: writer mit markdown und Rollen oder presenter mit Kopf-/Fußzeile; from kopiert eine bestehende (auch mitgelieferte) | write | `.localWrite` |
| `data.template.update` | Ändert eine eigene Vorlage: Name, Text, Kopf-/Fußzeile, Seitenzahlen, Logo-Ecke und -Größe | write | `.localWrite` |
| `data.template.delete` | Legt eine eigene Vorlage in den Papierkorb; Präsentationen mit diesem Master verlieren ihn | destructive | `.destructive` |
| `data.template.use` | Erstellt aus einer Vorlage ein Writer-Dokument oder eine Präsentation; blocks ordnet jeder Rolle einen Datenblock zu ({"absender": "user1"}). Die Felder bleiben verknüpft. | write | `.localWrite` |
| `data.template.fromDocument` | Macht aus einem Dokument oder einer Präsentation eine Vorlage; die Datenblöcke im Text werden zu Rollen | write | `.localWrite` |
| `data.master.apply` | Setzt einer Präsentation eine Masterfolie (Logo, Kopf-, Fußzeile auf jeder Folie); ohne template nimmt sie ihn ab. design übernimmt auch das Design. | write | `.localWrite` |
| `data.studio.open` | Öffnet Data Studio, auf Wunsch bei einem Datenblock oder einer Vorlage | read | `.plainRead` |
| `data.studio.close` | Schließt Data Studio | read | `.plainRead` |
