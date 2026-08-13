# Adaptive Session Preview Height Design

## Outcome

Opened tmux preview tiles preserve the captured terminal's aspect ratio whenever
it is between 4:3 and 2:1. Taller and wider surfaces clamp to those limits and
use only the remaining minimal letterboxing. Tiles without a captured frame
remain 16:10.

## Design

The snapshotter reads the IOSurface dimensions, clamps their aspect ratio, and
renders a 320-pixel-wide thumbnail at the matching height. The returned image
therefore carries the tile's intended aspect ratio without adding another state
field. The SwiftUI tile derives its aspect ratio from that image, while the
sidebar stops imposing a fixed 16:10 ratio around the tile.

The snapshot remains a complete-frame image. It never crops terminal content,
changes the terminal grid, reparents the active surface, or creates another
client. The existing IOSurface generation fence and capture-token semantics do
not change.

## Verification

Pure layout tests cover the 4:3 lower bound, 2:1 upper bound, in-range ratios,
and 16:10 placeholder fallback. AppKit snapshot coverage verifies that an
in-range source produces a matching thumbnail size without changing the hosted
surface. The full Swift, essential workflow, docs, formatting, and build gates
remain required.
