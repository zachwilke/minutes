import AppKit
import Testing
@testable import Minutes

/// The notes as one selectable text: what a plain copy reads like, what is
/// styled, and that a selection across sections copies.
@MainActor
struct NotesTextTests {
    private let notes = """
    ## Decisions
    - Push the **VPN** config next week
    - Use a team site, see [the docs](https://example.com)

    Marcus owns the rollout.

    | Item | Owner |
    |---|---|
    | VPN push | Marcus |
    """

    @Test func plainTextReadsLikeTheNotes() {
        let text = MarkdownText.attributed(notes).string
        #expect(text.hasPrefix("Decisions\n•\tPush the VPN config next week\n•\tUse a team site, see the docs\nMarcus owns the rollout.\n"))
        #expect(text.contains("Item\nOwner\nVPN push\nMarcus"))
        #expect(!text.hasSuffix("\n"))
    }

    @Test func boldLinksAndHeadingsAreStyled() throws {
        let rich = MarkdownText.attributed(notes)
        let ns = rich.string as NSString
        let bold = try #require(rich.attribute(.font, at: ns.range(of: "VPN").location, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let heading = try #require(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(heading.pointSize == 17)
        #expect(rich.attribute(.link, at: ns.range(of: "the docs").location, effectiveRange: nil) != nil)
    }

    @Test func aSelectionAcrossSectionsCopiesAsRichAndPlainText() throws {
        let view = NotesTextView()
        view.textStorage?.setAttributedString(MarkdownText.attributed(notes))
        let text = view.string as NSString
        let start = text.range(of: "Decisions").location
        let end = NSMaxRange(text.range(of: "rollout."))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        let board = NSPasteboard.withUniqueName()
        // The view's own types, which is what ⌘C asks for.
        #expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        let copied = try #require(board.string(forType: .string))
        #expect(copied.contains("Decisions") && copied.contains("Push the VPN config") && copied.contains("rollout."))
        #expect(board.data(forType: .rtf) != nil)
        board.releaseGlobally()
    }
}
