import AppKit
@testable import LLMDesigner

/// A real `AppModel` for tests. There is one throwaway library per test run, because the stores read the global
/// `AppLibrary.current` at any time and tests run in parallel. Tests look for what they made, not at whole lists.
@MainActor
enum TestApp {
    private static let library: AppLibrary = {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LLMDesignerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = try! AppLibrary.create(at: folder.appendingPathComponent("Test.llmdlibrary"))
        AppLibrary.current = library
        return library
    }()

    static func model() -> AppModel {
        _ = library
        return shared
    }

    /// One model per run: it loads and starts background work once, as in the app.
    private static let shared = AppModel()
}
