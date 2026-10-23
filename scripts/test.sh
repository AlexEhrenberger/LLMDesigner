#!/bin/bash
# Runs the unit tests. The Command Line Tools ship Swift Testing outside the default search path, so it is added here.
# Usage: scripts/test.sh [swift test arguments, e.g. --filter WriterStyleTests]
set -euo pipefail
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
    "$@"
