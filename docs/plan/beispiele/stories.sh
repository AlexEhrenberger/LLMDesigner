#!/bin/bash
# Eine Romanwelt: Gliederung, Figur, Überblick mit wenig Kontext.
set -euo pipefail
llmd stories world create --title "Eisland"
llmd stories world update --world Eisland --genre Fantasy --logline "Eine Reise durch das Eis"
llmd stories part add --world Eisland --level book --title "Buch 1"
llmd stories part add --world Eisland --level act --parent "Buch 1" --title "Akt 1"
llmd stories element create --world Eisland --kind figure --name Mara --fields '{"biography":"Kartografin aus dem Süden","role":"protagonist"}'
llmd stories part focus set --world Eisland --part "Buch 1/Akt 1" --aspect warum --text "Weil die Karte falsch ist"
llmd stories world read --world Eisland --depth overview --json
