#!/bin/bash
# Ein Dokument von Grund auf: anlegen, schreiben, formatieren, als PDF exportieren.
set -euo pipefail
DOC=$(llmd writer doc create --title "Beispiel Writer" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
llmd writer text insert-markdown --doc "$DOC" --markdown "# Der Wasserkreislauf

Wasser verdunstet, steigt auf und fällt als Regen.

- Verdunstung
- Niederschlag"
llmd writer format bold --doc "$DOC" --match "Verdunstung" --state on
llmd writer export --doc "$DOC" --format pdf
