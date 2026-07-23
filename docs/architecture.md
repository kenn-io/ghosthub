# Architecture

This page is the maintained architecture and product source of truth for
Ghosthub. Historical design plans are kept outside the generated docs site.
Security guarantees and trusted-peer assumptions are defined separately in
the [Threat Model](threat-model.md).

## Mental Model

- **Host:** a machine that runs tmux sessions. The local Mac is the default
  host. Remote hosts are reachable over SSH, commonly through a tailnet.
- **Project:** a git repository reported by kwt on a host.
- **Worktree:** a kwt workspace with an exact tmux session name.
- **Session:** an ordinary tmux session on a host.

The sidebar is a host-wide session navigator. It shows registered worktrees and
every directly discovered tmux session on each host, including sessions that
were not created by Ghosthub or kwt. General tmux sessions are presented as one
ordinary native tmux client; tmux alone owns and renders their layout.

## Process Boundaries

### Ghosthub.app

The Swift app owns native presentation and terminal rendering:

- SwiftUI and AppKit window shell.
- libghostty surface lifecycle, input, resize, and rendering.
- Worktree/session selection and presentation state.
- Local GRDB persistence for app-owned state.
- SSH host settings and native tmux client presentation.

Swift should stay focused on native app behavior and terminal hosting. Shared
pure domain models belong in `Sources/Workspace`; external worktree state is
consumed through kwt's machine-readable CLI surfaces.

### Application Updates

Packaged releases embed Sparkle 2 and check a stable HTTPS appcast published as
an asset of the latest GitHub release. The app menu exposes **Check for
Updates…**, and Sparkle performs automatic background checks using its standard
native UI and installation flow. Development binaries without the packaged
feed and public key disable the update command instead of contacting a release
service.

The release workflow generates the appcast only after the DMG is Developer ID
signed, notarized, stapled, and checksummed. The update archive and appcast are
authorized by Ghosthub's Sparkle Ed25519 key. Apple Developer ID signing and
notarization provide an independent platform integrity check, but stock Sparkle
allows either identity to authorize key rotation; they are not an AND gate.
Ghosthub disables signed-feed failure expiration and does not intentionally use
that rotation path. The reviewed public key is embedded in `Info.plist`; its
private counterpart exists only in 1Password and the protected
`release-signing` GitHub environment.

### External State

Ghosthub bundles a revision-pinned kwt CLI for local project and worktree
operations. The helper is signed as part of the application and invoked by its
exact bundle path; Ghosthub does not select a different local kwt from `PATH`.
This is a CLI boundary, not a vendored daemon or submodule. Remote hosts execute
their own kwt from the remote login-shell `PATH`. Kwt's machine-readable CLI
provides project identity, worktree metadata, and exact tmux session names.
Direct tmux discovery provides every otherwise-unbound session. A remote host
without kwt remains a valid tmux-only host; remote inventory failures stay
attached to that host and never replace usable local or cached inventory with a
workspace-wide error. Ghosthub has no Middleman runtime or API dependency.

Kwt also owns pull-request provider integration: authentication, repository
identity, candidate discovery, and worktree import. Ghosthub may present a
machine-readable candidate list and submit the user's selection through a
supported kwt command, but it does not query GitHub or another forge directly.

## Startup and Onboarding

Ghosthub always completes kwt and tmux inventory before deciding which empty
state to show. Existing users go directly to their host-wide session sidebar;
there is no repository-intake interstitial and no first-launch modal.

When both inventories are empty, Ghosthub explains that kwt owns project
registration and tmux owns sessions. Ghosthub does not edit kwt's config file
or present its retired Middleman-backed Add Repository flow. A native Add
Project action will call a supported, noninteractive kwt registration command
once kwt exposes one; until then project registration remains in kwt itself.

## Source Layout

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | App composition, window orchestration, external command boundaries, and app-owned session planning |
| `Sources/UI/` | Reusable SwiftUI/AppKit presentation components |
| `Sources/Settings/` | Native settings and preferences |
| `Sources/Terminal/` | libghostty-backed terminal runtime and surface views |
| `Sources/TerminalSupport/` | Ghostty config/bootstrap support that can compile without libghostty |
| `Sources/TmuxControl/` | Small native tmux/SSH attachment command model |
| `Sources/Workspace/` | Pure workspace, host, project, worktree, and session models |
| `Sources/Persistence/` | GRDB repositories for app-local state |
| `tools/` | Python bootstrap and packaging automation |
| `Tests/` | Swift and Python tests |

## Session Attachment

Kwt workspaces and otherwise-unbound host sessions use the same native tmux
client. Ghosthub never projects tmux windows or panes into a Swift split tree.
Closing the app, changing selection, or pressing Cmd-W closes only the client;
it never runs `kill-session`. For SSH, Ghosthub supplies keepalives and retries
transport status 255. Tmux owns all windows, panes, history, input, rendering,
and server-side lifetime.

Ghosthub normalizes only tmux's session-scoped visual chrome before attaching:
the status and message styles resolve through the foreground and background
from Ghosthub's Ghostty-format terminal configuration, with reversed terminal
colors highlighting the status line. This styling is best-effort and can never
prevent attachment. Tmux still owns all interaction behavior; Ghosthub does
not modify its prefix, key tables, mouse mode, window/pane commands, history,
or layout.

An explicit New Tmux Session action is the sole session-creation boundary.
For a user-supplied exact name, local and remote presentation perform one
idempotent, detached create-if-absent phase before ordinary attachment. Remote
presentation then permanently enters the attach-only SSH reconnect loop.
Ordinary worktree and discovered-session navigation is attach-only. Existing
same-named sessions are attached without changing their windows or panes.

Ghosthub publishes the requested name optimistically. Reconciliation starts
only after the terminal runtime accepts the command, then checks direct tmux
discovery with bounded retries. The optimistic entry remains while the command
is still running; only an authoritative empty inventory after both retry
exhaustion and command termination may retire it. Confirmation permanently
demotes later retries to attach-only. Host endpoint changes and scene shutdown
cancel pending probes.

## State Ownership

Kwt's project and worktree JSON surfaces are authoritative for workspace
identity and exact tmux session names. Direct tmux discovery is authoritative
for the remaining sessions on each host and for the eventual result of an
explicit named-session creation request.

Ghosthub local persistence stores app-owned state:

- terminal presentation state
- selected worktree/window state
- settings that are explicitly native-app concerns

Do not add database migrations before the first production release. Edit the
current schema, bootstrap paths, fixtures, and tests directly.

## Direction

Ghosthub should remain a native terminal client and session switcher: one
sidebar for the tmux servers across a user's Macs, Linux hosts, and tailnet.
The native app owns discovery, native client presentation, and SSH reconnect
supervision. It does not reconstruct tmux terminal state in Swift.
