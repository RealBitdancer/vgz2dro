# vgz2dro

Convert OPL-family **VGM**/**VGZ** logs to **DRO** (DOSBox Raw OPL).

[![Linux](https://github.com/RealBitdancer/vgz2dro/actions/workflows/linux.yml/badge.svg)](https://github.com/RealBitdancer/vgz2dro/actions/workflows/linux.yml)
[![macOS](https://github.com/RealBitdancer/vgz2dro/actions/workflows/macos.yml/badge.svg)](https://github.com/RealBitdancer/vgz2dro/actions/workflows/macos.yml)
[![Windows](https://github.com/RealBitdancer/vgz2dro/actions/workflows/windows.yml/badge.svg)](https://github.com/RealBitdancer/vgz2dro/actions/workflows/windows.yml)

## What it does

`vgz2dro` takes a VGM register log (or its gzip-compressed `.vgz` form) and rewrites
the OPL chip writes as a DRO v0.1 file ([`DBRAWOPL`](https://moddingwiki.shikadi.net/wiki/DRO_Format)),
one `.dro` per input. DRO stores
**both** OPL register banks, so OPL3 songs convert losslessly, unlike IMF, which is
OPL2-only.

## Why it exists

I needed to convert OPL music from [opl.wafflenet.com](https://opl.wafflenet.com/)
into DRO for the soundtracks of some retro-game rewrites, and didn't want to drag a
heavy toolchain or a pile of C/C++/Rust dependencies into such a small job. Zig hits
the sweet spot here: a single, dependency-free, cross-platform binary. The gzip
inflate uses `std.compress.flate` from the Zig standard library, and **no libc is
linked**. The resulting executable depends only on core OS libraries (no zlib, no
C runtime).

## Supported input

Any OPL-family chip is converted:

| Chip | VGM source |
|------|-----------|
| OPL2 (YM3812) | bank 0 |
| Dual OPL2 (YM3812 ×2) | chip 0 + chip 1 |
| OPL (YM3526) | bank 0 |
| Y8950 | bank 0 |
| OPL3 (YMF262) | banks 0 + 1 |

Dual OPL2 VGMs (Sound Blaster Pro and similar) are detected via the dual-chip flag
in the VGM header and written with DRO hardware type **Dual OPL2**. Dual OPL3 (two
YMF262 chips) is not fully representable in DRO v0.1; second-chip writes are captured
but may not replay correctly on all players.

If the VGM header lists no OPL-family chip clock (YM2612, SN76489, OPL4 PCM, and so
on), the file is reported and skipped rather than turned into an empty or misleading
`.dro`. Truncated files, unknown opcodes, and invalid header offsets are rejected
with an error instead of a partial output.

## Building

Requires **Zig 0.17.0-dev** (see `.minimum_zig_version` in `build.zig.zon`).

```sh
zig build                 # -> zig-out/bin/vgz2dro[.exe]
zig build test            # run unit tests
```

## Usage

```sh
vgz2dro <song.vgz|.vgm> [more files ...]
```

Each input writes a sibling `FILE.dro`. Multiple files convert in one invocation.

```sh
# via the build system
zig build run -- song.vgz

# or the built binary directly
zig-out/bin/vgz2dro song1.vgz song2.vgm
```

Per file, vgz2dro prints the detected chip, OPL register-write count, song length, and
output size:

```
vgz2dro: song.vgz -> song.dro  [OPL3, 14820 writes, 92.3 s, 31104 bytes]
vgz2dro: 1 converted, 0 skipped/failed
```

Input is limited to **64 MiB** of decompressed VGM data.

## Playing the output

The files this tool produces are DRO v0.1, the original DOSBox layout rather than the
later v2.0 packing. The same layout was called v1.0 before DOSBox 0.73 swapped the
version field names, so some tools (opal's player among them) say "DRO version 1".
Either name means the same bytes. One straightforward way to hear them is the example
player shipped with [opal](https://github.com/RealBitdancer/opal), an OPL2/OPL3
emulator:

```sh
player song.dro
```

Build instructions live in that repository. The player also accepts HSC and IMF/WLF,
but for the output of `vgz2dro` the DRO path is the one that matters.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Bitdancer
(github.com/RealBitdancer).
