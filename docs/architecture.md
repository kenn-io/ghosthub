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

## Window Model

Each Ghosthub workspace is an independent SwiftUI scene with its own scene
model, selection, and terminal coordinators. Workspaces may be presented as
separate windows or grouped using native AppKit `NSWindow` tabs. Cmd-N opens a
new window, while Cmd-T opens a workspace and adopts it into the active
window's native tab group. AppKit owns the tab bar, tab movement, and window
merging; Ghosthub does not render a custom tab strip or project tmux windows
into native UI.

Closing a native tab closes only that workspace presentation. Closing the last
tab of the last workspace follows the same quit-confirmation policy as closing
the final standalone window.

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

### Anonymous Usage Telemetry

Packaged release builds send a single allowlisted `application active` event
to Ghosthub's PostHog project at most once per UTC day. A Ghosthub-owned native
Swift client submits the event directly instead of enabling a general-purpose
analytics SDK, automatic lifecycle capture, screen capture, or swizzling.

The distinct ID is a random installation UUID stored in
`~/.ghosthub/telemetry.json`. Installation-ID creation and each UTC-day claim
are one interprocess-locked transaction, so simultaneous Ghosthub instances
share the same identity and only one schedules the event. The claim is
persisted before networking so an accepted event with a lost response is not
retried. Event properties are limited to the application name, native-app
source, version, and build number. Events explicitly disable PostHog
person-profile processing and GeoIP enrichment. Repository, worktree, host,
session, path, command, and terminal data are outside the telemetry contract.

Anonymous usage reporting is enabled by default in packaged releases. Users
can disable it in Settings or with `GHOSTHUB_TELEMETRY_ENABLED=0` or
`TELEMETRY_ENABLED=0`. Debug builds and tests do not configure the production
telemetry client. Each activity check refreshes the persisted privacy
preference so another Ghosthub process can disable reporting. While the app is
active, it schedules the next check for the following UTC-day boundary and
cancels that check when the app resigns active. The persisted activity day is
monotonic: stale claims cannot move it backward or make a newer day report
twice.

### External State

Ghosthub bundles revision-pinned kwt CLI builds for local project and worktree
operations and for `darwin/{amd64,arm64}`, `linux/{amd64,arm64}`, and
`windows/{amd64,arm64}` remote hosts. The local helper is signed as app code and invoked by its exact bundle
path. Remote helpers are sealed resources in the signed app. After the user
chooses **Install kwt Worktree Helper** for a host, Ghosthub selects the matching
`uname` target, uploads it, verifies its SHA-256 on the host, and atomically
installs it under `~/.ghosthub/helpers/kwt/<revision>/kwt`. Packaging verifies
the six binaries' formats, architectures, and embedded revision; installation
also requires the uploaded helper's `version` output to report that revision
before promotion. Every remote kwt operation invokes that exact revisioned
path; failed upload or installation attempts also best-effort remove their
unique staged file. Neither local nor remote operations select an unrelated
kwt from `PATH`. This is a CLI boundary, not a vendored daemon or submodule.
Kwt's machine-readable CLI provides project identity, worktree metadata, and
exact tmux session names.
On a host with no existing kwt registry, the user adds one absolute repository
path at a time through **Add Project**. Ghosthub delegates registration to
`kwt projects add --json`, then refreshes ordinary kwt inventory; it does not
search the host's filesystem or write kwt's configuration itself.
The account login shell initializes the command environment, while Ghosthub's
own inventory and discovery commands execute under the host's POSIX `/bin/sh`;
non-POSIX account shells such as fish are not asked to interpret those commands.
Direct tmux discovery provides every otherwise-unbound session. A remote host
without kwt remains a valid tmux-only host; remote inventory failures stay
attached to that host and never replace usable local or cached inventory with a
workspace-wide error. Ghosthub has no Middleman runtime or API dependency.

Kwt also owns pull-request provider integration: authentication, repository
identity, candidate discovery, and worktree import. Ghosthub may present a
machine-readable candidate list and submit the user's selection through a
supported kwt command, but it does not query GitHub or another forge directly.
Candidate discovery begins only after the user opens the pull-request import
surface for a project; startup inventory must not issue one provider request
per project. The opaque candidate ID returned by kwt is passed back unchanged,
and the successful import response supplies the canonical worktree path,
branch, tmux session name, and isolated tmux socket name. Ghosthub requests a
durable import without session startup; importing contributor-controlled code
does not start tmux or execute project layout and bootstrap commands. A
successful result is presented through kwt's protected attach command. That
command verifies
persisted workspace provenance and the current tmux state, creates or repairs
an inert shell-only session on the workspace-specific server when needed, and
then executes an ordinary client with environment updates disabled. The user
may explicitly run project commands after attachment. Other workspaces and
unbound sessions continue to attach directly to the host's normal tmux server.

Remote kwt installation is never implicit. Ordinary inventory, connection
testing, and tmux attachment remain non-mutating, and a remote host without the
managed helper remains tmux-only. Install and Update are explicit Settings
actions and never replace a host's system kwt. Versioned directories retain
older pinned helpers, so installing an older Ghosthub build can select and
restore its own revision; reinstalling one revision also retains
`kwt.previous`.

Native Windows installation uses a separate PowerShell boundary. The explicit
**Install Bundled kwt** action probes the remote process architecture, uploads
the matching PE helper over OpenSSH, verifies it at a managed staging path, and
atomically installs it at `%USERPROFILE%\.ghosthub\bin\kwt.exe` without
replacing a system `kwt.exe`. A failed activation restores the prior managed
helper. The Windows helpers remain unsigned experimental payloads until the
release pipeline adds an approved Authenticode/DigiCert signing step.

### Experimental native Windows hosts

A configured Windows host uses OpenSSH, Windows PowerShell 5.1 or newer, and
psmux's `tmux.exe` compatibility alias. Ghosthub probes and discovers psmux
through encoded, noninteractive PowerShell commands, then creates and attaches
to sessions using the same exact-target and attach-only reconnect model as
POSIX tmux hosts. Windows 11 build 22523 or newer is the initial interactive
target because its ConPTY path supports ordinary OpenSSH TTY allocation.

When Ghosthub creates a native Windows session, it passes the SSH account
process's `PATH` through psmux's session-environment argument so the initial
PowerShell and later panes resolve the same user-installed tools as a direct
SSH shell. It retains psmux's native status-bar styling and does not rewrite
the environment of an existing session or running pane.

## Startup and Onboarding

Ghosthub always completes kwt and tmux inventory before deciding which empty
state to show. Existing users go directly to their host-wide session sidebar;
there is no repository-intake interstitial and no first-launch modal.

When both inventories are empty, Ghosthub explains that kwt owns project
registration and tmux owns sessions. Ghosthub does not edit kwt's config file
or present its retired Middleman-backed Add Repository flow. The **+** menu on
each host exposes **Add Project**, which passes one explicit absolute checkout
path to kwt's supported noninteractive registration command. Ghosthub does not
scan the host for repositories.

## Source Layout

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | App composition, window orchestration, external command boundaries, and app-owned session planning |
| `Sources/UI/` | Reusable SwiftUI/AppKit presentation components |
| `Sources/Settings/` | Native settings and preferences |
| `Sources/Terminal/` | libghostty-backed terminal runtime and surface views |
| `Sources/TerminalSupport/` | libghostty config/bootstrap support that can compile without the linked library |
| `Sources/TmuxControl/` | Small native tmux/SSH attachment command model |
| `Sources/Workspace/` | Pure workspace, host, project, worktree, and session models |
| `Sources/Persistence/` | GRDB repositories for app-local state |
| `tools/` | Python bootstrap and packaging automation |
| `Tests/` | Swift and Python tests |

Terminal configuration is Ghosthub-owned and applied transactionally through
libghostty. The runtime watches the active base, project, appearance, and
recursive include graph with debouncing. Invalid candidates never replace the
last valid configuration. Automatic successes are silent, automatic failures
remain visible, and explicit reloads publish a user-visible result.

## Session Attachment

Kwt workspaces and otherwise-unbound host sessions use the same native tmux
client. Ghosthub never projects tmux windows or panes into a Swift split tree.
Closing the app, changing selection, or pressing Cmd-W closes only the client;
it never runs `kill-session`. An explicit, confirmed Kill Session action
targets the exact session (`=<name>:`) on its selected default or protected
socket only when discovery or a currently connected active attachment
establishes that it is running. Confirmation captures the selected host
endpoint and tmux server PID, `session_id`, and `session_created` identity. A
single tmux conditional checks all three live values and kills only the
matching instance, rejecting a same-named replacement even within the same
timestamp second or after a rapid tmux server restart.
Ghosthub detaches an active client after a successful kill, never before the
operation can fail. After success, Ghosthub closes the matching current active
selection and navigates away only when the killed target is active at
completion time, so switching sessions during the command is preserved. The
action terminates all of that session's windows, panes, and processes. For SSH,
Ghosthub supplies keepalives and retries
transport status 255. Tmux owns all windows, panes, history, input, rendering,
and server-side lifetime.

Ghosthub does not modify shared tmux colors by default. The explicit Tmux Theme
override is the only presentation exception: before attachment it resets
status and message styles to terminal defaults and supplies the selected
built-in theme's foreground and background to existing windows in the exact
session. This gives tmux deterministic OSC 10/11 responses, but tmux shares the
result with every attached client. The best-effort styling can never prevent
attachment. Tmux still owns all interaction behavior; Ghosthub does not modify
its prefix, key tables, mouse mode, window/pane commands, history, or layout.

An explicit New Tmux Session action is the sole boundary where Ghosthub
creates a bare tmux session itself. For a user-supplied exact name, local
presentation uses one atomic
`new-session -A` create-or-attach invocation so `destroy-unattached` cannot
remove a newly created session before the client arrives. Remote presentation
performs one idempotent, detached create-if-absent phase before ordinary
attachment, then permanently enters the attach-only SSH reconnect loop.
Before opening an ordinary worktree, Ghosthub asks kwt to establish or repair
that exact path's canonical session without attaching. Kwt inventory includes
worktrees whose sessions are not currently running, so inventory membership is
not evidence that attach-only will succeed. Kwt owns any required layout and
environment bootstrap; Ghosthub then presents an ordinary tmux client. The
remote establishment phase runs once, and transport reconnects remain
attach-only. Discovered sessions that are not bound to worktrees are always
attach-only.

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
for the remaining live sessions on each host and for the eventual result of an
explicit named-session creation request. A worktree open does not infer live
session state from kwt inventory: it uses kwt's exact-path start-only command
to converge the session before attachment.

Ghosthub local persistence stores app-owned state:

- terminal presentation state
- selected worktree/window state
- settings that are explicitly native-app concerns
- the anonymous telemetry installation UUID and last attempted activity day

Do not add database migrations before the first production release. Edit the
current schema, bootstrap paths, fixtures, and tests directly.

## Direction

Ghosthub should remain a native terminal client and session switcher: one
sidebar for the tmux servers across a user's Macs, Linux hosts, and tailnet.
The native app owns discovery, native client presentation, and SSH reconnect
supervision. It does not reconstruct tmux terminal state in Swift.
