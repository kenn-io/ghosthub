# Ghostty Memory Backports

Ghosthub applies these patches in the order declared by `GHOSTTY_BACKPORTS` to
its clean, pinned Ghostty `v1.3.1` checkout. PR #220 separately backports ten
upstream lifetime fixes through `apply_upstream_lifetime_backports`; the patches
here are the additional long-lived terminal-memory fixes not included there.

| Patch | Upstream commit | Upstream PR | Purpose |
| --- | --- | --- | --- |
| `0001` | `c4e16970a803b170e352432424f44192cb59f3ac` | [#14017](https://github.com/ghostty-org/ghostty/pull/14017) | Release Metal and IOSurface resources while a terminal surface is hidden. |
| `0003` | `16e4b5e98f10f255bdda934a61ff41e9b3a849c7` | [#13241](https://github.com/ghostty-org/ghostty/pull/13241) | Track terminal page ownership explicitly so pooled and heap-backed pages are reclaimed safely. |
| `0004` | `896aca499001f42e132f456ebc9cdfed616cf1fb` | [#13245](https://github.com/ghostty-org/ghostty/pull/13245) | Return free-listed terminal page memory to macOS or Linux instead of retaining the high-water footprint. |

The first patch is adapted to the semaphore and display-link APIs in `v1.3.1`.
The page-list source changes match their upstream commits; the fourth patch omits
unrelated test context that landed between the pinned release and that commit.

When the pinned Ghostty release contains these fixes, remove the corresponding
patches, update `GHOSTTY_BACKPORTS`, and bump `GHOSTHUB_BOOTSTRAP_VERSION`.
