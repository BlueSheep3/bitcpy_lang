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
                ']' => return error.CloseCommentOutsideComment,
                else => return error.UnexpectedChar,
            }
        }
    }
    return bytes;
}

fn push4Bits(gpa: Alloc, bits: u4, bytes: *ArrayList(u8), is_misaligned: *bool) !void {
    if (is_misaligned.*) {
        const last = &bytes.items[bytes.items.len - 1];
        last.* |= @as(u8, bits) << 4;
        is_misaligned.* = false;
    } else {
        try bytes.append(gpa, bits);
        is_misaligned.* = true;
    }
}

pub const RunError = error{} || Alloc.Error;

pub fn runProgram(gpa: Alloc, bytes: *ArrayList(u8)) RunError!void {
    // the first 256 bits of the program have special meaning.
    // this forces all of them to be in bounds, so the main loop
    // doesn't have to ever handle these weird edgecases.
    try ensureLength(gpa, bytes, 256 / 8);

    while (true) {
        const pc = bytesToU32(bytes.items[0..4].*);

        // TODO handle going out of bounds
        // in that case, do not extend array list, just pretend there are zeros out of bounds
        const source = bytesToU32(bytes.items[pc / 8 ..][0..4].*);
        const dest = bytesToU32(bytes.items[pc / 8 + 4 ..][0..4].*);
        const count = bytesToU32(bytes.items[pc / 8 + 8 ..][0..4].*);

        // TODO handle a LOT of edgecases
        // - any of the 3 values may not be a multiple of 8
        // - this may go out of bounds
        // - if the write is out of bounds, extend the array list
        // - source and dest may overlap
        @memcpy(
            bytes.items[dest / 8 ..][0 .. count / 8],
            bytes.items[source / 8 ..][0 .. count / 8],
        );

        const new_pc = bytesToU32(bytes.items[0..4].*) +| 0x60;
        bytes.items[0..4].* = u32ToBytes(new_pc);

        if (new_pc == std.math.maxInt(u32))
            break;
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

    switch (@import("builtin").cpu.arch.endian()) {
        .little => return transmute([4]u8, u32, bytes),
        .big => {
            const a, const b, const c, const d = bytes;
            const reversed_bytes = .{ d, c, b, a };
            return transmute([4]u8, u32, reversed_bytes);
        },
    }
}

fn u32ToBytes(int: u32) [4]u8 {
    // in future zig versions @bitCast will always convert ints as if they were
    // little endian, meaning this entire function could be replaced with a @bitCast

    switch (@import("builtin").cpu.arch.endian()) {
        .little => return transmute(u32, [4]u8, int),
        .big => {
            const bytes: [4]u8 = transmute(u32, [4]u8, int);
            const a, const b, const c, const d = bytes;
            return .{ d, c, b, a };
        },
    }
}

fn transmute(From: type, To: type, value: From) To {
    const alignment = @max(@alignOf(From), @alignOf(To));
    const from: From align(alignment) = value;
    const ptr: *align(alignment) const From = &from;
    const to_ptr: *align(alignment) const To = @ptrCast(ptr);
    return to_ptr.*;
}
