#!/bin/bash
# Builds LLM Designer and wraps the binary into build/LLM Designer.app
# Usage: scripts/build-app.sh [release|debug] [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/LLM Designer.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [ ! -f Resources/AppIcon.icns ]; then
    echo "Erzeuge App-Icon…"
    WORK="$(mktemp -d)"
    swift scripts/make-icon.swift "$WORK/icon.png"
    mkdir -p "$WORK/AppIcon.iconset"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
    rm -rf "$WORK"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LLMDesigner" "$APP/Contents/MacOS/LLMDesigner"
# The terminal tool lives inside the app; Settings can link it to ~/.local/bin.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/llmd" "$APP/Contents/Helpers/llmd"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# mermaid.js draws the diagrams of the content analysis (offline, in a hidden web view).
cp Resources/Mermaid/mermaid.min.js Resources/Mermaid/LICENSE "$APP/Contents/Resources/"
mv "$APP/Contents/Resources/LICENSE" "$APP/Contents/Resources/mermaid-LICENSE.txt"
# Presenter Studio's slide backgrounds (CSS), see Resources/SlideDesigns/LIESMICH.md.
cp -R Resources/SlideDesigns "$APP/Contents/Resources/SlideDesigns"
# SwiftPM resource bundles (math fonts) go into Contents/Resources; see Vendor/SwiftMath/README.md.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
codesign --force --sign - "$APP/Contents/Helpers/llmd" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "Fertig: $APP"
if [ "${2:-}" = "--open" ]; then
    # A running instance would only be brought to the front, so quit it to launch the fresh build.
    if pgrep -x LLMDesigner >/dev/null; then
        osascript -e 'quit app id "app.llmdesigner.LLMDesigner"' >/dev/null 2>&1 || pkill -x LLMDesigner || true
        for _ in {1..20}; do pgrep -x LLMDesigner >/dev/null || break; sleep 0.25; done
    fi
    open "$APP"
fi
