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
}
