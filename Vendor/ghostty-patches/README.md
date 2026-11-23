# Embedded libghostty source

`Vendor/ghostty.version.json` pins Ghostty 1.4.0 and Zig 0.17.0. Bootstrap
fetches that exact source commit and applies Ghosthub's integration patches in
`tools/libghostty_bootstrap.py`. Local builds and CI use the same compiler.

Ghostty 1.4.0 includes the memory and lifetime fixes previously backported to
1.3.1 (hidden-surface GPU cleanup and terminal page reclamation), so those
backports are gone. One small Ghosthub patch still keeps the presented
IOSurface alive while Core Animation retains it for hidden previews. Upstream
now normalizes static archives, applies its `libSystem` symbol overrides, and
exposes direct config-file loading through the C API; Ghosthub validates the
emitted archive without rebuilding it.

One unmerged upstream fix lives here as a unified diff:
`surface-teardown-drain.patch`
([ghostty-org/ghostty#14444](https://github.com/ghostty-org/ghostty/pull/14444)).
It keeps the app, renderer, and I/O mailboxes drained while a surface joins its
threads so closing a surface whose child is still writing cannot deadlock the
main thread. Bootstrap applies listed diffs with `git apply` before its string
patches. Remove the diff and its `UPSTREAM_SOURCE_PATCHES` entry once the
pinned Ghostty commit includes that fix.

The remaining patches cover Ghosthub's bundle and terminal identity, launcher
environment isolation, quiet macOS login, child process status, output
injection and child-write callbacks, clipboard classification and OSC 52 write
origin, disabled gettext linking, and an Apple Silicon-only XCFramework target.
Bumping the bootstrap schema invalidates cached artifacts whenever these
patches change.

When upgrading upstream Ghostty:

1. Compare the embedding header and linked dependencies.
2. Drop patches already shipped upstream, adapt the remaining ones, and bump
   the bootstrap schema.
3. Run the terminal regression gates in [AGENTS.md](../../AGENTS.md) and build
   both Debug and ReleaseFast variants.
4. Verify shell startup, paste confirmation, remote clipboard isolation,
   surface shutdown, and hidden previews against the built library.
