import AppKit
import SwiftUI
import WebKit

public struct WebPreviewWorkspaceLayout: View {
    private let mode: WebPreviewLayoutMode
    @Binding private var previewWidth: CGFloat
    private let terminal: AnyView
    private let preview: AnyView
    @State private var dragStartWidth: CGFloat?

    public init(
        mode: WebPreviewLayoutMode,
        previewWidth: Binding<CGFloat>,
        terminal: AnyView,
        preview: AnyView
    ) {
        self.mode = mode
        _previewWidth = previewWidth
        self.terminal = terminal
        self.preview = preview
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                terminal
                    .frame(
                        width: mode == .previewOnly ? 0 : nil
                    )
                    .frame(
                        maxWidth: mode == .previewOnly
                            ? nil
                            : .infinity,
                        maxHeight: .infinity
                    )
                    .clipped()
                    .opacity(mode == .previewOnly ? 0 : 1)
                    .allowsHitTesting(mode != .previewOnly)
                    .accessibilityHidden(mode == .previewOnly)

                if mode != .terminalOnly {
                    if mode == .split {
                        resizeDivider(availableWidth: geometry.size.width)
                    }

                    preview
                        .frame(
                            width: mode == .split
                                ? previewWidth
                                : nil
                        )
                        .frame(
                            maxWidth: mode == .previewOnly
                                ? .infinity
                                : nil,
                            maxHeight: .infinity
                        )
                }
            }
        }
    }

    private func resizeDivider(availableWidth: CGFloat) -> some View {
        WebPreviewResizeCursorView()
            .frame(width: WebPreviewLayoutPolicy.dividerWidth)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = previewWidth
                        }
                        guard let dragStartWidth else { return }
                        previewWidth = WebPreviewLayoutPolicy
                            .clampedPreviewWidth(
                                dragStartWidth - value.translation.width,
                                availableWidth: availableWidth
                            )
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize web preview")
            .accessibilityValue("\(Int(previewWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = direction == .increment ? 40 : -40
                previewWidth = WebPreviewLayoutPolicy.clampedPreviewWidth(
                    previewWidth + change,
                    availableWidth: availableWidth
                )
            }
    }
}

public struct WebPreviewView: View {
    @ObservedObject private var session: WebPreviewSession

    public init(session: WebPreviewSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            progress
            Divider()
            browserContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Web preview for \(session.context.worktreeName)")
    }

    private var browserToolbar: some View {
        HStack(spacing: 6) {
            browserButton(
                "Back",
                systemImage: "chevron.left",
                isEnabled: session.canGoBack,
                action: session.goBack
            )
            browserButton(
                "Forward",
                systemImage: "chevron.right",
                isEnabled: session.canGoForward,
                action: session.goForward
            )
            browserButton(
                session.isLoading ? "Stop" : "Reload",
                systemImage: session.isLoading ? "xmark" : "arrow.clockwise",
                isEnabled: session.isLoading || session.webView.url != nil,
                action: session.reloadOrStop
            )

            TextField("http://localhost:3000", text: $session.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(session.submitAddress)
                .accessibilityLabel("Web address")
                .accessibilityHint(
                    "Enter a complete HTTP or HTTPS address and press Return."
                )

            browserButton(
                "Open in Default Browser",
                systemImage: "arrow.up.right.square",
                isEnabled: session.webView.url != nil,
                action: session.openExternally
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var progress: some View {
        if session.isLoading {
            ProgressView(value: session.estimatedProgress)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .accessibilityLabel("Loading web page")
        } else {
            Color.clear.frame(height: 2)
        }
    }

    private var browserContent: some View {
        ZStack {
            WebPreviewWebView(webView: session.webView)

            if let errorMessage = session.errorMessage {
                ContentUnavailableView {
                    Label("Page Could Not Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", action: session.retry)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            } else if session.webView.url == nil, !session.isLoading {
                ContentUnavailableView {
                    Label("Web Preview", systemImage: "globe")
                } description: {
                    Text(
                        "Enter the HTTP or HTTPS address for this worktree's local web app."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private func browserButton(
        _ label: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct WebPreviewWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct WebPreviewResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}
