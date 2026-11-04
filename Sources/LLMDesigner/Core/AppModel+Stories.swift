import Foundation

/// Stories Studio takes the main area like Citation Studio; choosing a chat or a document closes it again.
extension AppModel {
    func openStoriesStudio() {
        closeDocument()
        showChats()
        stories.loadIfNeeded()
        storiesStudioOpen = true
    }

    func closeStoriesStudio() {
        stories.saveAll()
        storiesStudioOpen = false
    }

    /// The document of a part's manuscript, made when there is none or it was deleted. A new one starts with the part's
    /// title; deleting a part leaves its document alone, because the text must not go with the plan.
    func manuscript(ofPart partID: UUID, inWorld worldID: UUID, provenance: DocumentProvenance? = nil) -> (document: WriterDocument, isNew: Bool)? {
        guard let world = stories.world(worldID), let part = world.part(partID) else { return nil }
        if let id = part.manuscriptID, let document = document(id) { return (document, false) }
        let title = world.displayTitle(of: part)
        let document = createDocumentForAction(title: world.displayTitle + " – " + title, folderID: nil, markdown: "# " + WriterMarkdown.escape(title, atLineStart: false) + "\n", provenance: provenance)
        stories.update(worldID) { $0.updatePart(partID) { $0.manuscriptID = document.id } }
        return (document, true)
    }
}
