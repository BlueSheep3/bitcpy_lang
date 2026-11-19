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

    /// Spawns a process with given command line arguments and file descriptors for stdio.
    ///
    /// The command line arguments are a slice of slices. This means that they are passed
    /// in via a pointer in `arg2` and a length in `arg3`. These point to an array of more
    /// pointers and lengths (in that order). Each of those encode a string in the
    /// same slice format.
    ///
    /// The first command line argument is the path to the executable that you want to spawn.
    /// If it is not already a path, this will search `PATH` for the given name.
    ///
    /// `arg4` is a pointer to 3 stdio specifiers. Each of those is 0x20 bits long.
    /// The 3 stdio specifiers represent: stdin, stdout, stderr.
    /// If a stdio specifier has a 0 as its most significant bit, it will be interpreted
    /// as a file descriptor and the spawned process will use that file descriptor.
    /// If a stdio specifier has a 1 as its most significant bit,
    /// the rest of the value has a special meaning:
    /// - 0: Use a stream that behaves like `/dev/null`.
    /// - 1: Use the same file descriptor as the parent process.
    /// - 2: Creates an anonymous pipe. Once the process gets spawned,
    ///      the file descriptor of that pipe is written to this stdio specifier.
    ///
    /// # Errors
    /// - `misaligned` if any of `arg2`, `arg3`, or `arg4` are misaligned
    ///   or if `arg3` is not divisible by 0x40,
    ///   or if any command line argument pointer or length is misaligned.
    /// - `not_open` if any file descriptor in a stdio specifier is not open.
    /// - `invalid_stdio` if a stdio specifier is special,
    ///   but is not any of the values in the above list.
    /// - `spawn_failed` if something fails during the actual spawn itself.
    spawn = 0x3b,

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
    /// The stdio argument of the `spawn` syscall were invalid.
    /// This happens when the most significant bit of one of the stdio args is 1,
    /// but the rest of the number is greater than 2.
    invalid_stdio = 0x21,

    /// Generic error when a spawn fails.
    /// This can happen when the executable file is not found or not executable.
    /// This does NOT happen when the spawned process returns a non-zero exit status,
    /// because the spawn syscall does not wait for the process to finish.
    spawn_failed = 0x30,
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

    os: switch (builtin.target.os.tag) {
        .windows => struct {
            fd_assoc: std.AutoHashMapUnmanaged(u32, Io.File),
            max_fd: u32,
            pid_assoc: std.AutoHashMapUnmanaged(u32, std.os.windows.HANDLE),
            max_pid: u32,
        },
        else => void,
    },

    pub fn new(gpa: Alloc, opts: root.RunOptions) Alloc.Error!Context {
        switch (builtin.target.os.tag) {
            .windows => {
                var ctx: Context = .{
                    .opts = opts,
                    .os = .{
                        .fd_assoc = .empty,
                        .max_fd = 0,
                        .pid_assoc = .empty,
                        .max_pid = 0,
                    },
                };
                errdefer ctx.os.fd_assoc.deinit(gpa);
                _ = try ctx.addFile(gpa, .stdin());
                _ = try ctx.addFile(gpa, .stdout());
                _ = try ctx.addFile(gpa, .stderr());
                return ctx;
            },
            else => return .{ .opts = opts, .os = {} },
        }
    }

    pub fn deinit(ctx: *Context, gpa: Alloc) void {
        switch (builtin.target.os.tag) {
            .windows => ctx.os.fd_assoc.deinit(gpa),
            else => {},
        }
    }

    pub fn fdToFile(ctx: Context, fd: u32) ?Io.File {
        return switch (builtin.target.os.tag) {
            .windows => ctx.os.fd_assoc.get(fd),
            else => .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } },
        };
    }

    pub fn addFile(ctx: *Context, gpa: Alloc, file: Io.File) Alloc.Error!u32 {
        switch (builtin.target.os.tag) {
            .windows => {
                ctx.os.max_fd += 1;
                try ctx.os.fd_assoc.put(gpa, ctx.os.max_fd, file);
                return ctx.os.max_fd;
            },
            else => return @intCast(file.handle),
        }
    }

    pub fn removeFd(ctx: *Context, fd: u32) void {
        switch (builtin.target.os.tag) {
            .windows => _ = ctx.os.fd_assoc.remove(fd),
            else => {},
        }
    }

    pub fn addPid(ctx: *Context, gpa: Alloc, pid: std.process.Child.Id) Alloc.Error!u32 {
        switch (builtin.target.os.tag) {
            .windows => {
                ctx.os.max_pid += 1;
                try ctx.os.pid_assoc.put(gpa, ctx.os.max_pid, pid);
                return ctx.os.max_pid;
            },
            else => return @intCast(pid),
        }
    }
};

// #######################################################################################

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
        .spawn => try doSyscallSpawn(gpa, io, ctx, bytes),
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

fn getAlignedSlice(gpa: Alloc, bytes: *ArrayList(u8), buf: u32, len: u32) Alloc.Error!?[]u8 {
    if (buf % 8 != 0 or len % 8 != 0)
        return null;
    try root.ensureLen(gpa, bytes, buf + len);
    return bytes.items[buf / 8 ..][0 .. len / 8];
}

// #######################################################################################

fn doSyscallRead(gpa: Alloc, io: Io, ctx: Context, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const fd = readSyscallArg(bytes, 2);
    const buf = readSyscallArg(bytes, 3);
    const raw_len = readSyscallArg(bytes, 4);

    // the return value is how many bits where read, and it must fit into a u31, so we'll
    // limit how many bits you can read here, since read only reads UP TO that many bits anyway
    const len = @min(raw_len, (std.math.maxInt(u31) / 8) * 8);

    const slice = try getAlignedSlice(gpa, bytes, buf, len) orelse return .{ .err = .misaligned };

    const file: Io.File = ctx.fdToFile(fd) orelse return .{ .err = .not_open };
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

    const file: Io.File = ctx.fdToFile(fd) orelse return .{ .err = .not_open };
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

    const fd = try ctx.addFile(gpa, file);
    return .{ .val = @intCast(fd) };
}

fn doSyscallClose(io: Io, ctx: *Context, bytes: *const ArrayList(u8)) SyscallReturn {
    const fd = readSyscallArg(bytes, 2);

    const file: Io.File = ctx.fdToFile(fd) orelse return .{ .err = .not_open };
    file.close(io);
    ctx.removeFd(fd);

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

fn doSyscallSpawn(gpa: Alloc, io: Io, ctx: *Context, bytes: *ArrayList(u8)) Alloc.Error!SyscallReturn {
    const args_ptr = readSyscallArg(bytes, 2);
    const args_len = readSyscallArg(bytes, 3);
    const stdio_ptr = readSyscallArg(bytes, 4);

    const args_slice = try getAlignedSlice(gpa, bytes, args_ptr, args_len) orelse
        return .{ .err = .misaligned };
    if (args_len % 0x40 != 0)
        return .{ .err = .misaligned };
    const argv: [][]const u8 = try gpa.alloc([]const u8, args_len / 0x40);
    defer gpa.free(argv);
    for (0..argv.len, argv) |i, *a| {
        const args_slice_part = args_slice[i * (0x40 / 8) ..][0 .. 0x40 / 8];
        const ptr, const len = @as([2]u32, @bitCast(args_slice_part.*));
        a.* = try getAlignedSlice(gpa, bytes, ptr, len) orelse return .{ .err = .misaligned };
    }

    const stdio_slice = try getAlignedSlice(gpa, bytes, stdio_ptr, 0x60) orelse
        return .{ .err = .misaligned };
    const stdio_ints = @as([3]u32, @bitCast(stdio_slice[0 .. 0x60 / 8].*));
    var stdio: [3]std.process.SpawnOptions.StdIo = undefined;
    for (stdio_ints, &stdio) |int, *s| {
        if (int & 0x8000_0000 == 0) {
            const file = ctx.fdToFile(int) orelse return .{ .err = .not_open };
            s.* = .{ .file = file };
        } else switch (int & 0x7fff_ffff) {
            0 => s.* = .ignore,
            1 => s.* = .inherit,
            2 => s.* = .pipe,
            else => return .{ .err = .invalid_stdio },
        }
    }

    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = stdio[0],
        .stdout = stdio[1],
        .stderr = stdio[2],
    }) catch return .{ .err = .spawn_failed };

    inline for (0..3, stdio, .{ "stdin", "stdout", "stderr" }) |i, s, name| {
        if (s == .pipe) {
            const file: Io.File = @field(child, name).?;
            const fd = try ctx.addFile(gpa, file);
            stdio_slice[i * (0x20 / 8) ..][0 .. 0x20 / 8].* = @bitCast(fd);
        }
    }

    const child_pid = try ctx.addPid(gpa, child.id.?);
    return .{ .val = @intCast(child_pid) };
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
