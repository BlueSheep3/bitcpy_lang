const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const ParseError = error{};
pub fn parseCode(code: []const u8, gpa: Alloc) ParseError!ArrayList(u8) {}

pub const RunError = error{};
pub fn runProgram(bytes: *ArrayList(u8), gpa: Alloc) RunError!void {}
