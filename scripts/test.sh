#!/bin/bash
# Runs the unit tests. The Command Line Tools ship Swift Testing outside the default search path, so it is added here.
# Usage: scripts/test.sh [swift test arguments, e.g. --filter WriterStyleTests]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
# The odd expansion keeps /bin/bash 3.2 from calling an empty array unbound under `set -u`.
swift test \
    ${TESTING_PLUGIN_FLAGS[@]+"${TESTING_PLUGIN_FLAGS[@]}"} \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
    "$@"
