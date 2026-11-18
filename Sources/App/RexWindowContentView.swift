import AppKit
import GhosthubTerminalSupport
import GhosthubUI
import SwiftUI

/// A Rex window's panes once its layout has arrived; until then, or after
/// the window's connection is lost, the usual opening and recovery states.
struct RexWindowContentView: View {
    var container: TerminalSplitContainerView?
    var fallback: BorrowedSessionView
    var defersTerminalResize: Bool
    @Binding var closeRequest: RexPaneCloseRequest?
    var onConfirmClose: (RexPaneCloseRequest) -> Void
    @Environment(\.terminalBackgroundAppearance) private var backgroundAppearance

    var body: some View {
        Group {
            if let container {
                // A new presentation brings a new container; its own
                // identity makes SwiftUI show it instead of the old one.
                SplitContainer(container: container, defersResize: defersTerminalResize)
                    .id(ObjectIdentifier(container))
                    .padding(6)
                    .background(WorkspaceSurfaceColor.chrome(backgroundAppearance))
            } else {
                fallback
            }
        }
        .confirmationDialog(
            closeRequest.map { "Close \($0.title)?" } ?? "",
            isPresented: Binding(
                get: { closeRequest != nil },
                set: {
                    if !$0 {
                        closeRequest = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: closeRequest
        ) { request in
            Button("Close Pane", role: .destructive) {
                onConfirmClose(request)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Rex ends the program running in this pane.")
        }
    }

    private struct SplitContainer: NSViewRepresentable {
        let container: TerminalSplitContainerView
        let defersResize: Bool

        func makeNSView(context _: Context) -> TerminalSplitContainerView {
            container.defersContentResize = defersResize
            return container
        }

        func updateNSView(_ view: TerminalSplitContainerView, context _: Context) {
            view.defersContentResize = defersResize
        }
    }
}
