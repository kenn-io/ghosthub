# Ghosthub third-party notices

The release bundle includes the following source-derived or statically linked
components. The adjacent files contain their license text and attribution.
This inventory is maintained with Ghosthub's pinned Ghostty, Zig, GRDB, and kwt
revisions and is copied verbatim into `Ghosthub.app/Contents/Resources/Licenses`.

| Component | License file(s) |
| --- | --- |
| Ghostty / libghostty | `ghostty-MIT.txt` |
| GRDB.swift | `GRDB-MIT.txt` |
| kwt | `kwt-Apache-2.0.txt`, `kwt-NOTICE.txt` |
| Fantastty-derived terminal integration | `fantastty-MIT.txt` |
| Marked 15.0.7 | `Marked-MIT.txt` |
| Sparkle 2.9.4 | `Sparkle-LICENSE.txt` |
| Zig compiler runtime and standard library | `Zig-MIT.txt` |
| zlib | `zlib.txt` |
| libpng | `libpng.txt` |
| FreeType | `FreeType.txt`, `FreeType-FTL.txt`, `FreeType-BDF.txt`, `FreeType-PCF.txt`, `FreeType-HarfBuzz-Old-MIT.txt` |
| Oniguruma | `Oniguruma-BSD.txt` |
| glslang | `glslang.txt` |
| SPIRV-Cross | `SPIRV-Cross.txt` |
| Highway | `Highway-Apache-2.0.txt`, `Highway-BSD-3-Clause.txt` |
| simdutf | `simdutf-Apache-2.0.txt`, `simdutf-MIT.txt` |
| utfcpp | `utfcpp-BSL-1.0.txt` |
| Wuffs | `Wuffs.txt` |
| stb image and image resize | `stb-MIT.txt` |
| Dear ImGui | `Dear-ImGui-MIT.txt` |
| Dear Bindings | `Dear-Bindings.txt` |
| libxev | `libxev-MIT.txt` |
| z2d | `z2d-MPL-2.0.txt`, `z2d-NOTICE.txt` |
| zf | `zf-MIT.txt` |
| zig-objc | `zig-objc-MIT.txt` |
| uucode and generated Unicode data | `uucode-MIT.txt`, `uucode-Bjoern-Hoehrmann-MIT.txt`, `Unicode-Data.txt` |
| Symbols Nerd Font | `Symbols-Nerd-Font-MIT.txt` |
| JetBrains Mono | `JetBrains-Mono-OFL-1.1.txt` |

Portions of this software are copyright © 2023 The FreeType Project
(www.freetype.org). All rights reserved.

Ghosthub builds embedded libghostty with internationalization disabled and
patches its dependency graph so the otherwise statically linked GNU
libintl/gettext implementation is excluded. Ghosthub does not distribute that
component.
