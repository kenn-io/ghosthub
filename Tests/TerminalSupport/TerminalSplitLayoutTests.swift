import CoreGraphics
import Foundation
import Testing
@testable import GhosthubTerminalSupport

@Suite("Terminal split layout")
struct TerminalSplitLayoutTests {
    /// The layout Rex reported for a window split right, then down on the
    /// right with 60% above: A | (B over C).
    private let rexProbe = TerminalSplitTree(
        root: .split(
            id: "split:root", axis: .horizontal, ratio: 0.5,
            first: .pane("A"),
            second: .split(
                id: "split:right", axis: .vertical, ratio: 0.6,
                first: .pane("B"), second: .pane("C")
            )
        ),
        focusedPaneID: "C"
    )
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let metrics = TerminalSplitMetrics(
        gap: 8,
        minimumPaneSize: CGSize(width: 80, height: 60)
    )

    @Test("a single pane fills the bounds")
    func singlePane() {
        let layout = TerminalSplitLayout.layout(
            TerminalSplitTree(root: .pane("A")),
            in: bounds, metrics: metrics, scale: 2
        )
        #expect(layout.panes == ["A": bounds])
        #expect(layout.dividers.isEmpty)
    }

    @Test("panes split their parent by ratio, with a gap between them")
    func nestedSplits() {
        let layout = TerminalSplitLayout.layout(
            rexProbe, in: bounds, metrics: metrics, scale: 2
        )
        #expect(layout.panes["A"] == CGRect(x: 0, y: 0, width: 496, height: 600))
        #expect(layout.panes["B"] == CGRect(x: 504, y: 0, width: 496, height: 355))
        #expect(layout.panes["C"] == CGRect(x: 504, y: 363, width: 496, height: 237))
    }

    @Test("frames land on whole device pixels")
    func pixelAligned() throws {
        let tree = TerminalSplitTree(root: .split(
            id: "s", axis: .horizontal, ratio: 1.0 / 3.0,
            first: .pane("A"), second: .pane("B")
        ))
        let layout = TerminalSplitLayout.layout(
            tree, in: CGRect(x: 0, y: 0, width: 1000, height: 300),
            metrics: metrics, scale: 2
        )
        for frame in layout.panes.values {
            for value in [frame.minX, frame.minY, frame.width, frame.height] {
                #expect((value * 2).rounded() == value * 2)
            }
        }
        let a = try #require(layout.panes["A"])
        let b = try #require(layout.panes["B"])
        #expect(a.width + metrics.gap + b.width == 1000)
    }

    @Test("dividers sit in the gaps and name the panes beside them")
    func dividers() throws {
        let layout = TerminalSplitLayout.layout(
            rexProbe, in: bounds, metrics: metrics, scale: 2
        )
        let root = try #require(layout.dividers.first { $0.splitID == "split:root" })
        #expect(root.axis == .horizontal)
        #expect(root.ratio == 0.5)
        #expect(root.firstPaneID == "A")
        #expect(root.secondPaneID == "B")
        #expect(root.hitRect.minX <= 496 && root.hitRect.maxX >= 504)
        #expect(root.hitRect.height == 600)
        let right = try #require(layout.dividers.first { $0.splitID == "split:right" })
        #expect(right.firstPaneID == "B")
        #expect(right.secondPaneID == "C")
        #expect(right.hitRect.minY <= 355 && right.hitRect.maxY >= 363)
        #expect(right.hitRect.minX == 504)
    }

    @Test("a drag's ratio overrides the tree's")
    func ratioOverride() {
        let layout = TerminalSplitLayout.layout(
            rexProbe, in: bounds, metrics: metrics, scale: 2,
            ratioOverrides: ["split:root": 0.3]
        )
        #expect(layout.panes["A"]?.width == 297.5)
        #expect(layout.panes["B"]?.minX == 305.5)
    }

    @Test("a divider cannot shrink a side below its panes' minimum size")
    func ratioRange() throws {
        let layout = TerminalSplitLayout.layout(
            rexProbe, in: bounds, metrics: metrics, scale: 2
        )
        let root = try #require(layout.dividers.first { $0.splitID == "split:root" })
        #expect(abs(root.ratioRange.lowerBound - 80.0 / 992.0) < 1e-9)
        #expect(abs(root.ratioRange.upperBound - (1 - 80.0 / 992.0)) < 1e-9)
        let right = try #require(layout.dividers.first { $0.splitID == "split:right" })
        #expect(abs(right.ratioRange.lowerBound - 60.0 / 592.0) < 1e-9)
        #expect(
            TerminalSplitLayout.ratio(
                at: CGPoint(x: 5, y: 300), along: root, metrics: metrics
            ) == root.ratioRange.lowerBound
        )
        #expect(
            abs(TerminalSplitLayout.ratio(
                at: CGPoint(x: 500, y: 300), along: root, metrics: metrics
            ) - 0.5) < 1e-9
        )
    }

    @Test("a side holding a split in the same direction needs room for both panes")
    func nestedMinimum() throws {
        let tree = TerminalSplitTree(root: .split(
            id: "outer", axis: .horizontal, ratio: 0.5,
            first: .split(
                id: "inner",
                axis: .horizontal,
                ratio: 0.5,
                first: .pane("A"),
                second: .pane("B")
            ),
            second: .pane("C")
        ))
        let layout = TerminalSplitLayout.layout(
            tree, in: bounds, metrics: metrics, scale: 2
        )
        let outer = try #require(layout.dividers.first { $0.splitID == "outer" })
        #expect(abs(outer.ratioRange.lowerBound - 168.0 / 992.0) < 1e-9)
    }

    /// A | B side by side at `inner`, beside C.
    private func unevenTree(inner: Double) -> TerminalSplitTree {
        TerminalSplitTree(root: .split(
            id: "outer", axis: .horizontal, ratio: 0.5,
            first: .split(
                id: "inner",
                axis: .horizontal,
                ratio: inner,
                first: .pane("A"),
                second: .pane("B")
            ),
            second: .pane("C")
        ))
    }

    @Test("an outer divider keeps a nested split's panes usable at the nested ratio")
    func unevenNestedMinimum() throws {
        let tree = unevenTree(inner: 0.25)
        let outer = try #require(
            TerminalSplitLayout.layout(tree, in: bounds, metrics: metrics, scale: 2)
                .dividers.first { $0.splitID == "outer" }
        )
        let squeezed = TerminalSplitLayout.layout(
            tree, in: bounds, metrics: metrics, scale: 2,
            ratioOverrides: ["outer": outer.ratioRange.lowerBound]
        )
        for (id, frame) in squeezed.panes {
            #expect(frame.width >= metrics.minimumPaneSize.width - 0.5, "\(id): \(frame)")
        }
    }

    @Test("a nested ratio that cannot fit still leaves the outer divider movable")
    func unfittableNestedRatio() throws {
        let outer = try #require(
            TerminalSplitLayout.layout(
                unevenTree(inner: 0.05),
                in: bounds,
                metrics: metrics,
                scale: 2
            )
            .dividers.first { $0.splitID == "outer" }
        )
        #expect(abs(outer.ratioRange.lowerBound - 168.0 / 992.0) < 1e-9)
    }

    @Test("a nested ratio set by a drag counts toward the outer minimum")
    func nestedOverrideMinimum() throws {
        let even = TerminalSplitLayout.layout(
            unevenTree(inner: 0.5), in: bounds, metrics: metrics, scale: 2,
            ratioOverrides: ["inner": 0.25]
        )
        let outer = try #require(even.dividers.first { $0.splitID == "outer" })
        #expect(abs(outer.ratioRange.lowerBound - (8 + 80 / 0.25) / 992.0) < 1e-9)
    }

    @Test("a split whose panes' minimums exactly fill it has a valid ratio range")
    func exactlyFullSplit() throws {
        /// 80 + 8 + (4 × 80 + 3 × 8) = 432. In floating point the lower
        /// bound, 80/424, comes out above 1 − 344/424.
        func chain(_ ids: [String]) -> TerminalSplitTree.Node {
            ids.count == 1 ? .pane(ids[0]) : .split(
                id: "split:\(ids[0])", axis: .horizontal, ratio: 0.5,
                first: .pane(ids[0]), second: chain(Array(ids.dropFirst()))
            )
        }
        let tree = TerminalSplitTree(root: .split(
            id: "outer", axis: .horizontal, ratio: 0.5,
            first: .pane("A"), second: chain(["B", "C", "D", "E"])
        ))
        let outer = try #require(
            TerminalSplitLayout.layout(
                tree, in: CGRect(x: 0, y: 0, width: 432, height: 600),
                metrics: metrics, scale: 2
            )
            .dividers.first { $0.splitID == "outer" }
        )
        #expect(abs(outer.ratioRange.lowerBound - 80.0 / 424.0) < 1e-9)
        #expect(outer.ratioRange.lowerBound == outer.ratioRange.upperBound)
    }

    /// A | B tiled, with a floating C over D, and a minimized E.
    private func floatingTree(focused: String = "C", zoomed: String? = nil) -> TerminalSplitTree {
        TerminalSplitTree(
            root: .split(
                id: "tiled", axis: .horizontal, ratio: 0.5,
                first: .pane("A"), second: .pane("B")
            ),
            floatingLayers: [
                .init(
                    id: "layer:1", bounds: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5),
                    root: .split(
                        id: "floating", axis: .vertical, ratio: 0.5,
                        first: .pane("C"), second: .pane("D")
                    )
                ),
                .init(
                    id: "layer:2", bounds: CGRect(x: 0, y: 0, width: 0.3, height: 0.3),
                    root: .pane("E"), isMinimized: true
                ),
            ],
            focusedPaneID: focused,
            zoomedPaneID: zoomed
        )
    }

    @Test("a floating layer sits at its bounds over the tiled panes; a minimized one is not drawn")
    func floatingLayers() {
        let layout = TerminalSplitLayout.layout(
            floatingTree(), in: bounds, metrics: metrics, scale: 2
        )
        #expect(layout.floatingLayers == [
            .init(id: "layer:1", frame: CGRect(x: 250, y: 60, width: 500, height: 300)),
        ])
        #expect(layout.panes["C"] == CGRect(x: 250, y: 60, width: 500, height: 146))
        #expect(layout.panes["D"] == CGRect(x: 250, y: 214, width: 500, height: 146))
        #expect(layout.panes["E"] == nil)
        #expect(layout.dividers.map(\.splitID) == ["tiled", "floating"])
        #expect(layout.dividers.map(\.layerID) == [nil, "layer:1"])
    }

    @Test("a dragged floating layer is drawn at its new bounds")
    func floatingBoundsOverride() {
        let layout = TerminalSplitLayout.layout(
            floatingTree(), in: bounds, metrics: metrics, scale: 2,
            layerBoundsOverrides: ["layer:1": CGRect(x: 0, y: 0, width: 0.4, height: 0.5)]
        )
        #expect(layout.floatingLayers.first?.frame == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test("a zoomed floating pane fills the bounds and hides every layer")
    func zoomedFloatingPane() {
        let layout = TerminalSplitLayout.layout(
            floatingTree(zoomed: "D"), in: bounds, metrics: metrics, scale: 2
        )
        #expect(layout.panes == ["D": bounds])
        #expect(layout.floatingLayers.isEmpty)
    }

    @Test("focus moves reach floating panes and skip minimized ones")
    func floatingFocus() {
        let tree = floatingTree(focused: "B")
        #expect(TerminalSplitLayout.pane(.next, from: tree, in: bounds, metrics: metrics) == "C")
        let last = floatingTree(focused: "D")
        #expect(TerminalSplitLayout.pane(.next, from: last, in: bounds, metrics: metrics) == "A")
        #expect(TerminalSplitLayout.pane(.up, from: last, in: bounds, metrics: metrics) == "C")
    }

    @Test("a window whose panes all float has no tiled layout")
    func onlyFloating() {
        var tree = floatingTree()
        tree.root = nil
        let layout = TerminalSplitLayout.layout(tree, in: bounds, metrics: metrics, scale: 2)
        #expect(Set(layout.panes.keys) == ["C", "D"])
        #expect(tree.paneIDs == ["C", "D", "E"])
        #expect(tree.visiblePaneIDs == ["C", "D"])
    }

    @Test("a zoomed pane fills the bounds and the others get no frame")
    func zoomed() {
        var tree = rexProbe
        tree.zoomedPaneID = "B"
        let layout = TerminalSplitLayout.layout(
            tree, in: bounds, metrics: metrics, scale: 2
        )
        #expect(layout.panes == ["B": bounds])
        #expect(layout.dividers.isEmpty)
    }

    @Test("pane IDs follow layout order")
    func paneOrder() {
        #expect(rexProbe.paneIDs == ["A", "B", "C"])
    }

    @Test("sixteen panes lay out in well under a millisecond")
    func performance() {
        func balanced(_ depth: Int, _ prefix: String) -> TerminalSplitTree.Node {
            guard depth > 0 else { return .pane(prefix) }
            return .split(
                id: "split:\(prefix)",
                axis: depth.isMultiple(of: 2) ? .horizontal : .vertical,
                ratio: 0.5,
                first: balanced(depth - 1, prefix + "a"),
                second: balanced(depth - 1, prefix + "b")
            )
        }
        let tree = TerminalSplitTree(root: balanced(4, "p"))
        #expect(tree.paneIDs.count == 16)
        let start = Date()
        for _ in 0 ..< 1000 {
            _ = TerminalSplitLayout.layout(
                tree, in: CGRect(x: 0, y: 0, width: 2400, height: 1400),
                metrics: metrics, scale: 2
            )
        }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

@Suite("Terminal split focus moves")
struct TerminalSplitFocusMoveTests {
    /// A | (B over C).
    private func tree(focused: String) -> TerminalSplitTree {
        TerminalSplitTree(
            root: .split(
                id: "root", axis: .horizontal, ratio: 0.5,
                first: .pane("A"),
                second: .split(
                    id: "right", axis: .vertical, ratio: 0.6,
                    first: .pane("B"), second: .pane("C")
                )
            ),
            focusedPaneID: focused
        )
    }

    private func move(_ move: TerminalSplitFocusMove, from focused: String) -> String? {
        TerminalSplitLayout.pane(
            move, from: tree(focused: focused),
            in: CGRect(x: 0, y: 0, width: 1000, height: 600),
            metrics: TerminalSplitMetrics()
        )
    }

    @Test("arrows move to the nearest pane on that side")
    func directions() {
        #expect(move(.right, from: "A") == "B")
        #expect(move(.left, from: "C") == "A")
        #expect(move(.down, from: "B") == "C")
        #expect(move(.up, from: "C") == "B")
        #expect(move(.left, from: "A") == nil)
        #expect(move(.up, from: "A") == nil)
    }

    @Test("next and previous follow layout order and wrap")
    func order() {
        #expect(move(.next, from: "A") == "B")
        #expect(move(.next, from: "C") == "A")
        #expect(move(.previous, from: "A") == "C")
    }
}
