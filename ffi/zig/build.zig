// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Zig build script for hpm-http-client-rsr.
// Tested against Zig 0.15.x.
//
// Outputs:
//   zig-out/lib/libhpm_http_client.so   (dynamic)
//   zig-out/lib/libhpm_http_client.a    (static)
//
// Tests:
//   zig build test    runs the Zig-side test suite in src/main.zig

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const shared = b.addLibrary(.{
        .name = "hpm_http_client",
        .root_module = root_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    const static = b.addLibrary(.{
        .name = "hpm_http_client",
        .root_module = root_mod,
        .linkage = .static,
    });
    b.installArtifact(static);

    const tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
