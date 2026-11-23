# Launch-profile documentation

The public [Launch profiles guide](https://ghosthub.ai/docs/launch-profiles/)
owns setup instructions, supported hosts, and interrupted-command behavior.
Profiles work on macOS and Linux SSH hosts; the local Mac and native Windows
hosts do not show the profile picker.

## Reproduce the screenshot

Run the checked-in renderer to host the real SwiftUI sheet with a deterministic
**Container shell** profile and capture it without launching or activating the
app:

```sh
website/demo/render-launch-profile.sh
```

Output defaults to
`/private/tmp/ghosthub-doc-assets/docs-launch-profiles.png`. The published PNG
lives on the orphan `website-assets` branch so large image binaries stay out of
app history.
