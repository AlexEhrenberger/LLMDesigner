import Foundation

/// Two versions of one thing to put side by side: from the history, the working tree, or two documents.
struct CompareRequest: Identifiable, Equatable {
    enum Side: Equatable, Hashable {
        /// The item as it was at a commit (hash, branch or tag).
        case commit(String)
        /// The file as it is on disk now.
        case workingTree
        /// Another document of the library (a "Fassung"), as the app holds it.
        case document(UUID)
        /// The item as the app holds it in memory (unsaved edits), for a change from outside.
        case memory
    }

    let id = UUID()
    /// The item compared; for two documents the left one.
    var item: LibraryItem?
    var left: Side
    var right: Side
    /// What the person may take over into the right side ("übernehmen"): only when the right side is the working
    /// version of an item or a document.
    var allowsTakingOver = true

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension AppModel {
    func compare(_ request: CompareRequest) {
        compareRequest = request
    }
}
