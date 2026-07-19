# DRO format notes

What vgz2dro writes, why it writes it that way, and the traps that history has left in
the format. The authoritative reference is the
[DRO format page](https://moddingwiki.shikadi.net/wiki/DRO_Format) on the DOS Game
Modding Wiki. These notes record the parts that matter for this converter.

## The header

vgz2dro emits DRO v0.1 with the 24-byte header:

| Offset | Size | Field | Value written |
|-------:|-----:|-------|---------------|
| 0x00 | 8 | signature | `DBRAWOPL` |
| 0x08 | 4 | version | `0x00010000` (bytes `00 00 01 00`) |
| 0x0C | 4 | length in milliseconds | total of all delays |
| 0x10 | 4 | length in bytes | size of the command stream |
| 0x14 | 1 | hardware type | 0 = OPL2, 1 = OPL3, 2 = Dual OPL2 |
| 0x15 | 3 | padding | always zero, see below |

All multi-byte fields are little endian. The command stream follows at offset 0x18.

## The version-name confusion

The layout above was called v1.0 by DOSBox before 0.73 and v0.1 after, because 0.73
swapped the meaning of the two 16-bit halves of the version field when it introduced
the incompatible v2.0 packing. The bytes are identical either way: the 16-bit word at
offset 8 is zero and the word at offset 10 is one. Readers that "require DRO version 1"
(opal's player, AdPlug) check exactly that zero word, and vgz2dro's output passes.

## The early 21-byte header

The earliest DOSBox builds wrote the hardware type as a single byte, giving a 21-byte
header with no padding. Later builds widened the field to 32 bits. Readers distinguish
the two by inspecting the three bytes after the hardware type: nonzero bytes mean the
short header, because in those files command data already occupies that space. AdPlug
introduced this heuristic and opal's player adopted it in release 1.0.2.

The consequence for a writer is simple but strict: the padding must be zero. A writer
that leaves junk there would have its files parsed as early-header files, with the
padding bytes executed as commands and the whole stream desynchronized by three bytes.
A unit test in `src/main.zig` pins this, so a regression cannot pass CI.

## The command stream

| Encoding | Meaning |
|----------|---------|
| `00 NN` | delay NN+1 ms (1 to 256) |
| `01 LL HH` | delay (HH:LL)+1 ms (1 to 65536) |
| `02` | select register bank 0 (OPL3 port 0, or Dual OPL2 chip 0) |
| `03` | select register bank 1 (OPL3 port 1, or Dual OPL2 chip 1) |
| `04 RR VV` | escaped write: register RR gets value VV, needed for RR 0x00 to 0x04 |
| `RR VV` | write register RR (0x05 to 0xFF) in the current bank |

Both delay encodings store the value minus one, so a stored zero means one
millisecond. Playback starts in bank 0, which matches vgz2dro's initial state.

## Timing

VGM logs time in samples at 44100 Hz, DRO in whole milliseconds. One sample is about
0.0227 ms, so naive rounding per delay would accumulate audible drift over a long
song. vgz2dro converts with a fractional-millisecond carry: each flush emits the whole
milliseconds and keeps the remainder for the next delay. The song end can be up to one
millisecond early, but never drifts.

## Hardware type mapping

| VGM source | DRO hardware type |
|------------|-------------------|
| OPL2, OPL (YM3526), Y8950 | 0 (OPL2) |
| OPL3 | 1 (OPL3) |
| Dual OPL2 (dual-chip flag set) | 2 (Dual OPL2) |

DRO has no types for YM3526 or Y8950, so they ship as OPL2, which is register
compatible for everything except the Y8950's ADPCM unit. Dual OPL3 does not exist in
DRO v0.1 at all. vgz2dro folds a second OPL3 chip onto the two banks of the first,
which preserves the writes but cannot be a faithful rendition.
