# Architecture

This page is the maintained architecture and product source of truth for
Ghosthub. Historical design plans are kept outside the generated docs site.
Security guarantees and trusted-peer assumptions are defined separately in
the [Threat Model](threat-model.md).

## Mental Model

- **Host:** a machine that runs tmux and optionally Herdr or Zellij sessions. The local
  Mac is the default host. Remote hosts are reachable over SSH, commonly
  through a tailnet.
- **Project:** a git repository reported by kwt on a host.
- **Worktree:** a kwt workspace with an exact tmux session name.
- **Directory workspace:** one kwt-registered plain directory with an exact
  tmux session name and no Git children.
- **Session:** an ordinary tmux session, running/stopped Herdr session, or
  active Zellij session on a host.

The sidebar is a host-wide session navigator. Its **Projects** group shows
repository hierarchies followed by flat registered-directory rows. It also
shows directly discovered tmux sessions, running or stopped Herdr sessions,
and active Zellij sessions on each host, including sessions that were not
created by Ghosthub or kwt. The four inventories are independent; kwt worktrees and directory workspaces
remain tmux-backed. Users may hide matching standalone tmux sessions
from navigation with case-sensitive wildcard patterns; discovery retains the
complete inventory so a kwt-owned session confirmed by current discovery is
indicated on its worktree or directory row. Cached sessions do not remain live
while a host is unreachable. Kwt-owned sessions are hidden from the separate tmux session
group by default, with a Worktrees setting that exposes those duplicate
entries.
Tmux, Herdr, and Zellij sessions are each presented through their ordinary
native whole-session client. The selected backend alone owns its internal
layout. Each scene has at most one active interactive presentation.
Already-opened tmux clients may remain retained and noninteractive, and may
render only when the user explicitly enables session previews. A preview never
creates another client or reconstructs tmux panes, layout, or history.

After an attachment reaches the connected state, Ghosthub keeps that exact
session warm for the remainder of the app launch. One app-scoped, in-memory
activity controller serves every workspace window. It samples only warm
endpoints, never the complete discovered fleet, and binds each target to its
tmux server PID, session ID, and creation time. A bounded tail of the active
pane's scrollback, excluding its visible screen, is checksummed on the host
without discarding trailing blank output. Only the checksum, byte count,
scrollback line count, pane identity, and session identity return to the app.
The first sample for each active pane, and the first after a pane resize,
establishes a quiet baseline. A later scrollback change on that pane at
unchanged dimensions publishes a short-lived passive activity state to both
worktree and standalone session rows. Warm state is not
persisted, and a missing or same-named replacement session stops sampling that
identity.

## Window Model

Each Ghosthub workspace is an independent SwiftUI scene with its own scene
model, selection, and terminal coordinators. Workspaces may be presented as
separate windows or grouped using native AppKit `NSWindow` tabs. Cmd-N opens a
new window, while Cmd-T opens a workspace and adopts it into the active
window's native tab group. AppKit owns the tab bar, tab movement, and window
merging; Ghosthub does not render a custom tab strip or project tmux windows
into native UI.

The workspace `WindowGroup` is data-backed. Each scene continuously captures a
small logical descriptor containing stable host and project keys, the durable
kwt worktree generation or registered directory path, and an exact tmux
session/protected-socket, Herdr session, or Zellij session identity. Its window UUID exists only for native scene
adoption; runtime model UUIDs and worktree paths are never persisted as host,
project, or worktree identity. A worktree without a canonical generation
degrades to project-only navigation and does not persist its worktree-owned
tmux presentation. A directory workspace resolves by its authoritative kwt
registry path on the same host. SwiftUI and macOS normally
remain responsible for restoring scene count, native tab groups, and window
geometry. Before a Sparkle relaunch, Ghosthub also atomically records the
ordered logical descriptors in a one-shot manifest under `~/.ghosthub/`. The
app collects initial and late native scene values until AppKit reports that
native window restoration has finished and every restored workspace window has
registered its SwiftUI scene. Ghosthub requires the scenes' optional bindings to
be quiescent before unresolved scenes receive provisional unclaimed descriptors
in saved order, then requests a scene for every descriptor still missing. A
later native descriptor remains authoritative and corrects provisional
assignments. Scenes opened to replay missing descriptors also remain provisional:
if a late native scene reclaims their descriptor, the replay scene receives the
native scene's displaced descriptor instead. Replay requests use fresh scene
tokens rather than saved window IDs, preventing SwiftUI from coalescing them with
a late native scene; a displaced request is retargeted and issued again with the
same token. The manifest remains until every saved descriptor has begun
restoration in exactly one live assigned scene. Native restoration therefore
still owns geometry and tab grouping without dropping or duplicating a session.
After assignment, the scene model owns the complete logical descriptor; delayed
native payloads that share its window UUID but contain stale navigation or
presentation data are rewritten before they can become persisted scene state.
Every explicitly opened tmux presentation is retained by that workspace scene,
keyed by exact host, socket, and session identity. Active selection determines
which retained surface is mounted in the visible hierarchy; navigation only
hides the previous surface and does not terminate its tmux/SSH client or stop
its recovery supervisor. A retained worktree presentation keeps the generation
observed when it was established; a later non-nil generation change is a
replacement even when inventory reuses the same runtime UUID. Scene persistence
captures only the active presentation, while later generation enrichment is
written without requiring another navigation event.
Once a restored scene has current inventory, Ghosthub resolves the descriptor
back to live models and reattaches only to the confirmed exact session.
Missing or offline targets fail soft and remain pending across later inventory
refreshes. Explicit user navigation cancels pending restoration so a stale
scene can never take the window back.
Herdr restoration requires a completed fresh Herdr probe for the restored host
and the exact running name; cached pre-refresh rows never authorize attachment.
Zellij restoration has the same fresh-inventory requirement for the exact
active name. A captured scene contains one tmux, Herdr, or Zellij descriptor,
or none, never more than one.
A scene captured without an active native presentation restores its navigation
without opening or creating the selected worktree or directory session; the
user explicitly selects the workspace to attach again.

The host-scoped console panel is not part of workspace scene restoration. Its
existing global visibility preference is unchanged, and the user reopens the
surface when needed. Restoring the same session in more than one window may
reproduce the existing shared-presentation behavior tracked by kata `s75s`;
restoration does not add a separate collision policy.

Closing a native tab or window closes every retained presentation owned by that
workspace scene. Closing
the final workspace window leaves Ghosthub running, matching ordinary macOS
terminal behavior; Cmd-Q remains the explicit app-termination path. Ghosthub
confirms app termination by default, and users can disable that confirmation in
**Settings -> Terminal**. Closing presentations or quitting never terminates a
tmux, Herdr, or Zellij session: all detach clients. Kill Session remains a
separate confirmed tmux or Zellij action. Herdr exposes separate Create, Stop, Restart, and Delete
actions; Stop and Delete require confirmation and are never implied by
navigation or closing.

## Process Boundaries

### Ghosthub.app

The Swift app owns native presentation and terminal rendering:

- SwiftUI and AppKit window shell.
- libghostty surface lifecycle, input, resize, and rendering.
- Workspace/session selection and presentation state.
- Local GRDB persistence for app-owned state.
- SSH host settings and native tmux/Herdr/Zellij client presentation.

Swift should stay focused on native app behavior and terminal hosting. Shared
pure domain models belong in `Sources/Workspace`; external workspace state is
consumed through kwt's machine-readable CLI surfaces.

### Application Updates

Packaged releases embed Sparkle 2 and select exactly one update channel at
build time. Stable builds check the HTTPS appcast published as an asset of the
latest GitHub release. Nightly builds check the separately hosted nightly
appcast, carry a distinct Sparkle public key, and identify themselves as
**Ghosthub Nightly** while retaining the stable `com.ghosthub` bundle identity
and app-owned state. Installing one channel therefore replaces the other; the
channels cannot update into each other through Sparkle. Development binaries
without a packaged feed and public key disable the update command instead of
contacting a release service. The app menu exposes **Check for Updates…**, and
Sparkle performs automatic background checks using its standard native UI and
installation flow.

When the user accepts Sparkle's **Install and Relaunch**, Ghosthub captures
every live scene descriptor into the updater relaunch manifest before it
authorizes exactly one updater-driven AppKit termination request. The manifest
is discarded if the update aborts or errors, and consumed only after every
saved scene has begun restoration in the relaunched app. This authorization is
separate from ordinary quit confirmation and is cleared when an update cycle
aborts or finishes with an error. A successful cycle-finish notification that
arrives after the relaunch was requested does not disarm it, so Sparkle's
callback ordering cannot resurface the quit confirmation mid-relaunch.
Command-Q, final-window close, logout, restart, and
shutdown continue through the ordinary user preference and confirmation path.

Each release workflow generates its appcast only after the DMG is Developer ID
signed, notarized, stapled, and checksummed. The stable and nightly appcasts
use different Sparkle Ed25519 keys. Apple Developer ID signing and notarization
provide an independent platform integrity check, but stock Sparkle allows
either identity to authorize key rotation; the channel key and shared Apple
identity are not an AND gate. Ghosthub disables signed-feed failure expiration
and does not intentionally use that rotation path. Stable-feed routing and
publication authority are therefore the boundary that prevents unattended
nightly credentials from reaching stable users; the distinct nightly Sparkle
key is defense in depth. The private keys live only in 1Password and their
respective GitHub environments: approval-gated `release-signing` for stable
and unattended, `main`-restricted `nightly-signing` for nightly.

Stable releases live in the canonical repository. Nightly releases live in the
separate public `kenn-io/ghosthub-nightly` distribution repository, while the
canonical repository owns the only build, signing, notarization, and publishing
workflow. That workflow mints a short-lived `kenn-dist-update-bot` installation
token scoped to the distribution repository and cannot use it to alter stable
releases.

Manual nightly enrollment bypasses Sparkle, so the mutable latest-DMG URL is
only a discovery pointer; the operator must verify Gatekeeper acceptance and
the expected Kenn Software Apple Team Identifier on both the DMG and app before
the first install.

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

SSH transport, configuration resolution, and host-key storage remain owned by
the system OpenSSH client. Effective `ssh -G` output is nonce-framed inside the
account login shell so startup banners cannot become replayed SSH options. When
**Test Connection** or a host-scoped inventory
warning encounters an unseen key, Ghosthub presents the exact destination and
fingerprint through an explicit trust sheet. Approval is returned to that same
OpenSSH prompt through a private askpass channel; Ghosthub neither substitutes
a short alias nor writes a key obtained from a separate scanner. The approved
key therefore lands in the `UserKnownHostsFile` selected by the user's OpenSSH
configuration before the ordinary noninteractive probe or inventory refresh
retries.
When that retry needs interactive authentication, Ghosthub presents OpenSSH's
exact challenge in a native secure-entry sheet. The app brokers the session-only
response to the system client through a private FIFO; it does not put the
response in process arguments, environment variables, logs, or persistent
storage. A successful prompt leaves a non-persistent OpenSSH master owned by
the application session, and every window's inventory, transfer, and tmux
clients reuse its control socket in a per-launch namespace under
`~/.ghosthub/ssh/`. Its bounded socket
name includes an app-launch nonce plus a digest of the logical destination,
the normalized effective OpenSSH configuration for every route target, and the
proxy route, so changes to credentials, known-hosts files, trust identities,
routes, or app launches cannot reuse an authenticated master. A parent-held
watchdog descriptor remains open for the app lifetime and terminates each
master only when that descriptor reaches EOF. The next
launch removes only socket namespaces owned by processes that are no longer
running, so concurrent Ghosthub instances cannot unlink each other's masters.
When the state-home path would exceed macOS's Unix-socket limit, Ghosthub uses
the same process-owned namespace under `/tmp` and rejects any still-oversized
path before launching OpenSSH.
Routine clients and generated ProxyJump helpers explicitly disable
`ControlMaster` and `ControlPersist`; routine clients receive only Ghosthub's
supervised socket, while fallback proxy helpers set `ControlPath=none` so they
cannot inherit or create an unrelated master. Generated proxy commands also
force ordinary stdin/stdout forwarding instead of inheriting `ProxyUseFdpass`,
because Ghosthub's nested route commands do not return file descriptors.
Host-key review replays resolved key-exchange, cipher, MAC, and minimum RSA-key
constraints alongside known-hosts policy. Master preparation resolves one
effective-config snapshot, verifies that its control identity still matches
the cached path, and launches the endpoint, route, authentication, and
known-hosts options from that same snapshot under an empty base SSH
configuration. An identity change restarts recovery instead of using the old
socket path. Readiness resolves that identity again before reporting a
connection, invalidating the stale session and returning to recovery if the
route or control path changed. Master stderr is continuously drained into a
bounded diagnostic buffer through a nonblocking dispatch source, so verbose
OpenSSH logging cannot block the connection or occupy Swift concurrency
workers. Ghosthub keeps
the master in the foreground even if the user's SSH configuration requests
forking, so the app watchdog retains ownership of its lifetime. It removes
inherited tmux launcher state before starting the master through the account
login shell, preserving the same environment boundary used
by configuration checks and ordinary SSH operations.
Remote connection probes emit a leading line delimiter, then parse exact
protocol-marker lines only from stdout. SSH and login-shell diagnostics,
including marker text embedded in a banner, cannot make a failed probe appear
reachable.
Window presentations hold leases on shared authentication attempts. Closing a
window cancels an unfinished attempt only after its final presenting window
releases it; an authenticated master remains available until the app exits.
Before opening that channel, Ghosthub reads the effective destination policy
with `ssh -G`. It tightens `accept-new` to an explicit review but does not
override `yes`, `no`, or `off`; approval matches the parsed algorithm and
fingerprint rather than address-bearing prompt prose. Review-managed `ask` and
`accept-new` connections also disable `UpdateHostKeys`, so the connection
cannot persist additional server-advertised keys that were not reviewed.
Trust invocations use the same local account login-shell boundary as ordinary
SSH operations. For ProxyJump routes, Ghosthub names the host from OpenSSH's
prompt and reviews each unseen route key sequentially. When a preceding jump
host needs a password or other challenge, Ghosthub authenticates that reviewed
hop first and uses its app-session control connection to reach the next host.
The secure-entry sheet names the exact route host controlling the challenge
using its effective SSH user, hostname, and port, and warns the user to enter
only that host's credentials. Continue also permits a deliberate empty response
for keyboard-interactive challenges that require one.
Opaque ProxyCommand routes and jump hosts that introduce another proxy route
fail closed because Ghosthub cannot independently enforce every intermediate
host-key policy.

Ghosthub bundles revision-pinned kwt CLI builds for local project and worktree
operations and for `darwin/{amd64,arm64}`, `linux/{amd64,arm64}`, and
`windows/{amd64,arm64}` remote hosts. The local helper is signed as app code and invoked by its exact bundle
path. Remote helpers are sealed resources in the signed app. Before loading kwt
inventory for a configured remote macOS or Linux host, Ghosthub checks the
exact revisioned helper. If it is missing or stale, Ghosthub selects the
matching `uname` target, uploads it, verifies its SHA-256 on the host, and
atomically installs it under `~/.ghosthub/helpers/kwt/<revision>/kwt`.
Concurrent scenes share one provisioning operation per exact host endpoint.
When inventory cancellation removes the final caller, Ghosthub cancels that
operation and rechecks cancellation before upload and helper activation so a
removed or reconfigured host is not mutated by obsolete work.
Packaging verifies the six binaries' formats, architectures, and embedded
revision; installation also requires the uploaded helper's `version` output to
report that revision before promotion. Every remote kwt operation invokes that
exact revisioned path; failed upload or installation attempts also best-effort
remove their unique staged file. Neither local nor remote operations select an
unrelated kwt from `PATH`. Ghosthub integrates only through kwt's CLI and does
not manage its daemon directly. Kwt may auto-start or reuse its same-account
daemon behind that boundary. Kwt's machine-readable CLI provides project
identity, worktree metadata, and exact tmux session names.
On a macOS or Linux host with no existing kwt registry, the user adds one
absolute repository path at a time through **Add Project**. Ghosthub delegates
registration to `kwt projects add --json`, then refreshes ordinary kwt
inventory; it does not search the host's filesystem or write kwt's
configuration itself. A project's sidebar context menu exposes a confirmed
**Remove Project** action backed by
`kwt projects remove <path> --expected-repository <identity>
--expected-registration <fingerprint> --json`. Ghosthub supplies the exact
path, credential-free identity, and opaque registration fingerprint from the
record the user confirmed. A changed registration fails closed and requires a
new confirmation; a missing checkout remains removable when the guard
succeeds. Ghosthub preflights protected endpoints it already knows for
immediate feedback; kwt's daemon serializes the mutation with registration,
worktree, and protected-attachment operations, verifies durable protected
endpoint authority, and performs the final registry compare-and-swap. The
operation only unregisters discovery metadata and never deletes repositories,
worktrees, or tmux sessions. Windows hosts do not expose project registry
mutations until that command boundary supports native Windows paths.
On macOS and Linux, the account login shell initializes the command
environment, while Ghosthub's own inventory and discovery commands execute
under the host's POSIX `/bin/sh`; non-POSIX account shells such as fish are not
asked to interpret those commands. Windows commands execute through encoded
noninteractive PowerShell.
Direct tmux discovery provides every otherwise-unbound session. A remote host
without kwt remains a valid tmux-only host; remote inventory failures stay
attached to that host and never replace usable local or cached inventory with a
workspace-wide error. Ghosthub has no Middleman runtime or API dependency.

An enabled exe.dev account is a host-inventory provider, not a terminal
backend. Ghosthub invokes the account's configured OpenSSH destination with
`ls --json`, then treats each running VM as an ordinary Linux SSH host using
the response's exact `ssh_dest`; it never synthesizes a VM hostname or SSH
username. An account may carry a tag filter, in which case only VMs whose
`tags` include at least one filtered tag are discovered at all; the filter is
part of the account's discovery identity, so changing it invalidates that
account's cached VM list exactly as changing its destination does. Enabled accounts must use unique OpenSSH destinations; multiple
accounts therefore use distinct Host aliases. The account display name is
provider presentation metadata and never contributes to stable host identity.
The dynamic VM list is not copied into manual host settings. A
failed provider refresh retains the last usable VM list, while a successful
refresh removes stopped or deleted VMs. When a manual SSH host has the same
destination, the explicit manual configuration wins. System OpenSSH still
owns configuration, host-key storage, authentication, and routing for both the
exe.dev control destination and every discovered VM. Tmux and kwt continue to
own session and worktree identity exactly as they do on any other SSH host.

Kwt also owns pull-request provider integration: authentication, repository
identity, candidate discovery, and worktree import. Ghosthub may present a
machine-readable candidate list and submit the user's selection through a
supported kwt command, but it does not query GitHub or another forge directly.
Kwt keeps Git fetches noninteractive while allowing the host's ordinary system
and global Git credential-helper configuration to authenticate HTTPS remotes.
Its untrusted-tree lifecycle still suppresses repository-controlled execution
before materializing the imported checkout.
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

Adding a remote macOS or Linux host authorizes Ghosthub to maintain its
per-user managed kwt helper as part of inventory refresh. Provisioning failure
disables that host's worktree actions and reports the error without blocking
ordinary tmux discovery or attachment. The helper never replaces or resolves
a host's system kwt. Versioned directories retain older pinned helpers, so an
older Ghosthub build can select and restore its own revision; reinstalling one
revision also retains `kwt.previous`.

Native Windows installation uses a separate PowerShell boundary. The explicit
**Install Bundled kwt** action probes the remote process architecture, uploads
the matching PE helper over OpenSSH, verifies its SHA-256 and exact pinned
version at a managed staging path, and atomically installs it at
`%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe` without replacing or
resolving a system `kwt.exe`. A failed activation restores the prior helper at
that revision. Automatic Windows provisioning remains disabled while the
Windows helpers are unsigned experimental payloads; it requires an approved
Authenticode signing step first.

### Experimental native Windows hosts

A configured Windows host uses OpenSSH, Windows PowerShell 5.1 or newer, and
psmux's `tmux.exe` compatibility alias. Ghosthub probes and discovers psmux
through encoded, noninteractive PowerShell commands, then creates and attaches
to sessions using the same exact-target and attach-only reconnect model as
POSIX tmux hosts. Windows 11 build 22523 or newer is the initial interactive
target because its ConPTY path supports ordinary OpenSSH TTY allocation.
Passive activity sampling additionally requires psmux 3.3.4 or newer; earlier
versions remain attachable but cannot provide the scrollback-only capture
contract.

When Ghosthub creates a native Windows session, it passes the SSH account
process's `PATH` through psmux's session-environment argument so the initial
PowerShell and later panes resolve the same user-installed tools as a direct
SSH shell. It retains psmux's native status-bar styling and does not rewrite
the environment of an existing session or running pane.

## Startup and Onboarding

Ghosthub starts independent kwt, tmux, Herdr, and Zellij inventories before deciding
which empty state to show. Herdr and Zellij are additive and never block the workspace;
missing installations are silent. Existing users go directly to their host-wide session
sidebar;
there is no repository-intake interstitial and no first-launch modal.

When all visible inventories are empty, Ghosthub explains that kwt owns project
registration and tmux owns sessions. Ghosthub does not edit kwt's config file
or present its retired Middleman-backed Add Repository flow. The **+** menu on
macOS and Linux hosts exposes **Add Project**, which passes one explicit
absolute checkout path to kwt's supported noninteractive registration command.
Registered project rows expose a confirmed **Remove Project** action through
kwt's noninteractive unregistration command. Windows hosts omit both actions.
Ghosthub does not scan the host for repositories.

## Source Layout

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | App composition, window orchestration, external command boundaries, and app-owned session planning |
| `Sources/UI/` | Reusable SwiftUI/AppKit presentation components |
| `Sources/Settings/` | Native settings and preferences |
| `Sources/Terminal/` | libghostty-backed terminal runtime and surface views |
| `Sources/TerminalSupport/` | libghostty config/bootstrap support that can compile without the linked library |
| `Sources/Transport/` | Shared local/SSH routing, quoting, and command execution primitives |
| `Sources/Tmux/` | Native tmux discovery and attachment command model |
| `Sources/Herdr/` | Native Herdr discovery and attachment command model |
| `Sources/Zellij/` | Native Zellij discovery and attachment command model |
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

Each scene owns one active interactive presentation slot shared by tmux, Herdr,
and Zellij. Selecting Herdr or Zellij hides any active retained tmux client
before opening the peer presentation; selecting another tmux session hides the
previous retained tmux client. Already-opened retained tmux clients may render
as noninteractive previews when the user enables them, but previewing never
opens another client.
Herdr discovery and attachment are supported on the local Mac and configured
remote POSIX hosts, not experimental Windows/psmux hosts. Ghosthub shows
running and stopped sessions. Ordinary open and restoration are attach-only;
Create and Restart use Herdr's launch-or-attach path. Ghosthub manages only
whole-session create, stop, restart, and delete. The explicit Split Right and
Split Down app commands may ask a capable active Herdr attachment to split its
session-global focused pane; Herdr still owns themes, workspaces, tabs, panes,
agents, plugins, configuration, updates, and every process inside a session.

Stop terminates every process in the session but preserves Herdr's saved
workspace/tab/pane shape. Restart restores that shape with new processes.
Delete is offered only for stopped non-default sessions and permanently removes
their saved state. Every destructive command revalidates the current host,
state, and Herdr record immediately before execution. Herdr exposes no stable
session-generation identifier, so same-name/same-socket replacement cannot
receive tmux-strength identity protection; this race is documented rather than
hidden behind a false guarantee.

Zellij discovery and attachment are supported on the local Mac and configured
remote POSIX hosts. Ghosthub lists only active sessions, filtering Zellij's
exited/resurrectable entries. Ordinary open and restoration use attach-only;
remote restoration samples and rechecks one SSH connection snapshot, then
passes that frozen route to the client presentation. If the route changes,
restoration is canceled without attaching.
New Zellij Session uses `--session`, which refuses active and resurrectable
name collisions while Zellij creates and presents the new session. Ghosthub
does not expose resurrection or delete exited sessions and does not manage
tabs, panes, layouts, themes, plugins, configuration, updates, or processes
inside a session. Zellij provides no atomic active-only attachment, so a
session that exits between Ghosthub's active-state probe and `zellij attach`
may be resurrected by Zellij; Ghosthub does not pass `--force-run-commands`.

Closing a Zellij presentation only detaches. Kill Session is a separate
confirmed action that revalidates the exact name and current host immediately
before `kill-session`. A shared kill fence cancels matching reconnects and
detaches matching presentations across workspace scenes before the command,
preventing an already-launched Ghosthub client from undoing an intentional
kill. The successful event also invalidates in-flight Zellij discovery, removes
the killed row from every scene's cached inventory, and starts fresh discovery.
Per-session kill revisions prevent validation begun before the kill from
attaching afterward. A failed kill releases the fence and revalidates an
eligible detached presentation or matching pending open or restoration before
resuming it, while preserving its navigation and route checks. Zellij exposes
no stable session-generation identifier, so a same-name replacement between
that final check and the command remains an accepted race rather than receiving
tmux's stronger identity guarantee.

Kwt workspaces and otherwise-unbound host sessions use the same native tmux
client. Ghosthub never projects tmux windows or panes into a Swift split tree.
Changing selection only hides the previous retained client. Pressing Cmd-W
closes the active client, while closing its workspace window or the app closes
every client retained by that scene; none of these paths runs `kill-session`.
Optional sidebar previews copy width-bounded bitmap frames from these retained
clients. A tile follows its terminal's aspect ratio between 4:3 and 2:1 and
letterboxes only content outside those limits. Efficient mode captures on
disclosure and whenever the active tmux presentation navigates away, even when
its tile is collapsed. Live mode
may keep an inactive surface mounted behind the visible workspace content and
polls at no more than two frames per second. A process-wide budget permits at
most four such inactive live surfaces. Parked surfaces preserve their terminal
size and cannot receive focus, pointer input, or accessibility actions. The
active surface stays in the detail area and is copied without reparenting.
Preview pixels are published only after the attachment's token-bound tmux
client identity is available; a name-based session lookup never authorizes a
cached frame. Ghosthub revalidates that attached client after copying each
changed frame and rejects the copy if the client switched sessions. Attachments
that cannot supply this safe identity, including psmux and tmux older than 3.4,
show an unavailable placeholder instead of retaining unverified pixels.
Reconnect identity binding uses bounded background retries only after a preview
requests identity. Reconnecting keeps the last frame quarantined until the new
attachment binds to the same server and session identity, while replacement
clears the frame without collapsing the tile.
Off and Efficient modes schedule no preview work when a window becomes key,
and Off does not mount the hidden parking host. Live coalesces its delayed
parking reconciliation for the key scene. Selecting a parked preview unparks
and activates its retained surface synchronously; snapshot and identity work
never delay that pane-activation path.
An explicit, confirmed Kill Session action
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
Ghosthub supplies keepalives. Remote shell commands are one-shot; each retained
presentation owns its own transport-status-255 recovery, probe scheduling,
authentication and host-key escalation state, and attach-only client
replacement. Inactive presentations remain supervised. Tmux owns all windows,
panes, history, input, rendering, and server-side lifetime. Ghosthub
best-effort enables the exact POSIX session's `mouse` option before attachment
so wheel input reaches tmux copy mode under a vanilla configuration. This is a
shared session option visible to every client; Ghosthub does not replace tmux's
mouse bindings. Native Windows/psmux remains unchanged.

Cmd-D and Cmd-Shift-D provide Ghostty-style split-right and split-down actions,
also exposed in the File menu. A tmux attachment requires tmux 3.4 or newer.
Each explicit action runs `split-window -h` or `split-window -v` against the
active pane of the attachment's exact host and socket. The attachment retains
its resolved SSH configuration and effective endpoint, so a later SSH alias
edit cannot reroute a split. Each POSIX surface publishes its TTY under a unique
token; as the surface opens, Ghosthub finds that client by TTY and captures its
stable server, client, and session identity. Each split then uses one tmux
conditional to validate that identity and the active pane before mutating the
layout. This follows a session rename but rejects a replacement client or a
client switched to another session after binding. Requests
are serialized per attachment; detaching cancels the active command and queue.
Keyboard equivalents require effective terminal focus and no attached sheet;
clicking the File menu action remains an explicit request. This semantic routing
has a Herdr counterpart for version 0.8.0 or newer. Capability discovery binds
the resolved executable, SSH arguments, and exact running session socket to the
attachment. Each serialized request scrubs inherited Herdr control variables,
sets only that socket, and asks Herdr to split and focus right or down without a
pane identifier. Herdr's session-global focus remains authoritative; Ghosthub
does not inspect or rebuild its pane model. Detach drops queued requests and
late results. There is no stable Herdr session-generation or client identity,
so the constructive split accepts the documented same-name/socket replacement
limit rather than claiming tmux-strength identity protection. The focus premise
was verified against Herdr 0.8.0.

Tmux semantic routing is independent of the user's prefix and key tables.
Command failures appear
on the attachment rather than silently disappearing. Ghosthub does not maintain
a parallel pane model; tmux remains layout and process authority. Native Windows
psmux surfaces do not expose or intercept these split actions.

Ghosthub applies the selected Tmux Theme when it creates a new bare session.
Built-in themes provide fixed colors; Follow ghostty.conf uses the effective
foreground and background retained from libghostty's surface-scoped config
callback, including the active conditional light or dark theme. Until a surface
has delivered that state, no effective Follow ghostty.conf tmux style is
available.

The generated Ghosthub terminal config sets libghostty's minimum text contrast
to 3 so dark-oriented ANSI palettes remain legible when an existing session
uses a light background. This is a client-local rendering constraint and does
not modify tmux options or the colors seen by another attached client. An
explicit user value in `ghostty.conf` remains authoritative.

Existing sessions retain their own appearance by default; Ghosthub neither
places a client-local palette over them nor changes their tmux options. The
persistent shared-session override applies the selected effective style on
future attachments: built-in palettes within the attach command itself, and
Follow ghostty.conf one-shot and best-effort once the new surface has published
its resolved colors. The focused **Session -> Apply Theme to Current Session**
menu item and its command-palette counterpart apply the same style immediately
to the connected active workspace tmux attachment without reconnecting or
changing that preference. The target may be a selected unbound session but is
never a Console Panel terminal. Both paths reset status and message styles to
terminal defaults and supply the selected foreground and background to existing
windows in the exact session. Tmux shares the result with every attached client.
The best-effort styling can never prevent attachment. Native Windows/psmux
sessions do not offer either shared styling path. Tmux still owns all interaction
behavior. Other than enabling its session mouse option for POSIX attachments,
Ghosthub does not modify its prefix, key tables, mouse bindings, window/pane
commands, history, or layout.

An explicit New Tmux Session action is the sole boundary where Ghosthub
creates a bare tmux session itself. For a user-supplied exact name, local
presentation uses one atomic
`new-session -A` create-or-attach invocation so `destroy-unattached` cannot
remove a newly created session before the client arrives. Remote presentation
performs one idempotent, detached create-if-absent phase before ordinary
attachment. Once established, its native reconnect supervisor permanently
limits all later replacements to attach-only clients.
Configured POSIX SSH hosts may also persist ordered launch profiles, each with
a stable identifier, display name, and trusted user-authored shell command.
The selected profile becomes an optional field on the creation request; it is
not part of session identity, discovery, navigation, or restoration. Profile
creation replaces the detached remote phase with one PTY-backed atomic
`new-session -A` invocation whose initial pane runs the command. If that SSH
transport fails, Ghosthub probes the exact session: presence advances to the
ordinary attach-only loop, absence retries the initial invocation, and every
other result exits. Existing or discovered same-named sessions always attach
without the profile command.
Before opening an ordinary worktree, Ghosthub asks kwt to establish or repair
that exact path's canonical session without attaching. Kwt inventory includes
worktrees whose sessions are not currently running, so inventory membership is
not evidence that attach-only will succeed. Kwt owns any required layout and
environment bootstrap; Ghosthub then presents an ordinary tmux client. The
remote establishment phase runs once after its attachment is confirmed, and
transport reconnects remain attach-only. If transport interrupts an
unconfirmed kwt establishment, authoritative exact-session absence may rerun
that establishment because the remote command may never have executed.
Discovered sessions that are not bound to worktrees are always attach-only.

Ghosthub publishes the requested name optimistically. Reconciliation starts
only after the terminal runtime accepts the command, then checks direct tmux
discovery with bounded retries. The optimistic entry remains while the command
is still running; only an authoritative empty inventory after both retry
exhaustion and command termination may retire it. Confirmation permanently
demotes later retries to attach-only. Host endpoint changes and scene shutdown
cancel pending probes.

Each retained remote tmux presentation owns at most one native reconnect
supervisor. It uses the host's shared in-flight default-socket inventory probe,
or an exact headless `has-session` probe for a protected socket. Attempt starts
follow 1, 2, 4, 8, 16, and 30-second intervals, include probe runtime, and are
bounded by a 15-second probe deadline. Transport failures continue
automatically and **Reconnect Now** advances the existing schedule;
authentication or host-key failures pause it and route through native SSH
recovery. Exact absence ends an established presentation, while reachable
non-transport failures become an unable-to-attach state. Endpoint changes,
explicit closure, replacement presentations, and scene shutdown cancel stale
work. Navigation does not cancel recovery.
Each complete remote establishment or attachment command records its final
status through an app-owned per-launch temporary file because libghostty's
outer macOS login process does not reliably preserve a nested command's status.

## State Ownership

Kwt's project and worktree JSON surfaces are authoritative for workspace
identity and exact tmux session names. Direct tmux discovery is authoritative
for the remaining live sessions on each host and for the eventual result of an
explicit named-session creation request. A worktree open does not infer live
session state from kwt inventory: it uses kwt's exact-path start-only command
to converge the session before attachment.
Herdr's JSON session list is independently authoritative for running and
stopped Herdr sessions. Exit 127 means optional capability absence and emits no diagnostic;
malformed output or another failure produces only a host-scoped warning and
never changes tmux reachability, kwt availability, or blocking workspace state.
Zellij's unformatted session list is independently authoritative for active
Zellij sessions. Exited entries are excluded. Missing Zellij is silent, while
malformed output or another failure produces only a host-scoped warning.
Zellij fleet sweeps accumulate their host results and publish the completed
runtime inventory once. Tmux and Herdr publish host-scoped runtime results as
hosts complete. Session-only publication uses the runtime overlay, which cannot
reconcile kwt projects or worktrees and cannot normalize their paths. The full
overlay remains reserved for authoritative kwt changes. Application activation
starts neither inventory discovery nor process sampling; explicit refresh and
lifecycle reconciliation own those costs.

Ghosthub local persistence stores app-owned state:

- terminal presentation state
- selected worktree/window state
- settings that are explicitly native-app concerns
- configured SSH hosts and their launch profiles
- the anonymous telemetry installation UUID and last attempted activity day

Do not add database migrations before the first production release. Edit the
current schema, bootstrap paths, fixtures, and tests directly.

## Direction

Ghosthub should remain a native terminal client and session switcher: one
sidebar for tmux, Herdr, and Zellij fleets across a user's Macs, Linux hosts, and tailnet.
The native app owns discovery, native client presentation, and SSH reconnect
supervision. It does not reconstruct tmux, Herdr, or Zellij terminal state in Swift.
