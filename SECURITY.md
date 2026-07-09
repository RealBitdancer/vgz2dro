# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| latest main | yes |
| 1.x releases | yes |
| anything older | no |

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's security advisories. Open the Security tab
of this repository and choose "Report a vulnerability". Please do not open a public issue
for something exploitable.

This is a spare time project with one maintainer, so the honest promise is best effort. You
can expect an acknowledgment within a week and a fix as fast as severity warrants.

## Scope

The attack surface is file parsing. The converter reads untrusted VGM and gzip-compressed
VGZ files, and the parser is written to treat its input with suspicion: bounds-checked
reads, overflow-checked arithmetic, a 64 MiB decompression cap, and release builds default
to ReleaseSafe so the safety checks stay on. Malformed input should produce a clear refusal
and a nonzero exit code, never memory corruption or a runaway process. If you find an input
that does otherwise, that is exactly the report we want.

Gzip inflation uses `std.compress.flate` from the Zig standard library. Vulnerabilities
there belong upstream at https://github.com/ziglang/zig, though a note here is welcome if
this tool is affected.
