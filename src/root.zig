const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Context = syscall.Context;

pub const syscall = @import("syscall.zig");

pub const ParseError = error{
    CloseCommentOutsideComment,
    UnexpectedChar,
} || Alloc.Error;

pub fn parseCode(gpa: Alloc, code: []const u8) ParseError!ArrayList(u8) {
    var bytes: ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var is_misaligned = false;
    var is_comment = false;

    for (code) |c| {
        if (is_comment) {
            if (c == ']')
                is_comment = false;
        } else {
            switch (c) {
                '0'...'9' => try push4Bits(gpa, @intCast(c - '0'), &bytes, &is_misaligned),
                'a'...'f' => try push4Bits(gpa, @intCast(c - 'a' + 10), &bytes, &is_misaligned),
                'A'...'F' => try push4Bits(gpa, @intCast(c - 'A' + 10), &bytes, &is_misaligned),
                '\t', '\n', '\r', ' ' => {},
                '[' => is_comment = true,
                ']' => return ParseError.CloseCommentOutsideComment,
                else => return ParseError.UnexpectedChar,
            }
        }
    }
    return bytes;
}

fn push4Bits(gpa: Alloc, bits: u4, bytes: *ArrayList(u8), is_misaligned: *bool) Alloc.Error!void {
    if (is_misaligned.*) {
        const last = &bytes.items[bytes.items.len - 1];
        last.* |= @as(u8, bits) << 4;
        is_misaligned.* = false;
    } else {
        try bytes.append(gpa, bits);
        is_misaligned.* = true;
    }
}

pub const RunOptions = struct {
    trace_command: bool = false,
    trace_memory: bool = false,
};

pub const RunError = error{
    PcOutOfBounds,
} || Alloc.Error || Io.Writer.Error;

pub fn runProgram(gpa: Alloc, io: Io, bytes: *ArrayList(u8), opts: RunOptions) RunError!noreturn {
    // the first 0x100 bits of the program have special meaning.
    // this forces all of them to be in bounds, so the main loop
    // doesn't have to ever handle these weird edgecases.
    try ensureLen(gpa, bytes, 0x100);

    const ctx: Context = try .default(gpa);

    while (true) {
        if (opts.trace_memory)
            try dumpProgramBytes(io, bytes.items);

        const pc: u32 = @bitCast(bytes.items[0..4].*);

        // if this happens, you could technically still continue the program,
        // but it's very likely that something went wrong here.
        // this also makes reading the values below easier.
        if (pc / 8 + 12 > bytes.items.len)
            return RunError.PcOutOfBounds;

        // PERF these can be replaced with versions that don't check for bounds
        const source = readU32(bytes, pc);
        const dest = readU32(bytes, pc + 0x20);
        const count = readU32(bytes, pc + 0x40);

        if (opts.trace_command)
            traceCommand(io, source, dest, count) catch {};

        try bitcpyImpure(gpa, io, ctx, bytes, source, dest, count);

        const new_pc = @as(u32, @bitCast(bytes.items[0..4].*)) +% 0x60;
        bytes.items[0..4].* = @bitCast(new_pc);
    }
}

fn readU32(bytes: *const ArrayList(u8), source: u32) u32 {
    // FIXME i think this may have problems when source is close to 2^32

    const bits_end = @as(u3, @truncate(source));
    if (bits_end == 0) {
        const num_oob_bytes = source / 8 -| bytes.items.len;
        const read_bytes = 4 -| num_oob_bytes;
        const bytes_in_range = bytes.items[source / 8 ..][0..read_bytes];
        var result_bytes: [4]u8 = @splat(0);
        @memcpy(result_bytes[0..bytes_in_range.len], bytes_in_range);
        return @bitCast(result_bytes);
    } else {
        const start_mask: u8 = @truncate(@as(u16, 0xff) << bits_end);
        const end_mask: u8 = ~start_mask;
        var result: u32 = 0;
        if (source / 8 < bytes.items.len)
            result |= (bytes.items[source / 8] & start_mask) >> bits_end;
        for (bytes.items[source / 8 + 1 ..][0..3], 0..) |byte, i|
            result |= @as(u32, byte) << (bits_end + @as(u5, @intCast(i * 8)));
        if (source / 8 + 4 < bytes.items.len)
            result |= (bytes.items[source / 8 + 4] & end_mask) << bits_end;
        return result;
    }
}

pub fn bitcpyImpure(
    gpa: Alloc,
    io: Io,
    ctx: Context,
    bytes: *ArrayList(u8),
    source: u32,
    dest: u32,
    count: u32,
) Alloc.Error!void {
    try bitcpy(gpa, bytes, source, dest, count);

    // this condition guarantees that at least 1 bit was written to the bits in 0x20..0x40
    if (dest < 0x40 and dest + count > 0x20 and count != 0)
        try syscall.doSyscallAtArg1(gpa, io, ctx, bytes);
}

// this is the pure version of bitcpyImpure, meaning it will never perform syscalls.
pub fn bitcpy(
    gpa: Alloc,
    bytes: *ArrayList(u8),
    source: u32,
    dest: u32,
    count: u32,
) Alloc.Error!void {
    const dif = @abs(@as(i32, @bitCast(source)) - @as(i32, @bitCast(dest)));
    if (count < 16 or dif % 8 != 0 or dif <= count) {
        try slow_bitcpy(gpa, bytes, source, dest, count);
    } else {
        const first_count: u32 = (8 - (source % 8)) % 8;
        const a_source = source + first_count;
        const a_dest = dest + first_count;
        const a_count = count - count % 8;
        std.debug.assert(a_source % 8 == 0 and a_dest % 8 == 0 and a_count % 8 == 0);
        try ensureLen(gpa, bytes, @max(a_source, a_dest) + a_count);
        // TODO make this read here and write after the memmove, so dif <= count can be removed
        try slow_bitcpy(gpa, bytes, source, dest, first_count);
        try slow_bitcpy(gpa, bytes, a_source + a_count, a_dest + a_count, count % 8);

        @memmove(
            bytes.items[a_dest / 8 ..][0 .. a_count / 8],
            bytes.items[a_source / 8 ..][0 .. a_count / 8],
        );
    }

    // FIXME the bits being read/written may be at an adress larger than 2^32
}

// TODO replace this entirely
// the simplest (but also really slow) implementation of bitcpy.
// you may use this to test whether the actual bitcpy implementation is correct.
fn slow_bitcpy(
    gpa: Alloc,
    bytes: *ArrayList(u8),
    source: u32,
    dest: u32,
    count: u32,
) Alloc.Error!void {
    switch (std.math.order(source, dest)) {
        .lt => {
            var i: u33 = count;
            while (i > 0) {
                i -= 1;
                try bitcpy_single_bit(gpa, bytes, source + i, dest + i);
            }
        },
        .gt => {
            for (0..count) |index| {
                const i: u33 = @intCast(index);
                try bitcpy_single_bit(gpa, bytes, source + i, dest + i);
            }
        },
        .eq => {},
    }
}

fn bitcpy_single_bit(gpa: Alloc, bytes: *ArrayList(u8), source: u33, dest: u33) Alloc.Error!void {
    var bit: u1 = 0;
    if (source / 8 < bytes.items.len)
        bit = @truncate(bytes.items[source / 8] >> @as(u3, @truncate(source)));

    try ensureLen(gpa, bytes, 1 + dest);
    const mask = @as(u8, 1) << @as(u3, @truncate(dest));
    if (bit == 1) {
        bytes.items[dest / 8] |= mask;
    } else {
        bytes.items[dest / 8] &= ~mask;
    }
}

pub fn ensureLen(gpa: Alloc, bytes: *ArrayList(u8), required_bitlen: usize) Alloc.Error!void {
    const n = @divCeil(required_bitlen, 8) -| bytes.items.len;
    if (n > 0) {
        @branchHint(.unlikely);
        try bytes.appendNTimes(gpa, 0, n);
    }
}

pub fn traceCommand(io: Io, source: u32, dest: u32, count: u32) Io.Writer.Error!void {
    var buffer: [40]u8 = undefined;
    @memcpy(&buffer, "running: [XXXXXXXX, XXXXXXXX, XXXXXXXX]\n");
    writeFlippedHexInt(buffer[10..18], source);
    writeFlippedHexInt(buffer[20..28], dest);
    writeFlippedHexInt(buffer[30..38], count);
    Io.File.stderr().writeStreamingAll(io, &buffer) catch return error.WriteFailed;
}

pub fn writeFlippedHexInt(chars: *[8]u8, int: u32) void {
    const quads: [8]u4 = @bitCast(int);
    for (chars, quads) |*char, quad|
        char.* = "0123456789abcdef"[quad];
}

pub fn dumpProgramBytes(io: Io, bytes: []const u8) Io.Writer.Error!void {
    var buffer: [2048]u8 = undefined;
    var file_writer = Io.File.stderr().writer(io, &buffer);
    const writer = &file_writer.interface;

    try writer.writeAll("\n");
    for (bytes, 0..) |byte, i| {
        const lower, const higher = @as([2]u4, @bitCast(byte));
        try writer.print("{x}{x}", .{ lower, higher });
        if (i % 4 == 3)
            try writer.writeAll(if (i % 0x20 == 0x1f) "\n" else " ");
    }
    if (bytes.len % 0x20 != 0)
        try writer.writeAll("\n");

    try writer.flush();
}
