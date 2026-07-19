# Contributing

Contributions are welcome. The project is small and intends to stay that way, so the best
contributions are the ones that make it more correct rather than merely larger.

## What fits

Conversion-accuracy fixes are the most valuable thing you can send, and they should come
with evidence. A VGM that converts wrongly, the DRO bytes you expected against the ones you
got, or a citation of the [VGM specification](https://vgmrips.net/wiki/VGM_Specification)
or the [DRO format page](https://moddingwiki.shikadi.net/wiki/DRO_Format) are all good
evidence. An opinion that another converter does it differently is a starting point, not
proof. The spec settles arguments. What vgz2dro itself writes, and why, is recorded in
[doc/dro-format.md](doc/dro-format.md).

Robustness fixes are close behind. The converter reads untrusted files and is expected to
reject malformed input with a clear error instead of writing a broken `.dro`. A crashing or
misbehaving input file attached to an issue is a perfectly good contribution on its own.

Build fixes, CI fixes, and documentation corrections are welcome too. If Linux, macOS, and
Windows all go green, you have not broken the world in any way we test for.

New features get a higher bar. The tool converts VGM to DRO and nothing else. A feature
that moves it toward being a general-purpose chiptune toolbox will be declined kindly.

## Building and testing

The README covers building. `zig build test` runs the unit tests, and the GitHub Actions
workflows run the format check, build, and tests on every push. Do the same before opening
a pull request, and add a test when you fix conversion behavior. This project has already
learned once what untested tests are worth.

## Style

`zig fmt` enforces the formatting, so run it and the argument is over (CI checks it).
Comment only what the code cannot say itself. A comment that narrates the line below it
will be asked to leave.

Zero dependencies is a feature, not an accident. The standard library has everything this
tool needs, so do not add packages.

## Licensing

The project is MIT and your contributions are accepted under the same terms.
