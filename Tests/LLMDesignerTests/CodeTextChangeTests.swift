import Testing
@testable import LLMDesigner

/// A streaming code block only appends what the model wrote on (see `ChatCodeView`).
@Suite struct CodeTextChangeTests {
    @Test func growingCodeIsAppended() {
        #expect(CodeTextChange.between("let a = 1\n", "let a = 1\nlet b = 2") == .append("let b = 2"))
    }

    @Test func unchangedCodeDoesNothing() {
        #expect(CodeTextChange.between("print(1)", "print(1)") == CodeTextChange.none)
    }

    @Test func otherCodeReplaces() {
        #expect(CodeTextChange.between("print(1)", "print(2)") == .replace("print(2)"))
        #expect(CodeTextChange.between("print(1)\nprint(2)", "print(1)") == .replace("print(1)"))
        #expect(CodeTextChange.between("", "x") == .replace("x"))
    }

    @Test func appendsBeyondAsciiWithoutBreakingCharacters() {
        #expect(CodeTextChange.between("// Grüße", "// Grüße 🙂 äö") == .append(" 🙂 äö"))
    }
}
