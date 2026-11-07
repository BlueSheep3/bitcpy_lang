const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const root = @import("root.zig");

// these syscalls are similar to the linux x86_64 syscalls:
// https://www.chromium.org/chromium-os/developer-library/reference/linux-constants/syscalls/

/// The arguments used here are the first 0x100 bits split into 0x20 bit chunks indexed from 0 to 7.
/// This means that `arg0` is the program counter and `arg1` is the syscall number.
/// When a syscall "returns" something or errors, it is written to `arg1`.
/// The most significant bit of the return value is 1 if and only if it was an error.
pub const SyscallNumber = enum(u32) {
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

pub const SyscallError = enum(u16) {
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

pub const SyscallReturn = union(enum) {
    /// Write `val` to `arg1` with the most significant bit set to 0.
    val: u31,
    /// Write the number of `err` to `arg1` with the most significant bit set to 1.
    err: SyscallError,
    /// Don't write to `arg1`.
    none,
};

pub const Context = struct {
    fd_associations: switch (builtin.target.os.tag) {
        .windows => std.AutoHashMapUnmanaged(u32, Io.File),
        else => void,
    },

    pub fn default(gpa: Alloc) Alloc.Error!Context {
        return .{
            .fd_associations = switch (builtin.target.os.tag) {
                .windows => block: {
                    var fds: std.AutoArrayHashMapUnmanaged(u32, Io.File) = .empty;
                    errdefer fds.deinit(gpa);
                    try fds.put(gpa, 0, .stdin());
                    try fds.put(gpa, 1, .stdout());
                    try fds.put(gpa, 2, .stderr());
                    break :block fds;
                },
                else => {},
            },
        };
    }
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

pub fn doSyscallAtArg1(gpa: Alloc, io: Io, ctx: Context, bytes: *ArrayList(u8)) Alloc.Error!void {
    const syscall_number: SyscallNumber = @fromBackingInt(readSyscallArg(bytes, 1));
    switch (syscall_number) {
        .read => writeSyscallReturn(bytes, try doSyscallRead(gpa, io, ctx, bytes)),
        .write => writeSyscallReturn(bytes, doSyscallWrite(io, ctx, bytes)),
        .exit => std.process.exit(bytes.items[8]),
        .dumpmem => {
            root.dumpProgramBytes(io, bytes.items) catch
                writeSyscallReturn(bytes, .{ .err = .write_failed });
        },
        _ => {
            var int: [8]u8 = undefined;
            root.writeFlippedHexInt(&int, @backingInt(syscall_number));
            std.log.err("unknown syscall number {s}", .{int});
            std.process.exit(3);
        },
    }
}

fn doSyscallRead(gpa: Alloc, io: Io, ctx: Context, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const raw_len = readSyscallArg(bytes, 4);

    // the return value is how many bits where read, and it must fit into a u31, so we'll
    // limit how many bits you can read here, since read only reads UP TO that many bits anyway
    const len = @min(raw_len, (std.math.maxInt(u31) / 8) * 8);

    if (buf % 8 != 0 or len % 8 != 0)
        return .{ .err = .misaligned };
    try root.ensureLen(gpa, bytes, buf + len);
    const slice = bytes.items[buf / 8 ..][0 .. len / 8];

    const file: Io.File = fd_to_file(ctx, fd) orelse return .{ .err = .write_failed };
    const read_count = file.readStreaming(io, &.{slice}) catch
        return .{ .err = .read_failed };

    // read_count is at most len, which fits into a u31, so this fits as well
    return .{ .val = @intCast(read_count * 8) };
}

fn doSyscallWrite(io: Io, ctx: Context, bytes: *const ArrayList(u8)) SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const len = readSyscallArg(bytes, 4);

    // FIXME handle out of bounds
    if (buf % 8 != 0 or len % 8 != 0)
        return .{ .err = .misaligned };
    const slice = bytes.items[buf / 8 ..][0 .. len / 8];

    const file: Io.File = fd_to_file(ctx, fd) orelse return .{ .err = .write_failed };
    file.writeStreamingAll(io, slice) catch return .{ .err = .write_failed };

    return .none;
}

fn fd_to_file(ctx: Context, fd: u32) ?Io.File {
    return switch (builtin.target.os.tag) {
        .windows => ctx.fd_associations.get(fd),
        else => .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } },
    };
}
