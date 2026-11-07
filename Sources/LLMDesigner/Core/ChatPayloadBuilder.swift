import Foundation

/// What a chat sends to the model, put together so that the beginning stays the same from turn to turn.
///
/// Kapitsa and LM Studio keep the start of a prompt in a prefix cache and only read what is new. One changed character
/// in the system prompt makes them read the whole chat again – measured with Kapitsa on 2026-11-07: nothing at all
/// came from the cache then, and a chat of 2 200 tokens waited 11 s instead of 0.3 s. So the system prompt holds only
/// what stays for the whole chat, and what belongs to one turn (the moments the memory recalls, the hint for a spoken
/// answer) goes with the newest message. A second system message further down is no way out: the chat templates of
/// Qwen and Gemma expect system text at the start only.
enum ChatPayloadBuilder {
    /// System prompt and history. `hints` are the tool descriptions, which stay as long as the chat's tools do.
    /// `thinkToken`: Gemma 4 in LM Studio thinks only with its token at the very start of the system prompt.
    static func messages(system: String, hints: [String], thinkToken: Bool, history: [ChatPayloadMessage]) -> [ChatPayloadMessage] {
        var text = ([system] + hints).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if thinkToken { text = "<|think|>" + text }
        return (text.isEmpty ? [] : [ChatPayloadMessage(role: "system", content: text)]) + history
    }

    /// The messages with this turn's notes in front of the newest question, in a frame that says they come from the
    /// app. Nothing of it is stored; the next turn sends that question without them, which only touches the end.
    static func adding(notes: [String], toNewestOf messages: [ChatPayloadMessage]) -> [ChatPayloadMessage] {
        let notes = notes.filter { !$0.isEmpty }
        guard !notes.isEmpty else { return messages }
        var messages = messages
        guard let index = messages.lastIndex(where: { $0.role == "user" }) else {
            // Nothing to put them in front of (no question yet): the system prompt is the only place left.
            let text = notes.joined(separator: "\n\n")
            if let first = messages.first, first.role == "system" {
                messages[0].content = first.content + "\n\n" + text
            } else {
                messages.insert(ChatPayloadMessage(role: "system", content: text), at: 0)
            }
            return messages
        }
        messages[index].content = frame(notes) + messages[index].content
        return messages
    }

    static let noteStart = "(Hinweis der App für diese Antwort, nicht von deinem Gegenüber geschrieben:)"
    static let noteEnd = "(Ende des Hinweises. Die Nachricht deines Gegenübers:)"

    private static func frame(_ notes: [String]) -> String {
        noteStart + "\n" + notes.joined(separator: "\n\n") + "\n" + noteEnd + "\n\n"
    }
}
