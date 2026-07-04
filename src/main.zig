const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

const bitcpy_lang = @import("bitcpy_lang");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = try parseArgs(args, init.io);
    switch (parsed) {
        .exit => return,
        .run => |r| {
            const code = try readFile(r.filename, init.gpa, init.io);
            defer init.gpa.free(code);
            var bytes = try bitcpy_lang.parseCode(init.gpa, code);
            defer bytes.deinit(init.gpa);
            try bitcpy_lang.runProgram(init.gpa, &bytes);
            try print(init.io, .stdout(), "Program terminated with end state:\n", .{});
            try printProgramBytes(init.io, bytes.items);
        },
    }
}

fn printProgramBytes(io: Io, bytes: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writer = &file_writer.interface;

    for (bytes, 0..) |byte, i| {
        const lower = byte % 16;
        const higher = byte >> 4;
        try writer.print("{x}{x}", .{ lower, higher });
        if (i % 4 == 3)
            try writer.writeAll(if (i % 32 == 31) "\n" else " ");
    }

    try writer.flush();
}

fn readFile(filename: []const u8, gpa: Alloc, io: Io) ![]u8 {
    const file = try Io.Dir.openFile(.cwd(), io, filename, .{ .allow_directory = false });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const stat = try file.stat(io);
    return reader.interface.readAlloc(gpa, @intCast(stat.size));
}

const ParseArgsResult = union(enum) {
    exit,
    run: struct {
        filename: []const u8,
        extraargs: []const []const u8,
    },
};

fn parseArgs(args: []const []const u8, io: Io) !ParseArgsResult {
    var i: usize = 1; // skip the path of the interpreter
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len != 0 and arg[0] != '-')
            break;

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }

        if (isArg(arg, "-h", "--help")) {
            try printHelp(io);
            return .exit;
        } else if (isArg(arg, "-v", "--version")) {
            try print(io, .stdout(), "bitcpy_lang 0.0.0\n", .{});
        } else {
            try print(io, .stderr(), "unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
        // TODO other arguments
    }
    if (i == args.len) {
        try print(io, .stderr(), "no filename specified\n", .{});
        return error.MissingFilename;
    }

    return .{ .run = .{
        .filename = args[i],
        .extraargs = args[i + 1 ..],
    } };
}

fn isArg(given: []const u8, comptime expected_short: ?[]const u8, comptime expected_long: []const u8) bool {
    var is_short = false;
    if (expected_short) |s| is_short = std.mem.eql(u8, given, s);
    return is_short or std.mem.eql(u8, given, expected_long);
}

fn printHelp(io: Io) !void {
    try print(io, .stdout(),
        \\Interpreter for the bitcpy programming language.
        \\
        \\Usage: bitcpy [options] [filename] [extraoptions]
        \\
        \\This will run the file called [filename] and pass [extraoptions] to it.
        \\
        \\Options:
        \\
        \\  -h, --help       print out this help message and exit
        \\  -v, --version    print out version information and exit
        \\  --               force the argument after this to be interpreted as the filename
        \\
    , .{});
}

fn print(io: Io, file: Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buffer);
    const writer = &file_writer.interface;
    try writer.print(fmt, args);
    try writer.flush();
}
