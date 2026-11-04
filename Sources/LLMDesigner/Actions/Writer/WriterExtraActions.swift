import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerWriterExtraActions() {}
}

extension AppModel {
    /// Lets the open editor show what an agent changed (phase 3.6).
    func highlightActionChange(in id: WriterDocument.ID, channel: ActionChannel) {}
}
