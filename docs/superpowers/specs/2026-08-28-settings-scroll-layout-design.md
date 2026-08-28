# Settings Scroll Layout Design

## Goal

Keep the selected settings-domain header fixed in every settings pane. In the
Hosts pane, keep the host selector fixed while the selected host editor scrolls
independently.

## Current behavior

`SettingsView` wraps both its header and selected-domain content in one
`ScrollView`. `HostsSettingsView` then places its own `List` inside that outer
scroll container. Scrolling the host editor therefore moves the domain header
and host selector with it.

## Design

Keep the existing two-column `NavigationSplitView` and category sidebar. The
detail column becomes a full-height vertical stack with two regions:

1. A padded header outside any scroll container.
2. Domain content that fills the remaining height and owns its scrolling.

Ordinary settings domains retain their current sections and visual styling in
a shared detail `ScrollView`. Hosts receives the available detail height
directly. `HostsSettingsView` keeps its host selector as a full-height `List`
and wraps only the selected-host editor in a vertical `ScrollView`. The host
selector and editor retain their current widths, controls, selection bindings,
and persistence behavior.

This stays within the existing SwiftUI `NavigationSplitView` and `List`
selection model. A three-column root would fit Hosts but add an unnecessary
conditional column for every other domain. Replacing all custom sections with
`Form` would broaden the change into a visual redesign without helping the
scroll ownership bug.

## Behavior and boundaries

- Switching settings domains updates the fixed header as it does today.
- Scrolling any ordinary domain moves only that domain's settings content.
- Scrolling the selected host editor moves only the editor content.
- The host selector retains its own internal scrolling when the host inventory
  is taller than its visible region.
- Add, remove, import, verification, launch profile, and project actions keep
  their existing state and error handling.
- The settings sheet keeps its existing minimum size and Done toolbar action.
- No persistence, host discovery, terminal, or remote-connection behavior
  changes.

## Verification

Add a focused AppKit-hosted SwiftUI regression test in
`Tests/UI/SettingsViewTests.swift`. Mount the Hosts domain with a synthetic host,
locate the editor scroll view, scroll it, and compare converted view frames
before and after the scroll. The test must prove that:

- the large Hosts header stays in place;
- the host list stays in place; and
- a settings section inside the editor moves.

Run the new test before implementation and confirm that it fails for the
reported coupling. After the layout change, run the focused test, `make format`,
`make swift-test`, and `make build`. Review the rendered settings window if the
available UI harness can present it without using live Ghosthub application
state.

The public Guide needs no change because the available controls and documented
workflow remain the same. No screenshot asset is part of this change.
