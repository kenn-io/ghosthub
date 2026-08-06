# iOS Renderer Spike Design

## Purpose

Determine whether Ghosthub's pinned libghostty can provide a viable terminal
renderer and input path for a future iPad client. This spike tests only the
libghostty/UIKit boundary. It does not establish an iOS product architecture or
begin porting the macOS application.

The experiment remains isolated on the `ios-spike` branch under
`Spikes/iOSRenderer/`. Production targets must not be restructured unless the
spike establishes viability and a later design explicitly authorizes that work.

## Viability Criteria

The spike is viable when it can:

- launch in an iPad Simulator;
- create a libghostty surface backed by a `UIView`;
- render deterministic ANSI output containing colors, cursor movement,
  Unicode, and scrolling;
- accept software-keyboard and Mac hardware-keyboard input;
- capture the bytes libghostty writes toward its terminal backend and reinject
  them for visible local echo;
- resize, destroy, and recreate the surface without crashing; and
- leave the ordinary macOS `make build` gate passing.

Failure to satisfy a criterion should produce a stage-specific diagnostic so
the experiment identifies the blocking boundary rather than merely failing to
launch.

## Scope

### Included

- A minimal iPad app and Xcode project under `Spikes/iOSRenderer/`.
- An iOS device and Simulator build of the repository's revision-pinned,
  Ghosthub-patched GhosttyKit.
- A small UIKit bridge for libghostty application and surface lifecycle.
- A deterministic ANSI transcript and an external-I/O loopback harness.
- Narrow lifecycle and input coverage for the spike.
- Make targets that build and test the experiment reproducibly.

### Excluded

- SSH, tmux, kwt, host discovery, networking, and authentication.
- Local shells, subprocesses, and PTYs on iPadOS.
- Ghosthub workspace, persistence, settings, and production UI integration.
- Polished selection, clipboard, mouse, pointer, or exhaustive keyboard parity.
- Device distribution, signing automation, TestFlight, App Store work, and
  website changes.
- Refactoring the existing `GhosthubTerminal` module for multiple platforms.

## Architecture

### iOS artifact build

A dedicated Make target builds the pinned GhosttyKit with iOS device and
Simulator slices into `.build/ios-spike/`. It must not replace or invalidate the
macOS artifact staged under `.build/libghostty/`.

The target reuses the existing bootstrap code and all Ghosthub libghostty
patches that are platform-independent. Any additional patch needed solely for
external I/O must be narrowly scoped and must preserve the macOS build and
runtime behavior.

### Minimal iPad app

The spike is a standalone iPad app with one SwiftUI scene. It does not import
`GhosthubApp`, `GhosthubUI`, `GhosthubSettings`, or `GhosthubPersistence`.
Its only application responsibility is presenting the renderer harness and a
small status surface for diagnostics and reset actions.

### UIKit libghostty bridge

A `UIViewRepresentable` owns a custom `UIView` that hosts the iOS libghostty
surface. The bridge:

- initializes and frees the libghostty configuration and application handles;
- creates the surface with `GHOSTTY_PLATFORM_IOS` and the view pointer;
- reports content scale, focus, occlusion, and pixel-size changes;
- schedules libghostty application ticks from its wakeup callback;
- injects externally supplied terminal output; and
- frees the surface before freeing its application and configuration handles.

The bridge remains local to the spike. It should favor clear evidence over a
premature reusable abstraction.

### External-I/O harness

The harness must not launch a local program. A deterministic ANSI transcript is
the terminal's output source, and libghostty's child-write callback is the input
sink.

Upstream libghostty exposes an iOS embedding platform, but its ordinary surface
still initializes a subprocess/PTY-oriented terminal backend. If surface
creation or operation depends on that backend, the bootstrap adds the smallest
possible experimental no-child external-I/O mode. The experiment must not use
a dummy local subprocess as a workaround because iPadOS cannot provide that
contract for a future client.

## Data Flow

On launch:

1. The app initializes libghostty and creates one external-I/O surface.
2. The bridge reports the view's current scale and pixel size.
3. The harness injects a fixed ANSI transcript.
4. Libghostty parses the transcript, updates terminal state, and renders it into
   the `UIView`.

For input:

1. `UIKeyInput` supplies software-keyboard text.
2. UIKit press events supply hardware keys, modifiers, presses, releases, and
   repeats.
3. The bridge sends those events through libghostty's text and key APIs.
4. The child-write callback captures the exact bytes libghostty generates.
5. The harness records those bytes and reinjects them as terminal output for
   local echo.

Direct reinjection intentionally lets control and escape sequences affect the
terminal. This demonstrates libghostty's actual terminal input encoding rather
than validating a separate spike-only encoder.

## Demonstration Content

The deterministic transcript exercises:

- standard and bright ANSI colors;
- 24-bit foreground and background colors;
- bold, italic, underline, and reset behavior;
- cursor positioning and line clearing;
- ASCII, composed Unicode, wide glyphs, and emoji;
- enough lines to create scrollback; and
- a visible prompt showing where looped-back input begins.

The harness includes a Reset Surface action that destroys and recreates the
surface, then reinjects the same transcript.

## Error Handling

The build reports GhosttyKit compilation or linkage failures. Once launched,
the spike presents an in-app status for these runtime stages:

- `ghostty_init`;
- configuration creation and finalization;
- application creation;
- surface creation;
- transcript injection; and
- surface teardown and recreation.

Recoverable errors remain visible and keep the diagnostic UI usable. The spike
may stop after a failed prerequisite, but it must report which prerequisite
failed. Callback userdata must remain valid until the associated libghostty
handle is freed, and teardown must be idempotent from UIKit lifecycle paths.

## Validation

Automated validation provides Make targets for:

- building GhosttyKit for iOS device and Simulator without replacing the
  macOS staged artifact;
- building the iPad app for the installed Simulator SDK;
- running a narrow lifecycle smoke test that creates, resizes, injects output
  into, destroys, and recreates a surface; and
- testing representative printable, Return, Backspace, arrow, Control, and
  Option/Meta input events at the bridge boundary where deterministic coverage
  is practical.

Manual validation confirms:

- the reference transcript renders correctly;
- the software keyboard enters text;
- a Mac hardware keyboard enters text and representative special keys;
- rotation and window resizing redraw without corruption; and
- Reset Surface succeeds repeatedly without a crash.

Because this work touches libghostty bootstrap and Swift terminal code, the
repository's applicable terminal regression checks remain required. At minimum,
`make test-libghostty-bootstrap`, `make python-test`, `swift test`, and
`make build` must pass before the implementation turn is complete.

## Outcome

The spike produces evidence, not production code. If all viability criteria
pass, a later design can define a remote-only iPad client and decide which
bridge code should graduate into shared targets. If rendering, input, or
external I/O is blocked, the branch preserves the diagnostic result without
forcing compatibility scaffolding into the macOS application.
