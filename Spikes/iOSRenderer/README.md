# iPad renderer and remote tmux spike

This standalone iPadOS 17+ app first proved that Ghosthub's pinned libghostty
can parse, render, encode input, and run without owning a subprocess or PTY. It
now spikes a second boundary: attaching that external-I/O surface to one exact,
existing remote tmux session through an in-process SSH client. It deliberately
excludes kwt, persistence, session creation or destruction, and production
Ghosthub navigation.

The spike stages its own universal GhosttyKit artifact below
`.build/ios-spike/`. It does not replace the macOS artifact used by SwiftPM.

## Build and test

From the repository root:

```sh
make bootstrap-ios-renderer-libghostty
make test-ios-renderer
make build-ios-renderer
```

Override `IOS_RENDERER_DESTINATION` when the default `iPad Pro 13-inch (M5)`
Simulator is unavailable:

```sh
make test-ios-renderer \
  IOS_RENDERER_DESTINATION='platform=iOS Simulator,name=iPad Air 13-inch (M4)'
```

The complete cross-platform acceptance gate is:

```sh
make bootstrap-ios-renderer-libghostty
make test-ios-renderer
make build-ios-renderer
make format
make test-libghostty-bootstrap
make python-test
swift test
make build
```

SwiftNIO SSH and SwiftNIO are resolved only by the standalone Xcode project;
their exact transitive revisions are recorded beside the project in
`project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Launch in Simulator

Boot an installed iPad Simulator, build, install, and launch the app:

```sh
xcrun simctl boot 'iPad Pro 13-inch (M5)'
open -a Simulator
make build-ios-renderer
xcrun simctl install booted \
  .build/ios-spike/DerivedData/Build/Products/Debug-iphonesimulator/RendererSpike.app
xcrun simctl launch --terminate-running-process booted io.kenn.RendererSpike
```

`simctl boot` may report that the device is already booted; that is harmless.

## Simulator checks

The status should reach **Rendered**. The black libghostty surface should show:

- cyan `Ghosthub iPad renderer spike` text;
- red, green, and blue ANSI samples;
- `λ → 日本語 👻`;
- `updated by cursor motion` on the cursor-target row; and
- numbered scroll rows ending at row 80.

Tap the surface to make it the first responder. For the software keyboard,
disable **I/O > Keyboard > Connect Hardware Keyboard** in Simulator, then type
ordinary text and use Backspace. Re-enable that setting for Mac keyboard input.
The latest bytes returned by libghostty appear below the surface as
`child_write:` hexadecimal diagnostics.

With the US keyboard layout used during this spike, representative results are:

| Input | Child-write bytes |
| --- | --- |
| ordinary `x` | `78` |
| Left Arrow | `1B 5B 44` |
| F1 | `1B 4F 50` |
| Home | `1B 5B 48` |
| Control-A | `01` |
| Option-D | `E2 88 82` (`∂`) |

Rotate the simulated iPad or resize the Simulator window, then press **Reset
Surface** several times. The transcript should remain rendered and responsive.
Initialization errors appear with the exact failed stage and message above the
surface.

## Attach to a remote tmux session

The transport spike currently requires a POSIX SSH host with password
authentication enabled and an already-running tmux session. Nothing entered in
the connection form is persisted. The SSH password stays in process memory and
is discarded when the app exits.

Enter the host, port, username, password, and exact tmux session name. For
**Host key**, paste a trusted Ed25519 or ECDSA OpenSSH public-key line. A line
copied from an existing, independently trusted `known_hosts` file is accepted,
including its leading hostname. For example, inspect an existing entry on the
Mac with:

```sh
ssh-keygen -F host.example.com -f ~/.ssh/known_hosts
```

For a non-default port, look up `[host.example.com]:2222`. Do not establish
trust from an unverified `ssh-keyscan` result: the spike intentionally has no
accept-any-host-key path.

Press **Connect** to request an `xterm-256color` PTY and execute an exact-target
`tmux attach-session -E` command through the account login shell. Keyboard bytes
then flow from libghostty to SSH, while SSH stdout and stderr flow back into the
surface. Grid changes generate SSH window-change requests. **Disconnect** closes
only the SSH presentation; it does not kill the tmux session. Once a connection
has reached the attached state, an unexpected stream closure retries after two
seconds using the in-memory configuration.

## Result

The 2026-08-05 spike is positive for the renderer/input substrate. On an iPad
Pro 13-inch (M5) Simulator, a normally launched app initialized the pinned
libghostty, created a real UIKit/Metal surface, injected the reference
transcript, propagated resize and scale changes, and repeatedly destroyed and
recreated the native surface without accumulating renderer layers. The
`Rendered` status is reached only after the Metal layer presents real content,
and runtime shutdown frees native surfaces before the libghostty application.
Live integration coverage also observed plain UTF-8, Left Arrow, F1, Home,
Control-A, and Option-D traverse libghostty's ordered child-write callback
before reinjection. Mapper coverage includes the common navigation, function,
forward-delete, and keypad-enter keys, plus hardware-key repeat actions.

Two upstream-facing adaptations were required: a no-child external-I/O termio
backend and a Darwin-wide libxev Mach-port completion guard. Both are applied
hermetically to Ghosthub's revision-pinned source during bootstrap, while the
existing macOS backend remains the default.

This establishes renderer technical viability, not a product architecture.
The in-process SSH/tmux path builds and has focused configuration tests, but its
2026-08-06 transport result remains pending a live remote-session run. A real
iPad Ghosthub would still need durable Keychain-backed credentials, first-class
host trust UX, host/session discovery, remote lifecycle, scene/navigation
design, background behavior, packaging, and device testing.
