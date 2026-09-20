# Launch-profile documentation

The public [Launch profiles guide](https://ghosthub.ai/docs/launch-profiles/)
owns setup instructions, supported hosts, and interrupted-command behavior.
Profiles are configured for macOS and Linux SSH hosts; the local Mac and native
Windows hosts do not offer the profile picker.

## Reproduce the screenshot

The checked-in renderer hosts the real SwiftUI sheet with a deterministic
**Container shell** profile and captures it without launching or activating the
app:

```sh
website/demo/render-launch-profile.sh
```

The generated image defaults to
`/private/tmp/ghosthub-doc-assets/docs-launch-profiles.png`. The published copy
lives on the orphan `website-assets` branch so the documentation does not add
large binaries to the application history.
