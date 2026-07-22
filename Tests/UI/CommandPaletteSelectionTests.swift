import Foundation
@testable import GhosthubUI
import Testing

struct CommandPaletteSelectionTests {
    @Test("down arrow from nil selects first item")
    func downArrowFromNilSelectsFirst() {
        var index: Int? = nil
        index = CommandPaletteSelection.moved(
            from: index, direction: .down, count: 5
        )
        #expect(index == 0)
    }

    @Test("down arrow wraps to first item")
    func downArrowWraps() {
        var index: Int? = 4
        index = CommandPaletteSelection.moved(
            from: index, direction: .down, count: 5
        )
        #expect(index == 0)
    }

    @Test("up arrow from nil selects last item")
    func upArrowFromNilSelectsLast() {
        var index: Int? = nil
        index = CommandPaletteSelection.moved(
            from: index, direction: .up, count: 5
        )
        #expect(index == 4)
    }

    @Test("up arrow wraps to last item")
    func upArrowWraps() {
        var index: Int? = 0
        index = CommandPaletteSelection.moved(
            from: index, direction: .up, count: 5
        )
        #expect(index == 4)
    }

    @Test("movement returns nil for empty list")
    func movementReturnsNilForEmptyList() {
        let index = CommandPaletteSelection.moved(
            from: nil, direction: .down, count: 0
        )
        #expect(index == nil)
    }

    @Test("resolved index returns selected or falls back to first")
    func resolvedIndexReturnsSelectedOrFirst() {
        #expect(
            CommandPaletteSelection.resolved(
                selectedIndex: 3, count: 5
            ) == 3
        )
        #expect(
            CommandPaletteSelection.resolved(
                selectedIndex: nil, count: 5
            ) == 0
        )
        #expect(
            CommandPaletteSelection.resolved(
                selectedIndex: nil, count: 0
            ) == nil
        )
        #expect(
            CommandPaletteSelection.resolved(
                selectedIndex: 10, count: 5
            ) == 0
        )
    }
}
