# Adaptive Session Preview Height Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove unnecessary black bars by sizing captured tmux preview tiles from the source terminal aspect ratio within 4:3–2:1 limits.

**Architecture:** The snapshotter computes an adaptive output size from the IOSurface dimensions and returns an image with that size. SwiftUI reads the captured image ratio for tile layout and falls back to 16:10 before a frame exists.

**Tech Stack:** Swift, SwiftUI, AppKit, IOSurface, Metal, Swift Testing, XCTest.

## Global Constraints

- Preserve the complete terminal frame; do not crop.
- Clamp captured tile aspect ratios to 4:3–2:1.
- Keep placeholders at 16:10.
- Do not resize or reparent the terminal surface to derive preview geometry.
- Do not create another tmux or SSH client.

---

### Task 1: Adaptive Snapshot Geometry

**Files:**
- Modify: `Sources/Terminal/TerminalSurfaceSnapshotter.swift`
- Modify: `Sources/App/TmuxSessionPreviewCoordinator.swift`
- Test: `Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift`

**Interfaces:**
- Consumes: the IOSurface width and height already read by `makeSnapshot`.
- Produces: `snapshot(of:outputWidth:minimumAspectRatio:maximumAspectRatio:previousCaptureToken:)` returning a thumbnail whose height matches the clamped source ratio.

- [ ] **Step 1: Write the failing adaptive snapshot test**

Capture a known 400×300 IOSurface at width 320 and assert that the returned
image is 320×240 rather than 320×200.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `make swift-test SWIFT_TEST_FILTER=testSnapshotPreservesInRangeSourceAspectRatio`

Expected: FAIL because the snapshot API still requires and returns a fixed
320×200 output.

- [ ] **Step 3: Implement the adaptive snapshot size**

Replace the fixed output size with a width and aspect-ratio limits. Validate the
width and limits, clamp `sourceWidth / sourceHeight`, and render to
`width × width / clampedRatio`.

- [ ] **Step 4: Run snapshot tests and verify GREEN**

Run: `make swift-test SWIFT_TEST_FILTER=TerminalSurfacePreviewTests`

Expected: all snapshot and parking tests pass.

### Task 2: Adaptive SwiftUI Tile Layout

**Files:**
- Modify: `Sources/UI/WorkspaceSidebarView.swift`
- Modify: `Sources/App/TmuxSessionPreviewViews.swift`
- Test: `Tests/UI/WorkspaceSidebarViewTests.swift`

**Interfaces:**
- Consumes: `NSImage.size` from the visible captured frame.
- Produces: `TmuxSessionPreviewRowPresentation.aspectRatio(for:)`, clamped to 4:3–2:1 with a 16:10 nil/invalid fallback.

- [ ] **Step 1: Write failing layout-policy tests**

Assert that 4:3 and 16:9 image sizes are preserved, 1:1 clamps to 4:3, 3:1
clamps to 2:1, and nil falls back to 16:10.

- [ ] **Step 2: Run the focused UI test and verify RED**

Run: `make swift-test SWIFT_TEST_FILTER=WorkspaceSidebarViewTests`

Expected: FAIL because only the fixed `aspectRatio` constant exists.

- [ ] **Step 3: Implement adaptive tile layout**

Add the pure clamping policy, derive the tile ratio from its image, and remove
the sidebar's outer fixed-ratio modifier. Keep the image scaled to fit so
out-of-range surfaces retain their full contents.

- [ ] **Step 4: Run focused UI tests and verify GREEN**

Run: `make swift-test SWIFT_TEST_FILTER=WorkspaceSidebarViewTests`

Expected: all sidebar presentation tests pass.

### Task 3: Documentation, Acceptance Image, and Gates

**Files:**
- Modify: `website/docs/content/sessions.md`
- Modify: `website/docs/content/terminal-configuration.md`
- Refresh: `guide-session-previews.png` on `website-assets`

**Interfaces:**
- Consumes: accepted adaptive preview UI.
- Produces: current Guide wording and screenshot.

- [ ] **Step 1: Update Guide wording**

Describe adaptive 4:3–2:1 height and minimal letterboxing outside the limits.

- [ ] **Step 2: Run all required gates**

Run `make format`, `make swift-test`, `make test-essential-workflows`,
`make docs-build`, and `make build`.

- [ ] **Step 3: Refresh and publish the deterministic screenshot**

Build the release demo app, stage/run/shoot the session-preview workflow, inspect
the image for synthetic data and adaptive geometry, then commit and push only
`guide-session-previews.png` to `website-assets`.

- [ ] **Step 4: Remove local planning artifacts and commit the feature fix**

Remove this spec and plan before pushing. Commit only implementation, tests,
documentation, and accepted asset-contract changes, then push
`session-previews`.
