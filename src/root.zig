const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

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
    // the first 256 bits of the program have special meaning.
    // this forces all of them to be in bounds, so the main loop
    // doesn't have to ever handle these weird edgecases.
    try ensureLen(gpa, bytes, 256 / 8);

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

        try bitcpyImpure(gpa, io, bytes, source, dest, count);

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

// these syscalls are similar to the linux x86_64 syscalls:
// https://www.chromium.org/chromium-os/developer-library/reference/linux-constants/syscalls/

/// The arguments used here are the first 256 bits split into 32 bits chunks indexed from 0 to 7.
/// This means that `arg0` is the program counter and `arg1` is the syscall number.
/// When a syscall "returns" something or errors, it is written to `arg1`.
/// The most significant bit of the return value is 1 if and only if it was an error.
const SyscallNumber = enum(u32) {
    /// Reads from file descriptor `arg2` and writes the result into the buffer at `arg3`.
    /// This will read a maximum of `arg4` bits.
    /// Returns the number of bits read.
    /// The return value is less than `arg4` if and only if the end of the file was reached.
    ///
    /// # Errors
    /// - `misaligned` if `arg3` or `arg4` are misaligned.
    /// - `read_failed` if the read fails for any reason.
    read = 0x00,

    /// Writes the first `arg4` bits starting at address `arg3` to file descriptor `arg2`.
    ///
    /// # Errors
    /// - `misaligned` if `arg3` or `arg4` are misaligned.
    /// - `write_failed` if the write fails for any reason.
    write = 0x01,

    /// Exits the program with exit status `arg2`.
    ///
    /// The exit status will be truncated to fit into a `u8`.
    /// This cannot fail.
    exit = 0x3c,

    /// Will dump the entire program memory to `stderr`.
    ///
    /// # Errors
    /// - `write_failed` if the write fails for any reason.
    dumpmem = 0x200,

    _,
};

const SyscallError = enum(u16) {
    /// There does not exist a syscall with the given syscall number.
    unkown = 0x0,
    /// The syscall you are trying to call was disabled.
    disabled = 0x1,
    /// A pointer or length that you used in a syscall was not a multiple of 8.
    misaligned = 0x2,

    /// A read failed for some reason.
    /// For example: the file descriptor wasn't open, you didn't have read permissions, etc...
    read_failed = 0x10,
    /// A write failed for some reason.
    /// For example: the file descriptor wasn't open, you didn't have write permissions, etc...
    write_failed = 0x11,

    _,
};

const SyscallReturn = union(enum) {
    /// Write `val` to `arg1` with the most significant bit set to 0.
    val: u31,
    /// Write the number of `err` to `arg1` with the most significant bit set to 1.
    err: SyscallError,
    /// Don't write to `arg1`.
    none,
};

fn readSyscallArg(bytes: *const ArrayList(u8), comptime arg_index: u3) u32 {
    const index = @as(u32, arg_index) * 4;
    return @bitCast(bytes.items[index..][0..4].*);
}
fn writeSyscallReturn(bytes: *ArrayList(u8), ret: SyscallReturn) void {
    switch (ret) {
        .val => |val| {
            @memcpy(bytes.items[4..8], &@as([4]u8, @bitCast(@as(u32, val))));
        },
        .err => |err| {
            const int = @as(u32, @backingInt(err)) | 0x8000_0000;
            @memcpy(bytes.items[4..8], &@as([4]u8, @bitCast(int)));
        },
        .none => {},
    }
}

pub fn bitcpyImpure(
    gpa: Alloc,
    io: Io,
    bytes: *ArrayList(u8),
    source: u32,
    dest: u32,
    count: u32,
) Alloc.Error!void {
    try bitcpy(gpa, bytes, source, dest, count);

    // this condition guarantees that at least 1 bit was written to the bits in 0x20..0x40
    if (dest < 0x40 and dest + count > 0x20 and count != 0) {
        const syscall_number: SyscallNumber = @fromBackingInt(readSyscallArg(bytes, 1));
        switch (syscall_number) {
            .read => writeSyscallReturn(bytes, doSyscallRead(io, bytes)),
            .write => writeSyscallReturn(bytes, doSyscallWrite(io, bytes)),
            .exit => std.process.exit(bytes.items[8]),
            .dumpmem => {
                dumpProgramBytes(io, bytes.items) catch
                    writeSyscallReturn(bytes, .{ .err = .write_failed });
            },
            _ => std.debug.panic(
                "tried to perform syscall 0x{x:08}, but it hasn't been implemented yet",
                .{syscall_number},
            ),
        }
    }
}

fn doSyscallRead(io: Io, bytes: *const ArrayList(u8)) SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const raw_len = readSyscallArg(bytes, 4);

    // the return value is how many bits where read, and it must fit into a u31, so we'll
    // limit how many bits you can read here, since read only reads UP TO that many bits anyway
    const len = @min(raw_len, (std.math.maxInt(u31) / 8) * 8);

    // FIXME handle out of bounds
    // is there any good way to handle OOB besides always
    // extending memory to fit this entire buffer?
    if (buf % 8 != 0 or len % 8 != 0)
        return .{ .err = .misaligned };
    const slice = bytes.items[buf / 8 ..][0 .. len / 8];

    // FIXME file handles are not integers on windows
    const file: Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
    const read_count = file.readStreaming(io, &.{slice}) catch
        return .{ .err = .read_failed };

    // read_count is at most len, which fits into a u31, so this fits as well
    return .{ .val = @intCast(read_count * 8) };
}

fn doSyscallWrite(io: Io, bytes: *const ArrayList(u8)) SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const len = readSyscallArg(bytes, 4);

    // FIXME handle out of bounds
    if (buf % 8 != 0 or len % 8 != 0)
        return .{ .err = .misaligned };
    const slice = bytes.items[buf / 8 ..][0 .. len / 8];

    // FIXME file handles are not integers on windows
    const file: Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
    file.writeStreamingAll(io, slice) catch return .{ .err = .write_failed };

    return .none;
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
        try ensureLen(gpa, bytes, @divCeil((@max(a_source, a_dest) + a_count), 8));
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

    try ensureLen(gpa, bytes, 1 + dest / 8);
    const mask = @as(u8, 1) << @as(u3, @truncate(dest));
    if (bit == 1) {
        bytes.items[dest / 8] |= mask;
    } else {
        bytes.items[dest / 8] &= ~mask;
    }
}

fn ensureLen(gpa: Alloc, bytes: *ArrayList(u8), required_len: usize) Alloc.Error!void {
    const n = required_len -| bytes.items.len;
    if (n > 0) {
        @branchHint(.unlikely);
        try bytes.appendNTimes(gpa, 0, n);
    }
}

fn traceCommand(io: Io, source: u32, dest: u32, count: u32) Io.Writer.Error!void {
    var buffer: [40]u8 = undefined;
    @memcpy(&buffer, "running: [XXXXXXXX, XXXXXXXX, XXXXXXXX]\n");
    writeFlippedHexInt(buffer[10..18], source);
    writeFlippedHexInt(buffer[20..28], dest);
    writeFlippedHexInt(buffer[30..38], count);
    Io.File.stderr().writeStreamingAll(io, &buffer) catch return error.WriteFailed;
}

fn writeFlippedHexInt(chars: *[8]u8, int: u32) void {
    const quads: [8]u4 = @bitCast(int);
    for (chars, quads) |*char, quad|
        char.* = "0123456789abcdef"[quad];
}

fn dumpProgramBytes(io: Io, bytes: []const u8) Io.Writer.Error!void {
    var buffer: [2048]u8 = undefined;
    var file_writer = Io.File.stderr().writer(io, &buffer);
    const writer = &file_writer.interface;

    try writer.writeAll("\n");
    for (bytes, 0..) |byte, i| {
        const lower, const higher = @as([2]u4, @bitCast(byte));
        try writer.print("{x}{x}", .{ lower, higher });
        if (i % 4 == 3)
            try writer.writeAll(if (i % 32 == 31) "\n" else " ");
    }
    if (bytes.len % 32 != 0)
        try writer.writeAll("\n");

    try writer.flush();
}
