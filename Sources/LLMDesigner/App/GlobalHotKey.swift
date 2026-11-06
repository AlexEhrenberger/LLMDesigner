import AppKit
import Carbon.HIToolbox

/// One shortcut that works in every app, for the search bar. Carbon's hot keys need no accessibility permission and
/// take the combination away from other apps only while it is registered.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (() -> Void)?
    /// Only the running app registers; tests make models too, and must not take keys from the person.
    private(set) var isStarted = false
    /// What was asked for last, to come back to it after recording a new one.
    private var wanted: QuickBarShortcut?

    func start(onPress: @escaping () -> Void) {
        guard !isStarted else { return }
        self.onPress = onPress
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A closure without captures, as C wants: it hops to the main actor, where the shortcut lives.
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() } }
            return noErr
        }, 1, &type, nil, &handler)
        isStarted = true
    }

    /// Registers `shortcut` instead of the previous one (nil: none). False if another app holds the combination.
    @discardableResult
    func register(_ shortcut: QuickBarShortcut?) -> Bool {
        wanted = shortcut
        return apply(shortcut)
    }

    /// While a new shortcut is being recorded, the old one must not open the bar.
    func suspend() { _ = apply(nil) }
    func resume() { _ = apply(wanted) }

    private func apply(_ shortcut: QuickBarShortcut?) -> Bool {
        guard isStarted else { return true }
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        guard let shortcut, shortcut.isUsable else { return true }
        let id = EventHotKeyID(signature: OSType(0x4C4C_4D44), id: 1) // "LLMD"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonFlags(shortcut.modifierFlags), id, GetEventDispatcherTarget(), 0, &ref)
        return status == noErr
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return UInt32(carbon)
    }
}
