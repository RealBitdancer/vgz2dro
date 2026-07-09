//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//
// vgz2dro - convert OPL-family VGM (or gzip-compressed VGZ) logs to DRO.
//
// Output is DRO v0.1 ("DBRAWOPL", version 0x10000):
//     0x00 dd     delay dd+1 ms        0x02 / 0x03  select bank 0 / 1
//     0x01 ll hh  delay (hh<<8|ll)+1   0x04 rr vv   escape: write reg 0x00-0x04
//     rr vv       write reg 0x05-0xFF in the current bank
// VGM time (44100 Hz samples) is converted to DRO milliseconds with fractional
// carry so timing does not drift.
//
// Usage:  vgz2dro <song.vgz|.vgm> [more files ...]   (writes FILE.dro per input)
//

const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;
const build_options = @import("build_options");

const VGM_RATE: f64 = 44100.0;
const MAX_VGM_BYTES: usize = 64 * 1024 * 1024;

const ConvertError = error{
    Truncated,
    UnknownOpcode,
    DelayTooLong,
    OutOfMemory,
};

fn u16le(d: []const u8, p: usize) u16 {
    return @as(u16, d[p]) | (@as(u16, d[p + 1]) << 8);
}
fn u32le(d: []const u8, p: usize) u32 {
    return @as(u32, d[p]) | (@as(u32, d[p + 1]) << 8) |
        (@as(u32, d[p + 2]) << 16) | (@as(u32, d[p + 3]) << 24);
}

fn writeU32At(buf: []u8, p: usize, v: u32) void {
    buf[p] = @intCast(v & 0xff);
    buf[p + 1] = @intCast((v >> 8) & 0xff);
    buf[p + 2] = @intCast((v >> 16) & 0xff);
    buf[p + 3] = @intCast((v >> 24) & 0xff);
}

fn advance(p: *usize, n: usize, delta: usize) bool {
    const np, const overflow = @addWithOverflow(p.*, delta);
    if (overflow != 0 or np > n) return false;
    p.* = np;
    return true;
}

fn u32Fit(v: u64) ?u32 {
    if (v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

const Dro = struct {
    data: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    cur_bank: i32 = 0,
    carry: f64 = 0, // fractional-millisecond carry
    pending: f64 = 0, // VGM samples accumulated since the last write
    total_ms: u64 = 0,

    fn emitDelay(self: *Dro, ms_in: u32) !void {
        var ms = ms_in;
        self.total_ms += ms;
        while (ms > 0) {
            if (ms <= 256) {
                try self.data.append(self.gpa, 0x00);
                try self.data.append(self.gpa, @intCast(ms - 1));
                ms = 0;
            } else {
                const chunk = @min(ms, 65536);
                const v: u16 = @intCast(chunk - 1);
                try self.data.append(self.gpa, 0x01);
                try self.data.append(self.gpa, @intCast(v & 0xff));
                try self.data.append(self.gpa, @intCast(v >> 8));
                ms -= chunk;
            }
        }
    }

    fn flush(self: *Dro) !void {
        const t = self.pending * (1000.0 / VGM_RATE) + self.carry;
        if (t >= 1 << 32) return error.DelayTooLong;
        const whole: u32 = @intFromFloat(t);
        self.carry = t - @as(f64, @floatFromInt(whole));
        self.pending = 0;
        if (whole > 0) try self.emitDelay(whole);
    }

    fn write(self: *Dro, bank: i32, reg: u8, val: u8) !void {
        try self.flush(); // elapsed time before this write
        if (bank != self.cur_bank) {
            try self.data.append(self.gpa, if (bank != 0) @as(u8, 0x03) else 0x02);
            self.cur_bank = bank;
        }
        if (reg <= 0x04) try self.data.append(self.gpa, 0x04); // escape low registers
        try self.data.append(self.gpa, reg);
        try self.data.append(self.gpa, val);
    }
};

fn convert(d: []const u8, off: usize, m: *Dro) ConvertError!u64 {
    var p = off;
    const n = d.len;
    var writes: u64 = 0;

    while (p < n) {
        const c = d[p];
        var wait: i64 = 0;

        switch (c) {
            0x66 => break,
            0x67 => {
                if (p + 7 > n) return error.Truncated;
                const size = u32le(d, p + 3);
                const skip, const overflow = @addWithOverflow(@as(usize, 7), @as(usize, size));
                if (overflow != 0) return error.Truncated;
                if (!advance(&p, n, skip)) return error.Truncated;
                continue;
            },
            0x68 => {
                if (!advance(&p, n, 12)) return error.Truncated;
                continue;
            },
            0x61 => {
                if (p + 3 > n) return error.Truncated;
                wait = u16le(d, p + 1);
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            0x62 => {
                wait = 735;
                if (!advance(&p, n, 1)) return error.Truncated;
            },
            0x63 => {
                wait = 882;
                if (!advance(&p, n, 1)) return error.Truncated;
            },
            0x70...0x7f => {
                wait = @as(i64, c & 0x0f) + 1;
                if (!advance(&p, n, 1)) return error.Truncated;
            },
            // YM2612 DAC data-bank write + wait n samples (not n+1); OPL output keeps timing only.
            0x80...0x8f => {
                wait = @as(i64, c & 0x0f);
                if (!advance(&p, n, 1)) return error.Truncated;
            },
            // OPL bank 0 / chip 0: OPL3 port 0, OPL2, OPL (YM3526), Y8950
            0x5a, 0x5b, 0x5c, 0x5e => {
                if (p + 3 > n) return error.Truncated;
                try m.write(0, d[p + 1], d[p + 2]);
                writes += 1;
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            // OPL3 bank 1 / port 1 (chip 0)
            0x5f => {
                if (p + 3 > n) return error.Truncated;
                try m.write(1, d[p + 1], d[p + 2]);
                writes += 1;
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            // Dual-chip OPL2-family (YM3812 / YM3526 / Y8950), chip 1
            0xaa, 0xab, 0xac => {
                if (p + 3 > n) return error.Truncated;
                try m.write(1, d[p + 1], d[p + 2]);
                writes += 1;
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            // Dual-chip OPL3 port 0 / port 1 (chip 1; DRO has no dual-OPL3 mode)
            0xae => {
                if (p + 3 > n) return error.Truncated;
                try m.write(0, d[p + 1], d[p + 2]);
                writes += 1;
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            0xaf => {
                if (p + 3 > n) return error.Truncated;
                try m.write(1, d[p + 1], d[p + 2]);
                writes += 1;
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            0x51...0x59, 0x5d => {
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            0x4f, 0x50 => {
                if (!advance(&p, n, 2)) return error.Truncated;
            },
            0x40...0x4e => {
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            0x30...0x3f => {
                if (!advance(&p, n, 2)) return error.Truncated;
            },
            0x90, 0x91, 0x95 => {
                if (!advance(&p, n, 5)) return error.Truncated;
            },
            0x92 => {
                if (!advance(&p, n, 6)) return error.Truncated;
            },
            0x93 => {
                if (!advance(&p, n, 11)) return error.Truncated;
            },
            0x94 => {
                if (!advance(&p, n, 2)) return error.Truncated;
            },
            0xa0...0xa9, 0xad, 0xb0...0xbf => {
                if (!advance(&p, n, 3)) return error.Truncated;
            },
            0xc0...0xdf => {
                if (!advance(&p, n, 4)) return error.Truncated;
            },
            0xe0...0xff => {
                if (!advance(&p, n, 5)) return error.Truncated;
            },
            else => return error.UnknownOpcode,
        }

        if (wait > 0) m.pending += @floatFromInt(wait);
    }

    try m.flush();
    return writes;
}

fn identify(d: []const u8, off: usize) []const u8 {
    const Entry = struct { o: usize, n: []const u8 };
    const table = [_]Entry{
        .{ .o = 0x2c, .n = "YM2612 (Genesis FM)" },
        .{ .o = 0x0c, .n = "SN76489 (PSG)" },
        .{ .o = 0x10, .n = "YM2413 (OPLL)" },
        .{ .o = 0x30, .n = "YM2151" },
        .{ .o = 0x60, .n = "YMF278B (OPL4)" },
        .{ .o = 0x64, .n = "YMF271" },
        .{ .o = 0x68, .n = "YMZ280B" },
        .{ .o = 0x44, .n = "YM2203" },
        .{ .o = 0x48, .n = "YM2608" },
        .{ .o = 0x4c, .n = "YM2610" },
        .{ .o = 0x80, .n = "AY8910" },
    };
    for (table) |e| {
        if (e.o + 4 <= off and (u32le(d, e.o) & 0x3fff_ffff) != 0) return e.n;
    }
    return "no recognised chip";
}

fn vgmDataOffset(d: []const u8) ?usize {
    if (d.len < 0x40 or !std.mem.eql(u8, d[0..4], "Vgm ")) return null;
    const ver = u32le(d, 0x08);
    if (ver >= 0x150 and u32le(d, 0x34) != 0) {
        const rel = u32le(d, 0x34);
        const off, const overflow = @addWithOverflow(@as(usize, 0x34), @as(usize, rel));
        if (overflow != 0 or off < 0x40 or off > d.len) return null;
        return off;
    }
    return 0x40;
}

const Clk = struct {
    fn f(dd: []const u8, o: usize, of: usize) u32 {
        return if (of >= o + 4) (u32le(dd, o) & 0x3fff_ffff) else 0;
    }
    fn clockRaw(dd: []const u8, o: usize, of: usize) u32 {
        return if (of >= o + 4) u32le(dd, o) else 0;
    }
};

fn oplInfo(d: []const u8, off: usize) struct {
    opl2: u32,
    oplm: u32,
    y8950: u32,
    opl3: u32,
    dual_opl2: bool,
    hw_type: u8,
    label: []const u8,
} {
    const opl2 = Clk.f(d, 0x50, off);
    const oplm = Clk.f(d, 0x54, off);
    const y8950 = Clk.f(d, 0x58, off);
    const opl3 = Clk.f(d, 0x5c, off);
    const dual_opl2 = opl3 == 0 and
        ((Clk.clockRaw(d, 0x50, off) & 0x4000_0000) != 0 or
            (Clk.clockRaw(d, 0x54, off) & 0x4000_0000) != 0 or
            (Clk.clockRaw(d, 0x58, off) & 0x4000_0000) != 0);
    const hw_type: u8 = if (dual_opl2) 2 else if (opl3 != 0) 1 else 0;
    const label = if (dual_opl2)
        "Dual OPL2"
    else if (opl3 != 0)
        "OPL3"
    else if (opl2 != 0)
        "OPL2"
    else if (oplm != 0)
        "OPL (YM3526)"
    else
        "Y8950";
    return .{
        .opl2 = opl2,
        .oplm = oplm,
        .y8950 = y8950,
        .opl3 = opl3,
        .dual_opl2 = dual_opl2,
        .hw_type = hw_type,
        .label = label,
    };
}

fn appendU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    try list.append(gpa, @intCast(v & 0xff));
    try list.append(gpa, @intCast((v >> 8) & 0xff));
    try list.append(gpa, @intCast((v >> 16) & 0xff));
    try list.append(gpa, @intCast((v >> 24) & 0xff));
}

fn buildDro(gpa: std.mem.Allocator, m: *const Dro, hw_type: u8) ![]u8 {
    const ms_u32 = u32Fit(m.total_ms) orelse return error.OutputTooLarge;
    const data_u32 = u32Fit(m.data.items.len) orelse return error.OutputTooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "DBRAWOPL");
    try appendU32(&out, gpa, 0x0001_0000); // DRO v0.1
    try appendU32(&out, gpa, ms_u32);
    try appendU32(&out, gpa, data_u32);
    try out.append(gpa, hw_type); // 0=OPL2, 1=OPL3, 2=Dual OPL2
    try out.appendSlice(gpa, &[_]u8{ 0, 0, 0 });
    try out.appendSlice(gpa, m.data.items);
    return out.toOwnedSlice(gpa);
}

fn replaceExt(gpa: std.mem.Allocator, in_path: []const u8) ![]u8 {
    var cut = in_path.len;
    var i = in_path.len;
    while (i > 0) {
        i -= 1;
        const ch = in_path[i];
        if (ch == '.') {
            cut = i;
            break;
        }
        if (ch == '/' or ch == '\\') break;
    }
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    try result.appendSlice(gpa, in_path[0..cut]);
    try result.appendSlice(gpa, ".dro");
    return result.toOwnedSlice(gpa);
}

fn process(io: Io, gpa: std.mem.Allocator, stdout: *Io.Writer, in_path: []const u8) bool {
    const dir = Io.Dir.cwd();

    const raw = dir.readFileAlloc(io, in_path, gpa, .limited(MAX_VGM_BYTES)) catch |err| {
        if (err == error.StreamTooLong) {
            std.debug.print("vgz2dro: {s}: file too large (max {d} MiB decompressed)\n", .{
                in_path, MAX_VGM_BYTES / (1024 * 1024),
            });
        } else {
            std.debug.print("vgz2dro: {s}: cannot read\n", .{in_path});
        }
        return false;
    };
    defer gpa.free(raw);

    // Inflate if gzip (.vgz); plain .vgm passes through.
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var d: []const u8 = raw;
    if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) {
        var in: Io.Reader = .fixed(raw);
        var win: [flate.max_window_len]u8 = undefined;
        var dec: flate.Decompress = .init(&in, .gzip, &win);
        var total: usize = 0;
        while (true) {
            if (total > MAX_VGM_BYTES) {
                std.debug.print("vgz2dro: {s}: decompressed data too large (max {d} MiB)\n", .{
                    in_path, MAX_VGM_BYTES / (1024 * 1024),
                });
                return false;
            }
            total += dec.reader.stream(&aw.writer, .limited(MAX_VGM_BYTES + 1 - total)) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.debug.print("vgz2dro: {s}: gzip decompress failed\n", .{in_path});
                    return false;
                },
            };
        }
        d = aw.written();
    }

    if (d.len < 0x40 or !std.mem.eql(u8, d[0..4], "Vgm ")) {
        std.debug.print("vgz2dro: {s}: not a VGM file\n", .{in_path});
        return false;
    }

    const off = vgmDataOffset(d) orelse {
        std.debug.print("vgz2dro: {s}: invalid VGM data offset\n", .{in_path});
        return false;
    };

    const info = oplInfo(d, off);
    if (info.opl2 == 0 and info.oplm == 0 and info.y8950 == 0 and info.opl3 == 0) {
        std.debug.print(
            "vgz2dro: {s}: not an OPL-family VGM (chip: {s}) - skipped\n",
            .{ in_path, identify(d, off) },
        );
        return false;
    }

    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    const writes = convert(d, off, &m) catch |err| switch (err) {
        error.Truncated => {
            std.debug.print("vgz2dro: {s}: truncated or incomplete VGM data\n", .{in_path});
            return false;
        },
        error.UnknownOpcode => {
            std.debug.print("vgz2dro: {s}: unknown VGM opcode\n", .{in_path});
            return false;
        },
        error.DelayTooLong => {
            std.debug.print("vgz2dro: {s}: delay exceeds DRO limits\n", .{in_path});
            return false;
        },
        error.OutOfMemory => {
            std.debug.print("vgz2dro: {s}: out of memory during conversion\n", .{in_path});
            return false;
        },
    };

    const out = buildDro(gpa, &m, info.hw_type) catch |err| switch (err) {
        error.OutputTooLarge => {
            std.debug.print("vgz2dro: {s}: output too large for DRO header\n", .{in_path});
            return false;
        },
        else => {
            std.debug.print("vgz2dro: {s}: out of memory building output\n", .{in_path});
            return false;
        },
    };
    defer gpa.free(out);

    const out_path = replaceExt(gpa, in_path) catch {
        std.debug.print("vgz2dro: {s}: out of memory\n", .{in_path});
        return false;
    };
    defer gpa.free(out_path);

    dir.writeFile(io, .{ .sub_path = out_path, .data = out }) catch {
        std.debug.print("vgz2dro: {s}: cannot write\n", .{out_path});
        return false;
    };

    stdout.print("vgz2dro: {s} -> {s}  [{s}, {d} writes, {d:.1} s, {d} bytes]\n", .{
        in_path,
        out_path,
        info.label,
        writes,
        @as(f64, @floatFromInt(m.total_ms)) / 1000.0,
        out.len,
    }) catch {};
    return true;
}

const Cmd = enum { version, help };

const cmds = std.StaticStringMap(Cmd).initComptime(.{
    .{ "-v", .version }, .{ "--version", .version },
    .{ "-h", .help },    .{ "--help", .help },
});

const help_text =
    \\vgz2dro {s} - convert OPL-family VGM/VGZ logs to DRO
    \\
    \\usage: vgz2dro <song.vgz|.vgm> [more files ...]   writes FILE.dro per input
    \\       vgz2dro --version, -v
    \\       vgz2dro --help, -h
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2) {
        if (cmds.get(args[1])) |cmd| {
            switch (cmd) {
                .version => try stdout.print("vgz2dro {s}\n", .{build_options.version}),
                .help => try stdout.print(help_text, .{build_options.version}),
            }
            return stdout.flush();
        }
    }
    if (args.len < 2) {
        std.debug.print("usage: vgz2dro <song.vgz|.vgm> [more files ...]\n", .{});
        std.process.exit(2);
    }

    var ok: u32 = 0;
    var fail: u32 = 0;
    for (args[1..]) |a| {
        if (process(io, gpa, stdout, a)) ok += 1 else fail += 1;
        stdout.flush() catch {};
    }

    stdout.print("vgz2dro: {d} converted, {d} skipped/failed\n", .{ ok, fail }) catch {};
    stdout.flush() catch {};
    if (fail > 0) std.process.exit(1);
}

// --- tests ---

fn makeTestVgm(
    gpa: std.mem.Allocator,
    comptime data_off: usize,
    body: []const u8,
    clocks: struct {
        opl2: u32 = 0,
        opl3: u32 = 0,
    },
) ![]u8 {
    var vgm: std.ArrayList(u8) = .empty;
    errdefer vgm.deinit(gpa);
    try vgm.appendNTimes(gpa, 0, data_off);
    @memcpy(vgm.items[0..4], "Vgm ");
    writeU32At(vgm.items, 0x08, 0x171);
    writeU32At(vgm.items, 0x34, @intCast(data_off - 0x34));
    if (clocks.opl2 != 0) writeU32At(vgm.items, 0x50, clocks.opl2);
    if (clocks.opl3 != 0) writeU32At(vgm.items, 0x5c, clocks.opl3);
    try vgm.appendSlice(gpa, body);
    return vgm.toOwnedSlice(gpa);
}

test "opl2 register write" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x5a, 0x20, 0x01, 0x66 };
    const vgm = try makeTestVgm(gpa, 0x80, &body, .{ .opl2 = 3_579_545 });
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    try std.testing.expectEqual(@as(usize, 0x80), off);

    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    const writes = try convert(vgm, off, &m);
    try std.testing.expectEqual(@as(u64, 1), writes);
    try std.testing.expectEqual(@as(usize, 2), m.data.items.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x01 }, m.data.items);

    const info = oplInfo(vgm, off);
    try std.testing.expectEqual(@as(u8, 0), info.hw_type);
    const dro = try buildDro(gpa, &m, info.hw_type);
    defer gpa.free(dro);
    // Header: magic(8) + version(4) + lengthMS(4) + lengthBytes(4) + hwType @ 0x14
    try std.testing.expectEqual(@as(u8, 0), dro[0x14]);
}

test "opl3 bank switch" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x5e, 0x01, 0x02, 0x5f, 0x05, 0x06, 0x66 };
    const vgm = try makeTestVgm(gpa, 0x80, &body, .{ .opl3 = 14_318_180 });
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    const writes = try convert(vgm, off, &m);
    try std.testing.expectEqual(@as(u64, 2), writes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x04, 0x01, 0x02, // port 0 write of reg 0x01 (escape prefix)
        0x03, // bank 1
        0x05, 0x06, // port 1 write
    }, m.data.items);

    const info = oplInfo(vgm, off);
    try std.testing.expectEqual(@as(u8, 1), info.hw_type);
}

test "dual opl2 second chip" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x5a, 0x10, 0x11, 0xaa, 0x20, 0x21, 0x66 };
    const vgm = try makeTestVgm(gpa, 0x80, &body, .{
        .opl2 = 0x4000_0000 | 3_579_545,
    });
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    const writes = try convert(vgm, off, &m);
    try std.testing.expectEqual(@as(u64, 2), writes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x10, 0x11, // chip 0
        0x03, // chip 1
        0x20, 0x21, // chip 1 write
    }, m.data.items);

    const info = oplInfo(vgm, off);
    try std.testing.expect(info.dual_opl2);
    try std.testing.expectEqual(@as(u8, 2), info.hw_type);
}

test "wait timing from sample delay" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x62, 0x66 }; // 735 samples ~= 16 ms
    const vgm = try makeTestVgm(gpa, 0x80, &body, .{ .opl2 = 3_579_545 });
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    _ = try convert(vgm, off, &m);
    try std.testing.expectEqual(@as(u64, 16), m.total_ms);
}

test "truncated vgm rejected" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x5a, 0x01 }; // missing value byte and end marker
    const vgm = try makeTestVgm(gpa, 0x80, &body, .{ .opl2 = 3_579_545 });
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    try std.testing.expectError(error.Truncated, convert(vgm, off, &m));
}

test "unknown opcode rejected" {
    const gpa = std.testing.allocator;
    const body = [_]u8{ 0x01, 0x66 };
    const vgm = try makeTestVgm(gpa, 0x80, &body, .{ .opl2 = 3_579_545 });
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    try std.testing.expectError(error.UnknownOpcode, convert(vgm, off, &m));
}

test "clock fields beyond data offset are ignored" {
    const gpa = std.testing.allocator;
    const vgm = try makeTestVgm(gpa, 0x51, &[_]u8{}, .{});
    defer gpa.free(vgm);

    const off = vgmDataOffset(vgm).?;
    try std.testing.expectEqual(@as(usize, 0x51), off);
    const info = oplInfo(vgm, off);
    try std.testing.expectEqual(@as(u32, 0), info.opl2);
    try std.testing.expectEqual(@as(u32, 0), info.opl3);
    try std.testing.expect(!info.dual_opl2);
}

test "delay overflowing u32 milliseconds rejected" {
    const gpa = std.testing.allocator;
    var m = Dro{ .gpa = gpa };
    defer m.data.deinit(gpa);
    m.pending = 2e11;
    try std.testing.expectError(error.DelayTooLong, m.flush());
}

test "invalid data offset rejected" {
    const gpa = std.testing.allocator;
    const vgm = try makeTestVgm(gpa, 0x80, &[_]u8{0x66}, .{ .opl2 = 3_579_545 });
    defer gpa.free(vgm);
    writeU32At(vgm, 0x34, 0xffff_fff0); // points past any realistic file
    try std.testing.expect(vgmDataOffset(vgm) == null);

    writeU32At(vgm, 0x34, @intCast(vgm.len - 0x34 + 1)); // one byte past EOF
    try std.testing.expect(vgmDataOffset(vgm) == null);

    writeU32At(vgm, 0x34, 0x08); // lands inside the header (off < 0x40)
    try std.testing.expect(vgmDataOffset(vgm) == null);
}
