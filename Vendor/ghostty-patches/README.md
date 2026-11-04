# Embedded libghostty source

`Vendor/ghostty.version.json` pins Ghostty 1.4.0 and Zig 0.17.0. The bootstrap
fetches that exact source revision and applies Ghosthub's integration changes
in `tools/libghostty_bootstrap.py`. Local builds and CI use the same compiler.

Ghostty 1.4.0 includes the memory and lifetime fixes previously backported to
1.3.1, including hidden-surface GPU cleanup and terminal page reclamation.
Those backports are no longer applied. A small Ghosthub patch still preserves
the presented IOSurface while Core Animation retains it for hidden previews.
Upstream now normalizes static archives and applies its libSystem symbol
overrides; Ghosthub validates the emitted archive without rebuilding it.
Direct config-file loading also uses the upstream C API.

Ghosthub also carries one unmerged upstream fix as a unified diff in this
directory. `surface-teardown-drain.patch` is
[ghostty-org/ghostty#14444](https://github.com/ghostty-org/ghostty/pull/14444).
It keeps the app, renderer, and io mailboxes drained while a surface joins its
threads. Without it, closing a surface whose child is still writing can block
the main thread forever. The bootstrap applies listed diffs with `git apply`
before the string patches below. Remove the diff and its
`UPSTREAM_SOURCE_PATCHES` entry once the pinned revision includes the fix.

The remaining patches provide Ghosthub's bundle and terminal identity,
launcher environment isolation, quiet macOS login, child process status,
output injection and child-write callbacks, clipboard request classification
and OSC 52 write origin, disabled gettext linking, and an Apple Silicon-only
XCFramework target. The bootstrap schema invalidates cached artifacts whenever
these patches change.

For an upstream update, compare the embedding header and linked dependencies,
remove patches already supplied upstream, adapt the remaining patches, and
bump the bootstrap schema. Run the terminal regression gates in
[AGENTS.md](../../AGENTS.md), then build both Debug and ReleaseFast variants.
Check shell startup, paste confirmation, remote clipboard isolation, surface
shutdown, and hidden previews against the compiled library.
