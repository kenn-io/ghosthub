# Linux fonts

The Linux binary embeds these unmodified TrueType fonts before GPUI measures or
draws text: Inter for UI labels, and JetBrains Mono for the default terminal
font (explicit user font choices still take priority).

| Family | Upstream release | Included styles | License |
| --- | --- | --- | --- |
| Inter | [4.1](https://github.com/rsms/inter/releases/tag/v4.1) | Regular, SemiBold, Bold | [SIL OFL 1.1](../../../LICENSES/Inter-OFL-1.1.txt) |
| JetBrains Mono | [2.304](https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304) | Regular, Bold, Italic, Bold Italic | [SIL OFL 1.1](../../../LICENSES/JetBrains-Mono-OFL-1.1.txt) |

Source archive SHA-256 checksums:

```text
9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e  Inter-4.1.zip
6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf  JetBrainsMono-2.304.zip
```

To update these fonts, replace the files from upstream release archives, keep
their license notices, update the table and checksums above, run
`make rust-check` and `xvfb-run -a make rust-test-fonts-live`, and visually
inspect the sidebar, Settings, and terminal in a fresh dev run.
