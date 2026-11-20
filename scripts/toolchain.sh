# Sourced by build-app.sh and test.sh: picks an SDK the installed toolchain can actually compile against.
#
# From the macOS 27 SDK on, SwiftUI's @State is a macro whose implementation (the SwiftUIMacros plugin) ships
# only with Xcode, not with the Command Line Tools. With only the Command Line Tools, the build therefore goes
# against the newest SDK they bring along whose @State is still a property wrapper. The app targets macOS 15,
# so it loses nothing. An SDKROOT set by the caller always wins.

DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

# The macro declaration in the SDK, not the SDK version, decides: a later Command Line Tools release may ship
# the plugin, and then the default SDK works again.
sdk_declares_state_macro() {
    grep -q '"StateMacro"' \
        "$1/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface" \
        2>/dev/null
}

if [ -z "${SDKROOT:-}" ] && [ "${DEVELOPER_PATH##*/}" = "CommandLineTools" ] \
    && [ ! -e "$DEVELOPER_PATH/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    if sdk_declares_state_macro "$DEFAULT_SDK"; then
        for sdk in $(ls -d "$DEVELOPER_PATH"/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -V -r); do
            [ -L "$sdk" ] && continue  # MacOSX27.sdk etc. only point to the full versions
            if ! sdk_declares_state_macro "$sdk"; then
                export SDKROOT="$sdk"
                break
            fi
        done
        if [ -z "${SDKROOT:-}" ]; then
            echo "Fehler: $(basename "$DEFAULT_SDK") braucht das SwiftUI-Macro-Plugin, das nur Xcode mitbringt, und die Command Line Tools enthalten kein älteres SDK. Xcode installieren oder SDKROOT setzen." >&2
            exit 1
        fi
        echo "Hinweis: Baue gegen $(basename "$SDKROOT"), weil $(basename "$(readlink -f "$DEFAULT_SDK")") ohne Xcode nicht übersetzt (@State ist dort ein Macro)." >&2
    fi
fi

# The Command Line Tools ship the Swift Testing macros (@Test, #expect) in a folder the compiler doesn't search
# by itself. Passed as an array so callers can splice it into the swift command line.
TESTING_PLUGIN_FLAGS=()
if [ -d "$DEVELOPER_PATH/usr/lib/swift/host/plugins/testing" ]; then
    TESTING_PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$DEVELOPER_PATH/usr/lib/swift/host/plugins/testing")
fi
