const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;
const root = @import("root.zig");

// these syscalls are similar to the linux x86_64 syscalls:
// https://www.chromium.org/chromium-os/developer-library/reference/linux-constants/syscalls/
// you can also look at the type: std.os.linux.syscalls.X64

/// The arguments used here are the first 0x100 bits split into 0x20 bit chunks indexed from 0 to 7.
/// This means that `arg0` is the program counter and `arg1` is the syscall number.
/// When a syscall "returns" something or errors, it is written to `arg1`.
/// The most significant bit of the return value is 1 if and only if it was an error.
pub const SyscallNumber = enum(u32) {
    /// Reads from file descriptor `arg2` and writes the result into the buffer at `arg3`.
    /// This will read a maximum of `arg4` bits.
    /// Returns the number of bits read. This may read fewer bits than `arg4`.
    /// The return value is guaranteed to be a multiple of 8.
    /// When the end of the file is reached, this will return the `end_of_stream` error.
    ///
    /// # Errors
    /// - `misaligned` if `arg3` or `arg4` are misaligned.
    /// - `not_open` if the file descriptor is not open.
    /// - `read_failed` if the read fails for any other reason.
    /// - `end_of_stream` when reaching the end of the file.
    read = 0x00,

    /// Writes the first `arg4` bits starting at address `arg3` to file descriptor `arg2`.
    ///
    /// # Errors
    /// - `misaligned` if `arg3` or `arg4` are misaligned.
    /// - `not_open` if the file descriptor is not open.
    /// - `write_failed` if the write fails for any other reason.
    write = 0x01,

    /// Opens the file at the path specified by the pointer `arg2` and length `arg3`
    /// and returns the file descriptor of that file.
    /// The file descriptor is guaranteed to have a 0 as its most significant bit.
    ///
    /// `arg4` is a bitmask of flags. They are, in order:
    /// - `read`: Allow reading from the file.
    /// - `write`: Allow writing to the file.
    /// - `create`: Create the file if it doesn't exist. Requires `write`.
    /// - `truncate`: Empty out the file before writing to it. Ignored if `create` is 0.
    /// At least one of `read` and `write` must be 1.
    /// All bits not mentioned here must be set to 0.
    ///
    /// # Errors
    /// - `misaligned` if `arg2` or `arg3` are misaligned.
    /// - `open_failed` if the open fails for any other reason.
    /// - `invalid_open_flags` if `arg4` contains invalid flags.
    open = 0x02,

    /// Closes the file `arg2`.
    ///
    /// # Errors
    /// - `not_open` if the file descriptor is not open.
    close = 0x03,

    /// Sleeps for the given real time in nanoseconds.
    /// The time is given by the first 0x60 bits starting at `arg2`
    ///
    /// # Errors
    /// - `misaligned` if `arg2` is misaligned.
    sleep = 0x23,

    /// Exits the program with exit status `arg2`.
    ///
    /// The exit status will be truncated to fit into a `u8`.
    /// This cannot fail.
    exit = 0x3c,

    /// Gets the current time in nanoseconds.
    /// Writes the current time as 0x60 bits starting at address `arg2`.
    ///
    /// # Errors
    /// - `misaligned` if `arg2` is misaligned.
    time = 0xe4,

    /// Writes cryptographically secure random data into the
    /// first `arg3` bits starting at address `arg2`.
    ///
    /// # Errors
    /// - `misaligned` if `arg2` or `arg3` are misaligned.
    random = 0x13e,

    /// Will dump the entire program memory to `stderr`.
    ///
    /// # Errors
    /// - `write_failed` if the write fails for any reason.
    dumpmem = 0x200,
};

pub const SyscallError = enum(u16) {
    /// There does not exist a syscall with the given syscall number.
    unkown = 0x00,
    /// The syscall you are trying to call was disabled.
    disabled = 0x01,
    /// A pointer or length that you used in a syscall was not a multiple of 8.
    misaligned = 0x02,

    /// A read failed for some reason.
    /// For example: you didn't have read permissions.
    read_failed = 0x10,
    /// A write failed for some reason.
    /// For example: you didn't have write permissions.
    write_failed = 0x11,
    /// Opening the file failed for some reason.
    /// For example: opening a read only file in write mode.
    open_failed = 0x12,

    /// The file descriptor you are using is not open.
    not_open = 0x18,
    /// The end of the stream was reached.
    /// When reading in a loop, this is the indicator that you should stop reading.
    end_of_stream = 0x19,
    /// The flags provided for the `open` syscall were invalid.
    /// This can happen by setting a bit with unspecified meaning to 1,
    /// or by enabling incompatible flags.
    invalid_open_flags = 0x20,
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
    opts: root.RunOptions,

    fd_associations: switch (builtin.target.os.tag) {
        .windows => std.AutoHashMapUnmanaged(u32, Io.File),
        else => void,
    },
    max_fds: switch (builtin.target.os.tag) {
        .windows => u32,
        else => void,
    },

    pub fn new(gpa: Alloc, opts: root.RunOptions) Alloc.Error!Context {
        switch (builtin.target.os.tag) {
            .windows => {
                var fds: std.AutoHashMapUnmanaged(u32, Io.File) = .empty;
                errdefer fds.deinit(gpa);
                try fds.put(gpa, 0, .stdin());
                try fds.put(gpa, 1, .stdout());
                try fds.put(gpa, 2, .stderr());
                return .{ .opts = opts, .fd_associations = fds, .max_fds = 2 };
            },
            else => return .{ .opts = opts, .fd_associations = {}, .max_fds = {} },
        }
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

pub fn doSyscallAtArg1(gpa: Alloc, io: Io, ctx: *Context, bytes: *ArrayList(u8)) Alloc.Error!void {
    const syscall_int = readSyscallArg(bytes, 1);
    const syscall_number = std.enums.fromInt(SyscallNumber, syscall_int) orelse {
        var int: [8]u8 = undefined;
        root.writeFlippedHexInt(&int, syscall_int);
        std.log.err("unknown syscall number {s}", .{int});
        std.process.exit(3);
    };

    if (ctx.opts.trace_syscall)
        traceSyscall(io, bytes, syscall_number) catch {};

    const return_value = switch (syscall_number) {
        .read => try doSyscallRead(gpa, io, ctx.*, bytes),
        .write => try doSyscallWrite(gpa, io, ctx.*, bytes),
        .open => try doSyscallOpen(gpa, io, ctx, bytes),
        .close => doSyscallClose(io, ctx, bytes),
        .sleep => try doSyscallSleep(gpa, io, bytes),
        .exit => std.process.exit(bytes.items[8]),
        .time => try doSyscallTime(gpa, io, bytes),
        .random => try doSyscallRandom(gpa, io, bytes),
        .dumpmem => doSyscallDumpmem(io, bytes),
    };

    if (ctx.opts.trace_syscall)
        traceSyscallReturn(io, syscall_number, return_value) catch {};

    writeSyscallReturn(bytes, return_value);
}

pub fn traceSyscall(io: Io, bytes: *const ArrayList(u8), syscall: SyscallNumber) Io.Writer.Error!void {
    var buffer: [1 << 8]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);

    try writer.interface.print("syscall: {t}", .{syscall});

    var args: [61]u8 = undefined;
    @memcpy(&args, "(XXXXXXXX, XXXXXXXX, XXXXXXXX, XXXXXXXX, XXXXXXXX, XXXXXXXX)\n");
    inline for (0..6) |i|
        root.writeFlippedHexInt(args[1 + i * 10 ..][0..8], readSyscallArg(bytes, i + 2));
    try writer.interface.writeAll(&args);

    try writer.interface.flush();
}

pub fn traceSyscallReturn(io: Io, syscall: SyscallNumber, ret: SyscallReturn) Io.Writer.Error!void {
    var buffer: [1 << 7]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);

    try writer.interface.print("{t} returned: ", .{syscall});
    switch (ret) {
        .val => |val| {
            var number: [8]u8 = undefined;
            root.writeFlippedHexInt(&number, val);
            try writer.interface.print("value({s})\n", .{number});
        },
        .err => |err| try writer.interface.print("error({t})\n", .{err}),
        .none => try writer.interface.writeAll("none\n"),
    }
    try writer.interface.flush();
}

fn fd_to_file(ctx: Context, fd: u32) ?Io.File {
    return switch (builtin.target.os.tag) {
        .windows => ctx.fd_associations.get(fd),
        else => .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } },
    };
}

fn getAlignedSlice(gpa: Alloc, bytes: *ArrayList(u8), buf: u32, len: u32) Alloc.Error!?[]u8 {
    if (buf % 8 != 0 or len % 8 != 0)
        return null;
    try root.ensureLen(gpa, bytes, buf + len);
    return bytes.items[buf / 8 ..][0 .. len / 8];
}

fn doSyscallRead(gpa: Alloc, io: Io, ctx: Context, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const raw_len = readSyscallArg(bytes, 4);

    // the return value is how many bits where read, and it must fit into a u31, so we'll
    // limit how many bits you can read here, since read only reads UP TO that many bits anyway
    const len = @min(raw_len, (std.math.maxInt(u31) / 8) * 8);

    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    const file: Io.File = fd_to_file(ctx, fd) orelse return .{ .err = .not_open };
    const read_count = file.readStreaming(io, &.{slice}) catch |err| switch (err) {
        error.NotOpenForReading => return .{ .err = .not_open },
        error.EndOfStream => return .{ .err = .end_of_stream },
        else => return .{ .err = .read_failed },
    };

    // read_count is at most len, which fits into a u31, so this fits as well
    return .{ .val = @intCast(read_count * 8) };
}

fn doSyscallWrite(gpa: Alloc, io: Io, ctx: Context, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const len = readSyscallArg(bytes, 4);
    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    const file: Io.File = fd_to_file(ctx, fd) orelse return .{ .err = .not_open };
    file.writeStreamingAll(io, slice) catch |err| switch (err) {
        error.NotOpenForWriting => return .{ .err = .not_open },
        else => return .{ .err = .write_failed },
    };

    return .none;
}

fn doSyscallOpen(gpa: Alloc, io: Io, ctx: *Context, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const buf = readSyscallArg(bytes, 2);
    const len = readSyscallArg(bytes, 3);
    const flags = readSyscallArg(bytes, 4);

    const FileFlags = packed struct(u32) {
        read: bool = false,
        write: bool = false,
        create: bool = false,
        truncate: bool = false,
        unused: u28 = 0,
    };
    const f: FileFlags = @bitCast(flags);
    if (f.unused != 0) return .{ .err = .invalid_open_flags };

    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    const cwd = std.Io.Dir.cwd();
    var file: Io.File = undefined;
    if (f.create) {
        if (!f.write) return .{ .err = .invalid_open_flags };
        file = cwd.createFile(io, slice, .{ .read = f.read, .truncate = f.truncate }) catch
            return .{ .err = .open_failed };
    } else {
        const read_write: u2 = @bitCast(@as([2]bool, .{ f.read, f.write }));
        const mode: Io.Dir.OpenFileOptions.Mode = switch (read_write) {
            0b00 => return .{ .err = .invalid_open_flags },
            0b01 => .read_only,
            0b10 => .write_only,
            0b11 => .read_write,
        };
        file = cwd.openFile(io, slice, .{ .mode = mode }) catch
            return .{ .err = .open_failed };
    }

    switch (builtin.target.os.tag) {
        .windows => {
            ctx.max_fds += 1;
            try ctx.fd_associations.put(gpa, ctx.max_fds, file);
            return .{ .val = @intCast(ctx.max_fds) };
        },
        else => return .{ .val = @intCast(file.handle) },
    }
}

fn doSyscallClose(io: Io, ctx: *Context, bytes: *const ArrayList(u8)) SyscallReturn {
    const fd = readSyscallArg(bytes, 2);

    const file: Io.File = fd_to_file(ctx.*, fd) orelse return .{ .err = .not_open };
    file.close(io);

    switch (builtin.target.os.tag) {
        .windows => _ = ctx.fd_associations.remove(fd),
        else => {},
    }

    return .none;
}

fn doSyscallSleep(gpa: Alloc, io: Io, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const buf = readSyscallArg(bytes, 2);
    const len = 0x60;
    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    const duration: Io.Duration = .fromNanoseconds(@bitCast(slice[0 .. len / 8].*));
    io.sleep(duration, .real) catch unreachable;
    return .none;
}

fn doSyscallTime(gpa: Alloc, io: Io, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const buf = readSyscallArg(bytes, 2);
    const len = 0x60;
    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    const time = Io.Timestamp.now(io, .real);
    @memcpy(slice, &@as([len / 8]u8, @bitCast(time.nanoseconds)));
    return .none;
}

fn doSyscallRandom(gpa: Alloc, io: Io, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const buf = readSyscallArg(bytes, 2);
    const len = readSyscallArg(bytes, 3);
    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    io.random(slice);
    return .none;
}

fn doSyscallDumpmem(io: Io, bytes: *const ArrayList(u8)) SyscallReturn {
    root.dumpProgramBytes(io, bytes.items) catch
        return .{ .err = .write_failed };
    return .none;
}
