# Changelog

All notable changes to this project are documented here.

## [1.0.1] - 2026-07-08

### Fixed

- `zig build test` compiled the test binary but never executed it (the `test` step
  depended on the compile artifact instead of a run step), so CI had been green
  without running a single test
- Three tests that had never run were wrong once they did: the hardware type was
  asserted at header offset 0x10 (the low byte of the data length) instead of 0x14,
  the OPL3 test did not expect the 0x04 escape prefix for register 0x01, and the
  invalid-offset test assumed 32-bit `usize` overflow
- `vgmDataOffset` now rejects overflowing, sub-header (< 0x40), and past-EOF offsets
  itself instead of relying on the caller to range-check the result

### Documentation

- README describes the skip condition as implemented: the header clock fields decide,
  so a mixed VGM with both OPL and non-OPL chips still converts its OPL writes
- New "Playing the output" section pointing at the opal example player, including the
  DRO 0.1 versus 1.0 naming history so the two READMEs reconcile
- Added this changelog, CONTRIBUTING.md, and SECURITY.md

## [1.0.0] - 2026-07-06

### Added

- Converter from OPL-family VGM 1.50+ (and gzip-compressed VGZ) to DRO v0.1
  (`DBRAWOPL`), one `.dro` per input, batch capable
- Support for OPL2, dual OPL2, OPL (YM3526), Y8950, and OPL3 with both register banks
- Dual OPL2 detected via the VGM dual-chip clock flag and written as DRO hardware type
  dual OPL2, while dual OPL3 collapses onto one chip's two banks, as DRO cannot
  express it
- DRO encoding with bank-switch codes, the 0x04 escape for registers 0x00-0x04, and
  8/16-bit delay chunking
- Sample-to-millisecond timing with fractional carry so long songs do not drift
- Gzip inflate through `std.compress.flate` with no libc and no dependencies
- Bounds-checked parsing that rejects truncated files, unknown opcodes, and invalid
  header offsets instead of writing partial output
- Non-OPL VGMs are identified by chip name and skipped, and input is capped at
  64 MiB decompressed
- GitHub Actions workflows for Linux, macOS, and Windows running `zig fmt --check`,
  build, and tests, with status badges in the README
