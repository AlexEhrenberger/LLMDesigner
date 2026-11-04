#!/bin/bash
# Quelle anlegen, Baustein festhalten, im Dokument belegen.
set -euo pipefail
llmd citation source create --title "Beispielbuch" --authors '["Müller, Anna"]' --year 2020 --citekey mueller2020 --type book --publisher "Verlag"
llmd citation quote add --source mueller2020 --exact-text "Ein kurzer Satz." --page 12
llmd citation search "@mueller 2020"
DOC=$(llmd writer doc create --title "Beispiel Citation" --markdown "Das stimmt." --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
llmd writer citation insert --doc "$DOC" --match "stimmt" --key mueller2020 --page 12
llmd writer bibliography insert --doc "$DOC"
llmd writer doc read --doc "$DOC"
