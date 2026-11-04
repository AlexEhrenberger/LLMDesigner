#!/bin/bash
# Eine kleine Präsentation: Folien in einem Aufruf, Design, Moderatorenkarte, Bild zur Prüfung, PDF.
set -euo pipefail
DECK=$(llmd presenter deck create --title "Beispiel Presenter" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
llmd presenter slide set-text --deck "$DECK" --slide-index 1 --markdown "# Der Wasserkreislauf"
llmd presenter slide add --deck "$DECK" --markdown "# Verdunstung

- Sonne erwärmt das Meer
- Wasser steigt auf" --notes "Hier das Bild zeigen."
llmd presenter design apply --deck "$DECK" --design aurora
llmd writer format bold --deck "$DECK" --slide-index 2 --match "Sonne" --state on
llmd presenter slide render --deck "$DECK" --slide-index 2 --json | python3 -c 'import json,sys,base64; open("/tmp/folie2.png","wb").write(base64.b64decode(json.load(sys.stdin)["imageBase64"]))'
llmd presenter export pdf --deck "$DECK"
