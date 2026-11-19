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

    @Test("an outside hold, such as the sidebar animating, holds every pane's resizing")
    func outsideHold() {
        let view = container()
        let a = RecordingContent()
        view.apply(tree: tree(), panes: panes(["A": a]))
        view.defersContentResize = true
        #expect(a.deferrals == [true])

        // A pane that attaches during the hold waits too.
        let b = RecordingContent()
        view.apply(tree: tree(), panes: panes(["A": a, "B": b]))
        #expect(b.deferrals == [true])

        // A drag that ends during the hold does not release it.
        view.layoutSubtreeIfNeeded()
        #expect(view.beginDrag(at: CGPoint(x: 500, y: 300)))
        view.endDrag()
        #expect(a.deferrals == [true])

        view.defersContentResize = false
        #expect(a.deferrals == [true, false])
        #expect(b.deferrals == [true, false])
    }

    /// A | B tiled, with a floating C in the middle, and a minimized D.
    private func floatingTree(
        bounds: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        tiled: Bool = true
    ) -> TerminalSplitTree {
        TerminalSplitTree(
            root: tiled ? .split(
                id: "tiled", axis: .horizontal, ratio: 0.5,
                first: .pane("A"), second: .pane("B")
            ) : nil,
            floatingLayers: [
                .init(id: "layer:c", bounds: bounds, root: .pane("C")),
                .init(
                    id: "layer:d", bounds: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                    root: .pane("D"), isMinimized: true
                ),
            ],
            focusedPaneID: "C"
        )
    }

    private func floatingContainer() -> (TerminalSplitContainerView, [String: RecordingContent]) {
        let view = container()
        let contents = [
            "A": RecordingContent(), "B": RecordingContent(),
            "C": RecordingContent(), "D": RecordingContent(),
        ]
        view.apply(tree: floatingTree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        return (view, contents)
    }

    @Test("a floating window draws over the tiled panes, and a minimized one shows a capsule")
    func floatingOrder() throws {
        let (view, _) = floatingContainer()
        let a = try #require(view.paneViews["A"])
        let c = try #require(view.paneViews["C"])
        let capsule = try #require(view.capsules["layer:d"])
        let order = view.subviews
        let indexA = try #require(order.firstIndex { $0 === a })
        let indexC = try #require(order.firstIndex { $0 === c })
        #expect(indexA < indexC)
        #expect(order.last === capsule)
        #expect(c.frame == CGRect(x: 250, y: 150, width: 500, height: 300))
        #expect(view.paneViews["D"]?.isHidden == true)
        #expect(capsule.title == "pane D")

        var restored: [String] = []
        view.onLayerRestored = { restored.append($0) }
        capsule.performClick(nil)
        #expect(restored == ["layer:d"])
    }

    @Test(
        "dragging a floating window's edge resizes it, no smaller than its panes, then reports once"
    )
    func floatingResize() throws {
        let (view, contents) = floatingContainer()
        var commits: [(String, CGRect)] = []
        view.onLayerBoundsCommitted = { commits.append(($0, $1)) }

        #expect(view.beginDrag(at: CGPoint(x: 750, y: 300)))
        #expect(contents.values.allSatisfy { $0.deferrals == [true] })
        view.moveDrag(to: CGPoint(x: 850, y: 300))
        #expect(view.paneViews["C"]?.frame.width == 600)
        view.moveDrag(to: CGPoint(x: 0, y: 300))
        // No narrower than a pane's minimum width.
        #expect(view.paneViews["C"]?.frame.width == 80)
        view.moveDrag(to: CGPoint(x: 850, y: 300))
        #expect(commits.isEmpty)
        view.endDrag()

        #expect(contents.values.allSatisfy { $0.deferrals == [true, false] })
        let (layerID, bounds) = try #require(commits.first)
        #expect(commits.count == 1)
        #expect(layerID == "layer:c")
        #expect(bounds == CGRect(x: 0.25, y: 0.25, width: 0.6, height: 0.5))

        // The new bounds stay until the backend reports different ones.
        view.apply(tree: floatingTree(), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        #expect(view.paneViews["C"]?.frame.width == 600)
        view.apply(tree: floatingTree(bounds: bounds), panes: panes(contents))
        view.discardCommittedBounds(layerID: "layer:c")
        view.layoutSubtreeIfNeeded()
        #expect(view.paneViews["C"]?.frame.width == 600)
    }

    @Test("dragging a floating pane's header moves its window, kept inside the view")
    func floatingMove() throws {
        let (view, _) = floatingContainer()
        var commits: [(String, CGRect)] = []
        view.onLayerBoundsCommitted = { commits.append(($0, $1)) }

        #expect(view.beginMove(paneID: "C", at: CGPoint(x: 400, y: 160)))
        view.moveDrag(to: CGPoint(x: 0, y: 0))
        #expect(view.paneViews["C"]?.frame.origin == .zero)
        view.moveDrag(to: CGPoint(x: 500, y: 160))
        view.endDrag()

        let (_, bounds) = try #require(commits.first)
        #expect(bounds == CGRect(x: 0.35, y: 0.25, width: 0.5, height: 0.5))
        #expect(!view.beginMove(paneID: "A", at: CGPoint(x: 10, y: 10)))
    }

    @Test("a tiled divider under a floating window cannot be grabbed through it")
    func floatingCoversDivider() {
        let (view, _) = floatingContainer()
        // The tiled divider runs down the middle, under the floating window.
        #expect(!view.beginDrag(at: CGPoint(x: 500, y: 300)))
        #expect(view.beginDrag(at: CGPoint(x: 500, y: 50)))
        view.endDrag()
    }

    @Test("capsules that do not fit in one row wrap upward, all inside the view")
    func capsuleRows() {
        let view = TerminalSplitContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let ids = (1 ... 8).map { "M\($0)" }
        let tree = TerminalSplitTree(
            root: .pane("A"),
            floatingLayers: ids.map { .init(
                id: "layer:\($0)", bounds: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                root: .pane($0), isMinimized: true
            ) },
            focusedPaneID: "A"
        )
        view.apply(tree: tree, panes: (["A"] + ids).map {
            .init(id: $0, title: "a long pane title \($0)", content: nil)
        })
        view.layoutSubtreeIfNeeded()

        let frames = ids.compactMap { view.capsules["layer:\($0)"]?.frame }
        #expect(frames.count == ids.count)
        #expect(frames.allSatisfy { view.bounds.contains($0) })
        #expect(Set(frames.map(\.minY)).count > 1)
        for (index, frame) in frames.enumerated() {
            #expect(frames[(index + 1)...].allSatisfy { !$0.intersects(frame) })
        }
    }

    @Test("capsules that do not fit in the view move to a menu that restores them")
    func capsuleOverflow() throws {
        let view = TerminalSplitContainerView(frame: CGRect(x: 0, y: 0, width: 150, height: 120))
        let ids = (1 ... 8).map { "M\($0)" }
        let tree = TerminalSplitTree(
            root: .pane("A"),
            floatingLayers: ids.map { .init(
                id: "layer:\($0)", bounds: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                root: .pane($0), isMinimized: true
            ) },
            focusedPaneID: "A"
        )
        let panes: [TerminalSplitContainerView.Pane] = (["A"] + ids).map {
            .init(id: $0, title: "a long pane title \($0)", content: nil)
        }
        view.apply(tree: tree, panes: panes)
        view.layoutSubtreeIfNeeded()

        let more = try #require(view.capsuleOverflow)
        let shown = ids.filter { view.capsules["layer:\($0)"]?.isHidden == false }
        #expect(!shown.isEmpty)
        #expect(([more] + shown.compactMap { view.capsules["layer:\($0)"] })
            .allSatisfy { view.bounds.contains($0.frame) })
        #expect(view.subviews.last === more)
        let menu = view.capsuleOverflowMenu()
        #expect(menu.items.map(\.title) == ids.filter { !shown.contains($0) }
            .map { "a long pane title \($0)" })

        var restored: [String] = []
        view.onLayerRestored = { restored.append($0) }
        menu.performActionForItem(at: menu.items.count - 1)
        #expect(restored == ["layer:M8"])

        // Once everything fits again, the menu button goes away.
        view.frame.size = CGSize(width: 1000, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(view.capsuleOverflow == nil)
        #expect(ids.allSatisfy { view.capsules["layer:\($0)"]?.isHidden == false })
    }

    @Test("a floating window with an uneven split shrinks only until its smaller share is minimal")
    func floatingResizeKeepsRatios() {
        let view = container()
        let tree = TerminalSplitTree(
            root: .pane("A"),
            floatingLayers: [.init(
                id: "layer:c", bounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                root: .split(
                    id: "float", axis: .horizontal, ratio: 0.25,
                    first: .pane("C"), second: .pane("E")
                )
            )],
            focusedPaneID: "C"
        )
        view.apply(tree: tree, panes: panes([
            "A": RecordingContent(), "C": RecordingContent(), "E": RecordingContent(),
        ]))
        view.layoutSubtreeIfNeeded()

        #expect(view.beginDrag(at: CGPoint(x: 100, y: 300)))
        view.moveDrag(to: CGPoint(x: 1000, y: 300))
        view.endDrag()
        // C keeps a quarter of the width and still has its 80 points.
        #expect(view.paneViews["C"]?.frame.width == 80)
        #expect(view.paneViews["E"]?.frame.width == 240)
    }

    @Test("a floating window that fills the view can still be resized from its edges")
    func filledFloatingEdges() throws {
        let view = container()
        let contents = ["A": RecordingContent(), "C": RecordingContent()]
        view.apply(tree: TerminalSplitTree(
            root: .pane("A"),
            floatingLayers: [.init(
                id: "layer:c", bounds: CGRect(x: 0, y: 0, width: 1, height: 1), root: .pane("C")
            )],
            focusedPaneID: "C"
        ), panes: panes(contents))
        view.layoutSubtreeIfNeeded()
        let c = try #require(view.paneViews["C"])

        let edge = try #require(view.hitTest(view.convert(CGPoint(x: 997, y: 300), to: nil)))
        #expect(!edge.isDescendant(of: c))
        let middle = try #require(view.hitTest(view.convert(CGPoint(x: 500, y: 300), to: nil)))
        #expect(middle.isDescendant(of: c))

        // A minimized window's capsule over a window's edge keeps its clicks.
        view.apply(tree: TerminalSplitTree(
            root: .pane("A"),
            floatingLayers: [
                .init(
                    id: "layer:c", bounds: CGRect(x: 0, y: 0, width: 0.95, height: 1),
                    root: .pane("C")
                ),
                .init(
                    id: "layer:d", bounds: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                    root: .pane("D"), isMinimized: true
                ),
            ],
            focusedPaneID: "C"
        ), panes: panes(contents.merging(["D": RecordingContent()]) { a, _ in a }))
        view.layoutSubtreeIfNeeded()
        let capsule = try #require(view.capsules["layer:d"])
        #expect(capsule.frame.minX < 950 && capsule.frame.maxX > 950)
        #expect(view.hitTest(view.convert(CGPoint(x: 950, y: capsule.frame.midY), to: nil))
            === capsule)
        #expect(view.hitTest(view.convert(CGPoint(x: 950, y: 300), to: nil))
            .map { !$0.isDescendant(of: c) } == true)
    }

    @Test(
        "a floating pane offers Tile only beside a tiled layout and Minimize only beside another pane"
    )
    func floatingActions() {
        #expect(TerminalSplitContainerView.actions(for: "A", in: floatingTree())
            == TerminalSplitHeaderAction.tiledActions)
        #expect(TerminalSplitContainerView.actions(for: "C", in: floatingTree())
            == TerminalSplitHeaderAction.floatingActions)
        #expect(TerminalSplitContainerView.actions(for: "C", in: floatingTree(tiled: false))
            == [.splitRight, .splitDown, .zoom, .close])
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
        #expect(view.paneViews["C"]?.buttonActions == TerminalSplitHeaderAction.tiledActions)
        #expect(view.paneViews["A"]?.buttonActions == [])
        view.apply(tree: tree(focused: "A"), panes: panes(contents))
        #expect(view.paneViews["A"]?.buttonActions == TerminalSplitHeaderAction.tiledActions)
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
