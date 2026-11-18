import AppKit
import Testing
@testable import GhosthubTerminalSupport

@MainActor
@Suite("Terminal split container")
struct TerminalSplitContainerViewTests {
    private final class RecordingContent: TerminalSplitPaneContent {
        let view = NSView()
        var deferrals: [Bool] = []
        func setResizeDeferred(_ deferred: Bool) {
            deferrals.append(deferred)
        }
    }

    /// A | (B over C), as Rex reported it.
    private func tree(
        rootRatio: Double = 0.5,
        focused: String = "C",
        zoomed: String? = nil
    ) -> TerminalSplitTree {
        TerminalSplitTree(
            root: .split(
                id: "split:root", axis: .horizontal, ratio: rootRatio,
                first: .pane("A"),
                second: .split(
                    id: "split:right", axis: .vertical, ratio: 0.6,
                    first: .pane("B"), second: .pane("C")
                )
            ),
            focusedPaneID: focused,
            zoomedPaneID: zoomed
        )
    }

    private func panes(_ contents: [String: RecordingContent])
        -> [TerminalSplitContainerView.Pane] {
        contents.keys.sorted().map { id in
            .init(id: id, title: "pane \(id)", content: contents[id])
        }
    }

    private func container() -> TerminalSplitContainerView {
        let view = TerminalSplitContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        view.metrics = TerminalSplitMetrics(gap: 8, minimumPaneSize: CGSize(width: 80, height: 60))
        return view
    }

    @Test("a pane that stays keeps its card and content view; a gone pane leaves")
    func identity() throws {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(
            tree: TerminalSplitTree(root: .split(
                id: "split:root", axis: .horizontal, ratio: 0.5,
                first: .pane("A"), second: .pane("B")
            )),
            panes: panes(contents.filter { $0.key != "C" })
        )
        let a = try #require(view.paneViews["A"])
        view.apply(tree: tree(), panes: panes(contents))
        #expect(view.paneViews["A"] === a)
        #expect(contents["A"]?.view.superview === a)
        #expect(view.paneViews["C"] != nil)

        let c = try #require(view.paneViews["C"])
        view.apply(
            tree: TerminalSplitTree(root: .pane("A")),
            panes: panes(contents.filter { $0.key == "A" })
        )
        #expect(view.paneViews["A"] === a)
        #expect(view.paneViews["C"] == nil)
        #expect(c.superview == nil)
    }

    @Test("cards take the layout's frames and content sits below the header")
    func frames() throws {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: tree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        let expected = TerminalSplitLayout.layout(
            tree(), in: view.bounds, metrics: view.metrics, scale: 2
        )
        for (id, frame) in expected.panes {
            #expect(view.paneViews[id]?.frame == frame)
        }
        let b = try #require(expected.panes["B"])
        let header = TerminalSplitPaneView.headerHeight
        #expect(contents["B"]?.view.frame == CGRect(
            x: 0, y: header, width: b.width, height: b.height - header
        ))
    }

    @Test("a divider drag holds terminal resizing until mouse-up, then reports once")
    func drag() throws {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: tree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        var commits: [(String, Double)] = []
        view.onResizeCommitted = { divider, ratio in commits.append((divider.splitID, ratio)) }

        #expect(view.beginDrag(at: CGPoint(x: 500, y: 300)))
        #expect(contents.values.allSatisfy { $0.deferrals == [true] })
        for x in stride(from: 490, through: 310, by: -20) {
            view.moveDrag(to: CGPoint(x: x, y: 300))
        }
        #expect(contents.values.allSatisfy { $0.deferrals == [true] })
        #expect(view.paneViews["A"]?.frame.width ?? 0 < 400)
        #expect(commits.isEmpty)
        view.endDrag()

        #expect(contents.values.allSatisfy { $0.deferrals == [true, false] })
        #expect(commits.count == 1)
        let (splitID, ratio) = try #require(commits.first)
        #expect(splitID == "split:root")
        #expect(abs(ratio - (310.0 - 4) / 992) < 1e-9)
    }

    @Test("a reported ratio stays until the backend reports a different one")
    func committedRatio() throws {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: tree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        #expect(view.beginDrag(at: CGPoint(x: 500, y: 300)))
        view.moveDrag(to: CGPoint(x: 302, y: 300))
        view.endDrag()
        let dragged = try #require(view.paneViews["A"]?.frame.width)

        // A view that arrives before the backend applies the resize.
        view.apply(tree: tree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        #expect(view.paneViews["A"]?.frame.width == dragged)

        view.apply(tree: tree(rootRatio: 0.4), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        #expect(view.paneViews["A"]?.frame.width == 396.5)
    }

    @Test("a click away from every divider is not a drag")
    func missedDivider() {
        let view = container()
        view.apply(tree: tree(), panes: panes(["A": RecordingContent()]))
        view.layoutSubtreeIfNeeded()
        #expect(!view.beginDrag(at: CGPoint(x: 200, y: 300)))
    }

    @Test("a zoomed pane covers the container and the others keep running hidden")
    func zoomed() {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: tree(zoomed: "B"), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        #expect(view.paneViews["B"]?.frame == view.bounds)
        #expect(view.paneViews["B"]?.isHidden == false)
        #expect(view.paneViews["A"]?.isHidden == true)
        #expect(view.paneViews["C"]?.isHidden == true)
        #expect(view.dividers.isEmpty)
    }

    @Test("only the focused pane shows its header buttons, and they name their pane")
    func headerButtons() {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: tree(focused: "C"), panes: panes(contents))
        #expect(view.paneViews["C"]?.buttonActions == TerminalSplitHeaderAction.allCases)
        #expect(view.paneViews["A"]?.buttonActions == [])
        view.apply(tree: tree(focused: "A"), panes: panes(contents))
        #expect(view.paneViews["A"]?.buttonActions == TerminalSplitHeaderAction.allCases)
        #expect(view.paneViews["C"]?.buttonActions == [])
    }

    @Test("dividers are accessibility splitters named by the panes beside them")
    func accessibility() {
        let view = container()
        let contents = ["A": RecordingContent(), "B": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: tree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        let splitters = (view.accessibilityChildren() ?? [])
            .compactMap { $0 as? NSAccessibilityElement }
            .filter { $0.accessibilityRole() == .splitter }
        #expect(splitters.map { $0.accessibilityLabel() } == [
            "Divider between pane A and pane B",
            "Divider between pane B and pane C",
        ])
    }
}
