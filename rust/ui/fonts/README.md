# Linux fonts

The Linux executable embeds these unmodified TrueType faces before GPUI
measures or draws text. Inter supplies UI labels; JetBrains Mono supplies the
default terminal. Explicit terminal font preferences still use the chosen face.

| Family | Upstream release | Included styles | License |
| --- | --- | --- | --- |
| Inter | [4.1](https://github.com/rsms/inter/releases/tag/v4.1) | Regular, SemiBold, Bold | [SIL OFL 1.1](../../../LICENSES/Inter-OFL-1.1.txt) |
| JetBrains Mono | [2.304](https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304) | Regular, Bold, Italic, Bold Italic | [SIL OFL 1.1](../../../LICENSES/JetBrains-Mono-OFL-1.1.txt) |

Source archive SHA-256 values:

```text
9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e  Inter-4.1.zip
6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf  JetBrainsMono-2.304.zip
```

To update, replace the named faces from the upstream release archives, retain
their license notices, and update this provenance. Run `make rust-check` and
`xvfb-run -a make rust-test-fonts-live`, then inspect the native sidebar,
Settings, and terminal in a fresh development instance.
