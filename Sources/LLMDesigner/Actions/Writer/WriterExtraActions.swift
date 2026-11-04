import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerWriterExtraActions() {
        registerWriterTableActions()
        registerWriterBoxActions()
        registerWriterFigureActions()
        registerWriterMathActions()
        registerWriterCodeActions()
        registerWriterAIActions()
        registerWriterAnalysisActions()
        registerWriterViewActions()
        registerWriterPassageActions()
        registerWriterStructureActions()
        registerWriterPageActions()
    }
}

/// A short sign on the screen that something other than the person changed the open document.
struct ActionFlash: Equatable {
    let id = UUID()
    let document: WriterDocument.ID
    let channel: ActionChannel
}

extension AppModel {
    /// How long the sign stays.
    static let actionFlashSeconds = 1.6

    func highlightActionChange(in id: WriterDocument.ID, channel: ActionChannel) {
        guard channel != .ui, selectedDocumentID == id else { return }
        let flash = ActionFlash(document: id, channel: channel)
        actionFlash = flash
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.actionFlashSeconds))
            if self?.actionFlash == flash { self?.actionFlash = nil }
        }
    }
}
