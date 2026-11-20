# Finance-Actions

FinanceStudio: ein Konto, seine Buchungen, Kategorien, Gruppen ähnlicher Posten und die Planung (Einkommen, Fixkosten, Ausgabeprojekte, Sparziele). Speicherformat: [Speicherformate › FinanceStudio](../speicherformate.md#financestudio).

**Sicherheit.** Alles, was Beträge oder Buchungen zeigt, liest **private Daten** (B) und ist über MCP gesperrt. Empfänger und Verwendungszweck schreiben Banken und Händler; was sie zeigt, liest zugleich **Fremdes** (A). Ein Lauf, der Buchungen gelesen hat, fragt deshalb vor allem, was nach außen wirkt oder zerstört, und außerhalb der Oberfläche fragen `finance.transaction.list`, `finance.groups.list`, `finance.recurring.list` und `finance.import.csv` jedes Mal (A und B zugleich, wie `chat.document.read`). `finance.overview` und `finance.plan.read` zeigen nur Zahlen und eigene Einträge (B). Kategorien, Planung und Buchungen von Hand anlegen ist eine lokale Änderung ohne Lesen.

Beträge gehen als Zahl in Euro hinein (`--amount -54.20`), Ausgaben negativ; in der Planung sind sie positiv. Tage nehmen `2026-11-20`, `20.11.2026`, `heute`, `gestern`. Zeiträume: `--period tag|woche|monat|jahr|alles` um `--date` (Vorgabe heute) oder `--from`/`--to`.

| Action | Was sie tut | Art | Sicherheit |
|---|---|---|---|
| `finance.overview` | Kontostand, Einnahmen, Ausgaben und Umbuchungen eines Zeitraums und was der Plan im Monat frei lässt | read | `financeRead` (B) |
| `finance.account.update` | Ändert Name, Bank, Inhaber, IBAN oder Währung des Kontos | write | `.localWrite` |
| `finance.balance.set` | Gleicht den Kontostand ab: so viel stand am Ende des Tages auf dem Konto | write | `.localWrite` |
| `finance.transaction.list` | Buchungen nach Zeitraum, Richtung, Kategorie, Gruppe oder Suche, neueste zuerst, mit Summen | read | `financeForeignRead` (A, B) |
| `finance.transaction.add` | Trägt eine Buchung von Hand ein | write | `.localWrite` |
| `finance.transaction.update` | Ändert eine Buchung; `category ""` nimmt die eigene Kategorie weg | write | `.localWrite` |
| `finance.transaction.delete` | Löscht Buchungen (rückgängig machbar, solange die App läuft) | destructive | `.destructive` |
| `finance.import.csv` | Liest den CSV-Export der Bank (`file` oder `text`), übernimmt nur neue Buchungen und den Saldo der Datei | write | A, B, lokal; eine Datei, die Chat oder MCP nennen, fragt immer |
| `finance.groups.list` | Gruppen ähnlicher Posten mit Anzahl, Summe, Kategorie und Rhythmus | read | `financeForeignRead` (A, B) |
| `finance.recurring.list` | Wiederkehrende Zahlungen und Eingänge mit Rhythmus, üblichem Betrag, nächstem Termin, ob sie in der Planung stehen | read | `financeForeignRead` (A, B) |
| `finance.category.list` | Kategorien mit Art (`ausgabe`, `einnahme`, `umbuchung`) und Stichworten | read | `.plainRead` |
| `finance.category.create` | Legt eine Kategorie mit Stichworten an | write | `.localWrite` |
| `finance.category.update` | Ändert Name, Art, Stichworte (ersetzen, hinzufügen, entfernen), Symbol, Farbe | write | `.localWrite` |
| `finance.category.delete` | Löscht eine Kategorie; Buchungen und Zuordnungen verlieren sie | destructive | `.destructive` |
| `finance.category.assign` | Kategorie für eine Gruppe (alle ihre Buchungen, auch künftige) oder eine Buchung; ohne `category` gelöst | write | `.localWrite` |
| `finance.ai.categorize` | Das lokale Modell ordnet Gruppen ohne Kategorie ein; es darf nur bestehende Kategorien nennen | write | A, B, lokal |
| `finance.statement.export` | Kontoauszug als PDF: Anfangssaldo, Buchungen mit Saldo, Endsaldo | destructive | `.outbound`, im Exportordner wie die anderen Exporte |
| `finance.plan.read` | Planung: Einkommen, Fixkosten, Projekte mit „machbar ab“, Sparziele mit „erreicht am“, was im Monat frei bleibt | read | `financeRead` (B) |
| `finance.plan.configure` | Ob der Durchschnitt der übrigen Ausgaben vom freien Betrag abgeht | write | `.localWrite` |
| `finance.income.add` | Regelmäßiges Einkommen | write | `.localWrite` |
| `finance.fixedCost.add` | Fixkosten; mit `group` aus den erkannten Buchungen übernommen | write | `.localWrite` |
| `finance.project.add` | Ausgabeprojekt (z. B. Mac mini M5 Pro, 3500 €) mit Priorität und Zieldatum | write | `.localWrite` |
| `finance.goal.add` | Sparziel mit Zielbetrag, Monatsrate und Zieldatum | write | `.localWrite` |
| `finance.plan.update` | Ändert einen Eintrag der Planung; Felder, die nicht zur Art passen, sind ein Fehler | write | `.localWrite` |
| `finance.plan.remove` | Nimmt einen Eintrag aus der Planung | destructive | `.destructive` |
| `finance.goal.deposit` | Legt Geld in ein Sparziel oder Projekt (negativ: heraus) | write | `.localWrite` |
| `finance.studio.open` | Öffnet FinanceStudio bei Konto oder Planung, einem Zeitraum, einer Kategorie oder Gruppe | read | `.plainRead` |
| `finance.studio.close` | Schließt FinanceStudio | read | `.plainRead` |

Chat-Werkzeuggruppe `finance.core`: `finance.overview`, `finance.transaction.list`, `finance.transaction.add`, `finance.groups.list`, `finance.plan.read`, `finance.goal.add`, `finance.goal.deposit`, `finance.project.add`, `finance.studio.open`.

```bash
llmd finance import csv --file ~/Downloads/Umsaetze.csv
llmd finance overview --period monat
llmd finance transaction list --period woche --direction ausgaben
llmd finance groups list --period jahr --direction ausgaben --limit 15
llmd finance category assign --group rewe --category lebensmittel
llmd finance fixed-cost add --group netflix
llmd finance project add --name "Mac mini M5 Pro" --amount 3500 --priority hoch
llmd finance goal add --name Notgroschen --target 6000 --monthly 250
llmd finance statement export --from 2026-10-01 --to 2026-10-31
```
