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
    try ensureLength(gpa, bytes, 256 / 8);

    while (true) {
        if (opts.trace_memory)
            try dumpProgramBytes(io, bytes.items);

        const pc = bytesToU32(bytes.items[0..4].*);

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
            // FIXME these values should be printed with flipped digit order
            std.debug.print("running: [{x:08}, {x:08}, {x:08}]\n", .{ source, dest, count });

        try bitcpyImpure(gpa, io, bytes, source, dest, count);

        const new_pc = bytesToU32(bytes.items[0..4].*) +% 0x60;
        bytes.items[0..4].* = u32ToBytes(new_pc);
    }
}

fn readU32(bytes: *const ArrayList(u8), source: u32) u32 {
    // FIXME i think this may have problems when source is close to 2^32

    const bits_end = @as(u3, @truncate(source));
    if (bits_end == 0) {
        const num_oob_bytes = source / 8 -| bytes.items.len;
        const read_bytes = 4 -| num_oob_bytes;
        const bytes_in_range = bytes.items[source / 8 ..][0..read_bytes];
        var result_bytes: [4]u8 = .{0} ** 4;
        @memcpy(result_bytes[0..bytes_in_range.len], bytes_in_range);
        return bytesToU32(result_bytes);
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
const SyscallNumber = enum(u32) {
    /// Writes the first `arg2` bytes starting at address `arg1` to file descriptor `arg0`.
    ///
    /// # Errors
    /// - `misaligned` if `arg1` or `arg2` are misaligned.
    /// - `write_failed` if the write fails for any reason.
    write = 0x01,

    /// Exits the program with exit status `arg0`.
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

    /// A write failed for some reason.
    /// For example: the file descriptor wasn't open,
    /// you didn't have write permissions, etc...
    write_failed = 0xf,

    _,
};

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
        const syscall_number: SyscallNumber = @enumFromInt(bytesToU32(bytes.items[4..8].*));
        switch (syscall_number) {
            .write => {
                const fd = bytesToU32(bytes.items[8..12].*);
                const buf = bytesToU32(bytes.items[12..16].*);
                const len = bytesToU32(bytes.items[16..20].*);

                // FIXME handle out of bounds
                if (buf % 8 != 0 or len % 8 != 0)
                    @panic("TODO: write error");
                const slice = bytes.items[buf / 8 ..][0 .. len / 8];
                // FIXME file handles are not integers on windows
                const file: Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };

                // is this really the best way to do this write?
                var buffer: [1024]u8 = undefined;
                var writer = file.writer(io, &buffer);
                writer.interface.writeAll(slice) catch @panic("TODO: write error");
                writer.flush() catch @panic("TODO: write error");
            },
            .exit => {
                std.process.exit(bytes.items[8]);
            },
            .dumpmem => {
                dumpProgramBytes(io, bytes.items) catch |err| switch (err) {
                    error.WriteFailed => @panic("TODO: write error"),
                };
            },
            _ => std.debug.panic(
                "tried to perform syscall 0x{x:08}, but it hasn't been implemented yet",
                .{syscall_number},
            ),
        }
    }
}

// this is the pure version of bitcpyImpure, meaning it will never perform syscalls.
pub fn bitcpy(
    gpa: Alloc,
    bytes: *ArrayList(u8),
    source: u32,
    dest: u32,
    count: u32,
) Alloc.Error!void {
    try slow_bitcpy(gpa, bytes, source, dest, count);

    // TODO handle a LOT of edgecases
    // - any of the 3 values may not be a multiple of 8
    // - this may go out of bounds
    // - if the write is out of bounds, extend the array list
    // - source and dest may overlap
    // - the bits being read/written may be at an adress larger than 2^32
    // @memcpy(
    //     bytes.items[dest / 8 ..][0 .. count / 8],
    //     bytes.items[source / 8 ..][0 .. count / 8],
    // );
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

    try ensureLength(gpa, bytes, dest / 8);
    const mask = @as(u8, 1) << @as(u3, @truncate(dest));
    if (bit == 1) {
        bytes.items[dest / 8] |= mask;
    } else {
        bytes.items[dest / 8] &= ~mask;
    }
}

fn ensureLength(gpa: Alloc, bytes: *ArrayList(u8), required_len: usize) !void {
    const extra_len: usize = required_len -| bytes.items.len;
    for (0..extra_len) |_|
        try bytes.append(gpa, 0);
}

fn bytesToU32(bytes: [4]u8) u32 {
    // in future zig versions @bitCast will always convert ints as if they were
    // little endian, meaning this entire function could be replaced with a @bitCast

    const int = std.mem.bytesToValue(u32, &bytes);
    return std.mem.toNative(u32, int, .little);
}

fn u32ToBytes(int: u32) [4]u8 {
    // in future zig versions @bitCast will always convert ints as if they were
    // little endian, meaning this entire function could be replaced with a @bitCast

    const little_endian = std.mem.nativeTo(u32, int, .little);
    return std.mem.toBytes(little_endian);
}

fn dumpProgramBytes(io: Io, bytes: []const u8) Io.Writer.Error!void {
    var buffer: [2048]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), io, &buffer);
    const writer = &file_writer.interface;

    for (bytes, 0..) |byte, i| {
        const lower = byte % (1 << 4);
        const higher = byte >> 4;
        try writer.print("{x}{x}", .{ lower, higher });
        if (i % 4 == 3)
            try writer.writeAll(if (i % 32 == 31) "\n" else " ");
    }
    if (bytes.len % 32 != 0)
        try writer.writeAll("\n");

    try writer.flush();
}
