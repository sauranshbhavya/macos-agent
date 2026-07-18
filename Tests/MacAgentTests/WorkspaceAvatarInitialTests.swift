import Testing
@testable import MacAgent

struct WorkspaceAvatarInitialTests {
    @Test
    func usesTheFirstCharacterUppercased() {
        #expect(WorkspaceAvatarInitial.from(name: "personal") == "P")
        #expect(WorkspaceAvatarInitial.from(name: "Build in Public") == "B")
    }

    @Test
    func skipsLeadingWhitespaceBeforeTakingTheFirstCharacter() {
        #expect(WorkspaceAvatarInitial.from(name: "  client work") == "C")
    }

    @Test
    func fallsBackToAQuestionMarkForAnEmptyOrWhitespaceOnlyName() {
        #expect(WorkspaceAvatarInitial.from(name: "") == "?")
        #expect(WorkspaceAvatarInitial.from(name: "   ") == "?")
    }
}
