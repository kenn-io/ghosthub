# Compact Homepage Hero

## Context

The Homebrew install control introduced in `6e147dc` correctly made the
terminal-native install path primary, but it removed the homepage link to the
Guide and added enough vertical space to push the product screenshot farther
down the first viewport.

## Design

Keep the Homebrew command bubble as the hero's only primary control. Restore a
`Learn More` link to `/guide/` beside the existing DMG fallback in a compact
secondary row beneath the command. The DMG fallback remains visually quiet and
the Guide link may use the accent color, but neither receives the weight,
border, or shadow of the command bubble.

Expose the extra homepage action through an optional secondary-action slot on
`InstallCommand`. The Guide's existing use of the component supplies no slot,
so it continues to show only the Homebrew command and DMG fallback rather than
linking back to itself.

Tighten the hero's vertical rhythm by modestly reducing the space below its
description and above the screenshot. Preserve the current copy-feedback
region and all install-command behavior. On narrow screens, the secondary links
may wrap as a centered row without overflowing or displacing the command.

## Validation

Add a focused component-rendering test that verifies the homepage variant
contains both the primary Homebrew command and the Guide action while the base
install component omits the optional action. Do not encode exact CSS values in
tests. Run the website type check, lint, unit tests, and production build.

No Guide copy, application behavior, screenshot assets, or deployment behavior
changes as part of this work.
