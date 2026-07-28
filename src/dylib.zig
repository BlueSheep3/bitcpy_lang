const std = @import("std");
const bitcpy_lang = @import("bitcpy_lang");

pub const ExternSliceU8 = extern struct {
    ptr: ?[*]u8,
    len: usize,
};

/// If an error occurs, the `ptr` field of the returned value will be `null`.
pub export fn parseCode(code_ptr: [*]const u8, code_len: usize) ExternSliceU8 {
    const code: []const u8 = code_ptr[0..code_len];

    const null_slice: ExternSliceU8 = .{ .ptr = null, .len = 0 };
    const gpa = std.heap.c_allocator;

    var bytes = bitcpy_lang.parseCode(gpa, code) catch return null_slice;
    bytes.shrinkToLen(gpa) catch {
        bytes.deinit(gpa);
        return null_slice;
    };

    return .{
        .ptr = bytes.items.ptr,
        .len = bytes.items.len,
    };
}

pub const RunOptions = packed struct(u8) {
    trace_command: bool = false,
    trace_memory: bool = false,
    _: u6 = 0,
};

/// This function only returns if an error occured.
pub export fn runProgram(bytes_ptr: [*]const u8, bytes_len: usize, opts: RunOptions) void {
    const gpa = std.heap.c_allocator;
    var io = std.Io.Threaded.init(gpa, .{});

    const owned = gpa.dupe(u8, bytes_ptr[0..bytes_len]) catch return;
    var bytes: std.ArrayList(u8) = .fromOwnedSlice(owned);
    defer bytes.deinit(gpa);

    const run_opts: bitcpy_lang.RunOptions = .{
        .trace_command = opts.trace_command,
        .trace_memory = opts.trace_memory,
    };
    bitcpy_lang.runProgram(gpa, io.io(), &bytes, run_opts) catch return;
}
