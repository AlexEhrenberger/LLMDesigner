#!/bin/bash
# Das lokale Modell befragen.
set -euo pipefail
llmd models list
CHAT=$(llmd chat create --title "Beispiel Chat" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
llmd chat ask --chat "$CHAT" --text "Nenne drei Teile des Wasserkreislaufs."
llmd chat read --chat "$CHAT"
