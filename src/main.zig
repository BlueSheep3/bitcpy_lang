const std = @import("std");
const Io = std.Io;

const bitcpy_lang = @import("bitcpy_lang");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    while (args.next()) |arg| {
        if (isArg(arg, "-h", "--help")) print_help();
        // TODO other arguments
    }

    // TODO run program
}

fn isArg(given: []const u8, comptime expected_short: ?[]const u8, comptime expected_long: []const u8) bool {
    var is_short = false;
    if (expected_short) |s| is_short = std.mem.eql(u8, given, s);
    return is_short or std.mem.eql(u8, given, expected_long);
}

fn print_help(io: Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.writeAll(
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
    );
    try stdout_writer.flush();
}
