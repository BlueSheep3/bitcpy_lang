const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const output_exe = b.option(bool, "outputexe", "output an executable") orelse true;
    const output_dylib = b.option(bool, "outputdylib", "output a dynamic library") orelse false;

    const mod = b.addModule("bitcpy_lang", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const run_mod_tests = b.addRunArtifact(b.addTest(.{
        .root_module = mod,
    }));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    if (output_exe) {
        const exe = b.addExecutable(.{
            .name = "bitcpy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "bitcpy_lang", .module = mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_exe_tests = b.addRunArtifact(b.addTest(.{
            .root_module = exe.root_module,
        }));
        test_step.dependOn(&run_exe_tests.step);
    }

    if (output_dylib) {
        const dylib = b.addLibrary(.{
            .name = "bitcpy",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/dylib.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "bitcpy_lang", .module = mod },
                },
                .link_libc = true,
            }),
        });
        b.installArtifact(dylib);

        const run_dylib_tests = b.addRunArtifact(b.addTest(.{
            .root_module = dylib.root_module,
        }));
        test_step.dependOn(&run_dylib_tests.step);
    }
}
