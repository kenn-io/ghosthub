from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS_DIR))

import libghostty_bootstrap as bootstrap  # noqa: E402


class LibghosttyBootstrapTests(unittest.TestCase):
    def test_render_build_command_uses_repo_bootstrap_flags(self) -> None:
        # Shield the baseline from a caller's real
        # LIBGHOSTTY_ZIG_BUILD_ARGS (a supported override).
        with mock.patch.dict("os.environ", clear=True):
            command = bootstrap.render_build_command(
                "/opt/homebrew/bin/zig",
                "native",
                "Debug",
            )

        self.assertEqual(
            command,
            [
                "/opt/homebrew/bin/zig",
                "build",
                "-Dapp-runtime=none",
                "-Demit-xcframework=true",
                "-Demit-macos-app=false",
                "-Demit-themes=false",
                "-Di18n=false",
                "-Dsentry=false",
                "-Doptimize=Debug",
                "-Dxcframework-target=native",
            ],
        )

    def test_render_build_command_appends_env_zig_build_args(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {
                "LIBGHOSTTY_ZIG_BUILD_ARGS":
                    "--sysroot /tmp/patched-sdk"
            },
        ):
            command = bootstrap.render_build_command(
                "/opt/homebrew/bin/zig",
                "native",
                "Debug",
            )

        self.assertEqual(
            command[-2:], ["--sysroot", "/tmp/patched-sdk"]
        )

    def test_render_build_command_ignores_empty_env_zig_build_args(self) -> None:
        with mock.patch.dict(
            "os.environ", {"LIBGHOSTTY_ZIG_BUILD_ARGS": "  "}
        ):
            command = bootstrap.render_build_command(
                "/opt/homebrew/bin/zig",
                "native",
                "Debug",
            )

        self.assertEqual(command[-1], "-Dxcframework-target=native")

    def test_main_print_command_accepts_aarch64_xcframework_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            self._create_repo_layout(repo_root)

            with (
                mock.patch.object(
                    bootstrap,
                    "resolve_tool",
                    return_value="/opt/homebrew/bin/zig",
                ),
                mock.patch("builtins.print") as print_mock,
            ):
                result = bootstrap.main(
                    [
                        "--repo-root",
                        str(repo_root),
                        "--zig",
                        "zig",
                        "--xcframework-target",
                        "aarch64",
                        "--print-command",
                    ]
                )

            self.assertEqual(result, 0)
            print_mock.assert_called_once()
            self.assertIn(
                "-Dxcframework-target=aarch64",
                print_mock.call_args.args[0],
            )

    def test_main_print_command_defaults_to_aarch64_xcframework_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            self._create_repo_layout(repo_root)

            with (
                mock.patch.object(
                    bootstrap,
                    "resolve_tool",
                    return_value="/opt/homebrew/bin/zig",
                ),
                mock.patch("builtins.print") as print_mock,
            ):
                result = bootstrap.main(
                    [
                        "--repo-root",
                        str(repo_root),
                        "--zig",
                        "zig",
                        "--print-command",
                    ]
                )

            self.assertEqual(result, 0)
            print_mock.assert_called_once()
            self.assertIn(
                "-Dxcframework-target=aarch64",
                print_mock.call_args.args[0],
            )

    def test_public_header_patch_upgrades_old_config_load_signature(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            header = Path(tmpdir) / "ghostty.h"
            header.write_text(
                """ghostty_config_t ghostty_config_new();
void ghostty_config_load_file(ghostty_config_t, const char*);
void ghostty_config_finalize(ghostty_config_t);
void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
bool ghostty_surface_process_exited(ghostty_surface_t);
void ghostty_surface_refresh(ghostty_surface_t);
void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_complete_clipboard_request(ghostty_surface_t,
                                                const char*,
                                                void*,
                                                bool);
"""
            )

            bootstrap.patch_public_header(header)

            contents = header.read_text()
            self.assertIn(
                "void ghostty_config_load_file(ghostty_config_t, const char*, size_t);",
                contents,
            )
            self.assertNotIn(
                "void ghostty_config_load_file(ghostty_config_t, const char*);",
                contents,
            )

    def _make_archive(
        self,
        workdir: Path,
        name: str,
        symbol: str,
        *,
        arch: str | None = None,
    ) -> Path:
        source = workdir / f"{symbol}.c"
        source.write_text(f"int {symbol}(void) {{ return 1; }}\n")
        obj = workdir / f"{symbol}.o"
        command = ["cc"]
        if arch is not None:
            command.extend(["-arch", arch])
        command.extend(["-c", str(source), "-o", str(obj)])
        subprocess.run(
            command, check=True
        )
        archive = workdir / name
        subprocess.run(
            ["ar", "-q", str(archive), str(obj)],
            check=True,
            capture_output=True,
        )
        return archive

    @unittest.skipUnless(
        sys.platform == "darwin" and shutil.which("cc"),
        "needs macOS cc/ar/libtool",
    )
    def test_rebuild_fat_archive_restores_dropped_members(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir)
            alpha = self._make_archive(workdir, "libalpha.a", "alpha_fn")
            beta = self._make_archive(workdir, "libbeta.a", "beta_fn")
            # The broken fat archive only carries alpha, mimicking
            # libtool having dropped beta's member.
            fat = workdir / "libghostty-fat.a"
            shutil.copy2(alpha, fat)

            self.assertFalse(
                bootstrap.archive_defines_symbol(fat, "_beta_fn")
            )

            bootstrap.rebuild_fat_archive(fat, [alpha, beta])

            self.assertTrue(
                bootstrap.archive_defines_symbol(fat, "_alpha_fn")
            )
            self.assertTrue(
                bootstrap.archive_defines_symbol(fat, "_beta_fn")
            )

    @unittest.skipUnless(
        sys.platform == "darwin" and shutil.which("cc") and shutil.which("lipo"),
        "needs macOS cc/ar/libtool/lipo",
    )
    def test_repair_fat_archive_preserves_xcframework_slice_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            paths = self._paths(repo_root, xcframework_target="aarch64")
            source_root = paths.source_checkout_root
            cache_root = source_root / ".zig-cache" / "o"
            arm_cache = cache_root / "arm64"
            x86_cache = cache_root / "x86_64"
            arm_cache.mkdir(parents=True)
            x86_cache.mkdir(parents=True)
            slice_dir = (
                source_root
                / "macos"
                / "GhosttyKit.xcframework"
                / "macos-arm64"
            )
            slice_dir.mkdir(parents=True)
            fat = slice_dir / bootstrap.FAT_ARCHIVE_NAME

            sentinel_only = self._make_archive(
                Path(tmpdir),
                "libbroken.a",
                "ghostty_app_new",
                arch="arm64",
            )
            shutil.copy2(sentinel_only, fat)
            arm_component = self._make_archive(
                arm_cache,
                "libghostty.a",
                "ghostty_app_new",
                arch="arm64",
            )
            arm_dependency = self._make_archive(
                arm_cache,
                "libdependency.a",
                "dependency_fn",
                arch="arm64",
            )
            x86_component = self._make_archive(
                x86_cache,
                "libx86_only.a",
                "x86_only_fn",
                arch="x86_64",
            )
            del arm_component, arm_dependency, x86_component

            bootstrap.repair_fat_archives(paths)

            self.assertTrue(
                bootstrap.archive_defines_symbol(
                    fat,
                    bootstrap.GHOSTTY_SENTINEL_SYMBOL,
                )
            )
            self.assertEqual(bootstrap.archive_archs(fat), ["arm64"])
            self.assertTrue(
                bootstrap.archive_defines_symbol(fat, "_dependency_fn")
            )
            self.assertFalse(
                bootstrap.archive_defines_symbol(fat, "_x86_only_fn")
            )

    @unittest.skipUnless(
        sys.platform == "darwin" and shutil.which("cc"),
        "needs macOS cc/ar/libtool",
    )
    def test_artifact_state_flags_archive_missing_ghostty_api(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            workdir = Path(tmpdir)
            artifacts = bootstrap.ArtifactPaths.from_root(workdir)
            slice_dir = artifacts.xcframework_path / "macos-arm64"
            slice_dir.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            metadata = bootstrap.VendorMetadata(
                source="https://example.com/ghostty.git",
                tag="v0.0.0",
                commit="abc123",
                required_zig_version="0.15.2",
            )
            artifacts.manifest_path.write_text(
                json.dumps(
                    {
                        "ghosttyCommit": "abc123",
                        "ghosthubBootstrapVersion":
                            bootstrap.GHOSTHUB_BOOTSTRAP_VERSION,
                        "xcframeworkTarget": "native",
                        "optimize": "Debug",
                        "requiredZigVersion": "0.15.2",
                        "ghosttyBundleID":
                            bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID,
                        "i18nEnabled": False,
                        "sentryEnabled": False,
                        "ghosttyConfigLoadExport": True,
                        "surfaceInjectOutputExport": True,
                        "childWriteCallback": True,
                        "embeddedEnvIsolation": True,
                        "termProgram":
                            bootstrap.GHOSTHUB_TERM_PROGRAM,
                        "macosLoginQuiet": True,
                    }
                )
            )

            broken = self._make_archive(workdir, "libbroken.a", "other_fn")
            shutil.copy2(broken, slice_dir / "libghostty-fat.a")
            message = bootstrap.artifact_state_message(
                artifacts, metadata, "native", "Debug"
            )
            self.assertIsNotNone(message)
            assert message is not None
            self.assertIn("ghostty API", message)

            healthy = self._make_archive(
                workdir, "libhealthy.a", "ghostty_app_new"
            )
            shutil.copy2(healthy, slice_dir / "libghostty-fat.a")
            self.assertIsNone(
                bootstrap.artifact_state_message(
                    artifacts, metadata, "native", "Debug"
                )
            )

    def test_component_archives_excludes_fat_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            cache = Path(tmpdir) / ".zig-cache" / "o" / "abc"
            cache.mkdir(parents=True)
            (cache / "libdep.a").write_bytes(b"!<arch>\n")
            (cache / "libghostty-fat.a").write_bytes(b"!<arch>\n")
            nested = Path(tmpdir) / ".zig-cache" / "o" / "def"
            nested.mkdir(parents=True)
            (nested / "libghostty.a").write_bytes(b"!<arch>\n")

            found = bootstrap.component_archives(
                Path(tmpdir) / ".zig-cache"
            )

            names = [p.name for p in found]
            self.assertEqual(names, ["libdep.a", "libghostty.a"])

    def test_clipboard_write_patch_marks_both_osc52_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            surface = Path(tmpdir) / "Surface.zig"
            surface.write_text(
                """    self.rt_surface.setClipboard(loc, &.{.{
        .mime = "text/plain",
        .data = buf,
    }}, confirm) catch |err| {
        return err;
    };

        .osc_52_write => |clipboard| try self.rt_surface.setClipboard(clipboard, &.{.{
            .mime = "text/plain",
            .data = data,
        }}, !confirmed),
"""
            )

            bootstrap.patch_clipboard_write_origin(surface)

            patched = surface.read_text()
            self.assertEqual(
                patched.count('application/x-ghosthub-osc52'),
                2,
            )
            self.assertIn(".data = buf", patched)
            self.assertIn(".data = data", patched)

    def test_apply_ghosthub_source_patches_exports_direct_config_loading(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            del metadata
            paths = self._paths(repo_root)
            build_config = paths.source_checkout_root / "src" / "build_config.zig"
            config_c_api = paths.source_checkout_root / "src" / "config" / "CApi.zig"
            header = paths.source_checkout_root / "include" / "ghostty.h"
            embedded = paths.source_checkout_root / "src" / "apprt" / "embedded.zig"
            apprt_surface = paths.source_checkout_root / "src" / "apprt" / "surface.zig"
            core_surface = paths.source_checkout_root / "src" / "Surface.zig"
            exec_zig = paths.source_checkout_root / "src" / "termio" / "Exec.zig"
            termio_zig = paths.source_checkout_root / "src" / "termio" / "Termio.zig"
            xcframework_enum = paths.source_checkout_root / "src" / "build" / "xcframework.zig"
            ghostty_xcframework = (
                paths.source_checkout_root / "src" / "build" / "GhosttyXCFramework.zig"
            )
            ghostty_xcodebuild = (
                paths.source_checkout_root / "src" / "build" / "GhosttyXcodebuild.zig"
            )
            shared_deps = (
                paths.source_checkout_root / "src" / "build" / "SharedDeps.zig"
            )

            build_config.parent.mkdir(parents=True, exist_ok=True)
            config_c_api.parent.mkdir(parents=True, exist_ok=True)
            header.parent.mkdir(parents=True, exist_ok=True)
            embedded.parent.mkdir(parents=True, exist_ok=True)
            apprt_surface.parent.mkdir(parents=True, exist_ok=True)
            core_surface.parent.mkdir(parents=True, exist_ok=True)
            exec_zig.parent.mkdir(parents=True, exist_ok=True)
            termio_zig.parent.mkdir(parents=True, exist_ok=True)
            xcframework_enum.parent.mkdir(parents=True, exist_ok=True)

            build_config.write_text(
                'pub const bundle_id = "com.mitchellh.ghostty";\n'
            )
            config_c_api.write_text(
                """export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}
"""
            )
            header.write_text(
                """ghostty_config_t ghostty_config_new();
void ghostty_config_free(ghostty_config_t);
ghostty_config_t ghostty_config_clone(ghostty_config_t);
void ghostty_config_load_cli_args(ghostty_config_t);
void ghostty_config_load_default_files(ghostty_config_t);
void ghostty_config_load_recursive_files(ghostty_config_t);
void ghostty_config_finalize(ghostty_config_t);
void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
bool ghostty_surface_process_exited(ghostty_surface_t);
void ghostty_surface_refresh(ghostty_surface_t);
void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_complete_clipboard_request(ghostty_surface_t,
                                                const char*,
                                                void*,
                                                bool);
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef struct {
  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;
"""
            )
            embedded.write_text(
                """    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        const alloc = self.app.core_app.alloc;
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            env.remove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) env.remove("LANGUAGE");
        }

        return env;
    }

    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {}

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,
    };

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }
"""
            )
            apprt_surface.write_text(
                "    /// The terminal has reported a change in the working directory.\n"
                "    pwd_change: WriteReq,\n"
                "\n"
                "    /// The terminal encountered a bell character.\n"
                "    ring_bell,\n"
            )
            core_surface.write_text(
                "/// This is set to true if our IO thread notifies us our child exited.\n"
                "/// This is used to determine if we need to confirm, hold open, etc.\n"
                "child_exited: bool = false,\n"
                "\n"
                "        .close => self.close(),\n"
                "\n"
                "        .child_exited => |v| self.childExited(v),\n"
                "\n"
                "fn childExited(self: *Surface, info: apprt.surface.Message.ChildExited) void {\n"
                "    // Mark our flag that we exited immediately\n"
                "    self.child_exited = true;\n"
                "\n"
                "    self.rt_surface.setClipboard(loc, &.{.{\n"
                "        .mime = \"text/plain\",\n"
                "        .data = buf,\n"
                "    }}, confirm) catch |err| {\n"
                "\n"
                "        .osc_52_write => |clipboard| try self.rt_surface.setClipboard(clipboard, &.{.{\n"
                "            .mime = \"text/plain\",\n"
                "            .data = data,\n"
                "        }}, !confirmed),\n"
            )
            exec_zig.write_text(
                """        const hush = if (passwd.home) |home| hush: {
            var dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
                log.warn(
                    "failed to open home dir, not checking for hushlogin err={}",
                    .{err},
                );
                break :hush false;
            };
            defer dir.close();

            break :hush if (dir.access(".hushlogin", .{})) true else |_| false;
        } else false;

        try args.append(alloc, "/usr/bin/login");
        if (hush) try args.append(alloc, "-q");
        try args.append(alloc, "-flp");
        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);
"""
            )
            termio_zig.write_text(
                "pub inline fn queueWrite(\n"
                "    self: *Termio,\n"
                "    td: *ThreadData,\n"
                "    data: []const u8,\n"
                "    linefeed: bool,\n"
                ") !void {\n"
                "    try self.backend.queueWrite(self.alloc, td, data, linefeed);\n"
                "}\n"
            )
            xcframework_enum.write_text(
                "pub const Target = enum { native, universal };\n"
            )
            ghostty_xcframework.write_text(
                """const GhosttyXCFramework = @This();

const Config = @import("Config.zig");
const GhosttyLib = @import("GhosttyLib.zig");

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    const xcframework = XCFrameworkStep.create(b, .{
        .libraries = switch (target) {
            .native => &.{.{
                .library = macos_native.output,
                .headers = b.path("include"),
                .dsym = macos_native.dsym,
            }},
        },
    });
}
"""
            )
            ghostty_xcodebuild.write_text(
                """const builtin = @import("builtin");

pub fn init() void {
    const xc_arch: ?[]const u8 = switch (deps.xcframework.target) {
        .universal => null,

        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
    };
}
"""
            )
            shared_deps.write_text(
                '''        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
'''
            )

            bootstrap.apply_ghosthub_source_patches(paths)

            self.assertIn(
                f'pub const bundle_id = "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}";',
                build_config.read_text(),
            )
            self.assertIn(
                "export fn ghostty_config_load_file(",
                config_c_api.read_text(),
            )
            self.assertIn(
                "void ghostty_config_load_file(ghostty_config_t, const char*, size_t);",
                header.read_text(),
            )
            self.assertIn(
                "int ghostty_surface_child_pid(ghostty_surface_t);",
                header.read_text(),
            )
            self.assertIn(
                "int ghostty_surface_child_exit_code(ghostty_surface_t);",
                header.read_text(),
            )
            self.assertIn(
                "void ghostty_surface_inject_output(ghostty_surface_t, const char*, uintptr_t);",
                header.read_text(),
            )
            self.assertIn(
                "typedef void (*ghostty_runtime_child_write_cb)(void*, const char*, uintptr_t);",
                header.read_text(),
            )
            self.assertIn(
                "ghostty_runtime_child_write_cb child_write_cb;",
                header.read_text(),
            )
            self.assertIn(
                "try stripGhosthubLauncherEnv(alloc, &env);",
                embedded.read_text(),
            )
            self.assertIn(
                "export fn ghostty_surface_child_pid(surface: *Surface) c_int {",
                embedded.read_text(),
            )
            self.assertIn(
                "export fn ghostty_surface_child_exit_code(surface: *Surface) c_int {",
                embedded.read_text(),
            )
            self.assertIn(
                "export fn ghostty_surface_inject_output(",
                embedded.read_text(),
            )
            self.assertIn(
                "fn stripGhosthubLauncherEnv(",
                embedded.read_text(),
            )
            self.assertIn(
                '"EDITOR",',
                embedded.read_text(),
            )
            self.assertIn(
                '"VISUAL",',
                embedded.read_text(),
            )
            self.assertIn(
                "child_write: ?*const fn (SurfaceUD, [*]const u8, usize) callconv(.c) void = null,",
                embedded.read_text(),
            )
            self.assertIn(
                "pub fn childWrite(self: *const Surface, data: []const u8) void {",
                embedded.read_text(),
            )
            self.assertIn(
                "child_write: WriteReq,",
                apprt_surface.read_text(),
            )
            self.assertIn(
                ".child_write => |w| {",
                core_surface.read_text(),
            )
            self.assertIn(
                "self.rt_surface.childWrite(w.slice());",
                core_surface.read_text(),
            )
            self.assertIn(
                "child_exit_code: ?u32 = null,",
                core_surface.read_text(),
            )
            self.assertIn(
                "self.child_exit_code = info.exit_code;",
                core_surface.read_text(),
            )
            self.assertIn(
                ".child_write = req",
                termio_zig.read_text(),
            )
            self.assertIn(
                "req.deinit();",
                termio_zig.read_text(),
            )
            self.assertIn(
                '        try args.append(alloc, "/usr/bin/login");\n'
                '        try args.append(alloc, "-q");\n'
                '        try args.append(alloc, "-flp");\n',
                exec_zig.read_text(),
            )
            self.assertNotIn(
                "const hush = if (passwd.home)",
                exec_zig.read_text(),
            )
            self.assertIn(
                f'try env.put("TERM_PROGRAM", "{bootstrap.GHOSTHUB_TERM_PROGRAM}");',
                exec_zig.read_text(),
            )
            self.assertIn(
                "pub const Target = enum { native, universal, aarch64 };",
                xcframework_enum.read_text(),
            )
            self.assertIn(
                "Config.genericMacOSTarget(b, .aarch64)",
                ghostty_xcframework.read_text(),
            )
            self.assertIn(
                '        },\n\n        .aarch64 => "arm64",\n',
                ghostty_xcodebuild.read_text(),
            )

    def test_patch_term_program_env_sets_ghosthub_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "Exec.zig"
            path.write_text(
                """        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);
"""
            )

            bootstrap.patch_term_program_env(path)

            self.assertIn(
                f'try env.put("TERM_PROGRAM", "{bootstrap.GHOSTHUB_TERM_PROGRAM}");',
                path.read_text(),
            )

    def test_patch_libintl_i18n_guard_skips_static_gettext(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "SharedDeps.zig"
            path.write_text(
                '''        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
'''
            )

            bootstrap.patch_libintl_i18n_guard(path)
            bootstrap.patch_libintl_i18n_guard(path)

            self.assertIn(
                "if (self.config.i18n) {",
                path.read_text(),
            )

    def test_patch_surface_inject_output_export_adds_capi_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            embedded = Path(tmp) / "embedded.zig"
            embedded.write_text(
                "    export fn ghostty_surface_text(\n"
                "        surface: *Surface,\n"
                "        ptr: [*]const u8,\n"
                "        len: usize,\n"
                "    ) void {\n"
                "        surface.textCallback(ptr[0..len]);\n"
                "    }\n"
            )
            bootstrap.patch_surface_inject_output_export(embedded)
            contents = embedded.read_text()
            self.assertIn(
                "export fn ghostty_surface_inject_output(", contents
            )
            self.assertIn(
                "surface.core_surface.io.processOutput(ptr[0..len]);", contents
            )
            # Idempotency: double-apply must not duplicate the export.
            bootstrap.patch_surface_inject_output_export(embedded)
            self.assertEqual(
                embedded.read_text().count("ghostty_surface_inject_output"), 1
            )

    def test_patch_clipboard_request_type_export_adds_capi_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            embedded = Path(tmp) / "embedded.zig"
            embedded.write_text(
                """    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {}
"""
            )

            bootstrap.patch_clipboard_request_type_export(embedded)
            contents = embedded.read_text()
            self.assertIn(
                "export fn ghostty_clipboard_request_type(", contents
            )
            self.assertIn("std.meta.activeTag(state.*)", contents)

            bootstrap.patch_clipboard_request_type_export(embedded)
            self.assertEqual(
                embedded.read_text().count(
                    "export fn ghostty_clipboard_request_type("
                ),
                1,
            )

    def test_patch_public_header_declares_inject_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            header = Path(tmp) / "ghostty.h"
            header.write_text(
                "ghostty_config_t ghostty_config_new();\n"
                "void ghostty_config_free(ghostty_config_t);\n"
                "ghostty_config_t ghostty_config_clone(ghostty_config_t);\n"
                "void ghostty_config_load_cli_args(ghostty_config_t);\n"
                "void ghostty_config_load_default_files(ghostty_config_t);\n"
                "void ghostty_config_load_recursive_files(ghostty_config_t);\n"
                "void ghostty_config_finalize(ghostty_config_t);\n"
                "void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);\n"
                "bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);\n"
                "bool ghostty_surface_process_exited(ghostty_surface_t);\n"
                "void ghostty_surface_refresh(ghostty_surface_t);\n"
                "void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);\n"
                "void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);\n"
                "void ghostty_surface_complete_clipboard_request(ghostty_surface_t,\n"
                "                                                const char*,\n"
                "                                                void*,\n"
                "                                                bool);\n"
            )
            bootstrap.patch_public_header(header)
            contents = header.read_text()
            self.assertIn(
                "void ghostty_surface_inject_output(ghostty_surface_t, const char*, uintptr_t);",
                contents,
            )
            # Declaration sits between text and preedit.
            self.assertLess(
                contents.index("ghostty_surface_text("),
                contents.index("ghostty_surface_inject_output("),
            )
            self.assertLess(
                contents.index("ghostty_surface_inject_output("),
                contents.index("ghostty_surface_preedit("),
            )
            self.assertIn(
                "ghostty_clipboard_request_e ghostty_clipboard_request_type(void*);",
                contents,
            )

    def test_patch_child_write_header_adds_typedef_and_field(self):
        with tempfile.TemporaryDirectory() as tmp:
            header = Path(tmp) / "ghostty.h"
            header.write_text(
                "typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);\n"
                "typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t,\n"
                "                                          ghostty_target_s,\n"
                "                                          ghostty_action_s);\n"
                "typedef struct {\n"
                "  void* userdata;\n"
                "  bool supports_selection_clipboard;\n"
                "  ghostty_runtime_wakeup_cb wakeup_cb;\n"
                "  ghostty_runtime_action_cb action_cb;\n"
                "  ghostty_runtime_read_clipboard_cb read_clipboard_cb;\n"
                "  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;\n"
                "  ghostty_runtime_write_clipboard_cb write_clipboard_cb;\n"
                "  ghostty_runtime_close_surface_cb close_surface_cb;\n"
                "} ghostty_runtime_config_s;\n"
            )
            bootstrap.patch_child_write_header(header)
            contents = header.read_text()
            self.assertIn(
                "typedef void (*ghostty_runtime_child_write_cb)(void*, const char*, uintptr_t);",
                contents,
            )
            self.assertIn("ghostty_runtime_child_write_cb child_write_cb;", contents)
            bootstrap.patch_child_write_header(header)
            self.assertEqual(header.read_text().count("child_write_cb;"), 1)

    def test_patch_child_write_message_adds_union_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            surface_zig = Path(tmp) / "surface.zig"
            surface_zig.write_text(
                "    /// The terminal has reported a change in the working directory.\n"
                "    pwd_change: WriteReq,\n"
                "\n"
                "    /// The terminal encountered a bell character.\n"
                "    ring_bell,\n"
            )
            bootstrap.patch_child_write_message(surface_zig)
            contents = surface_zig.read_text()
            self.assertIn("child_write: WriteReq,", contents)
            bootstrap.patch_child_write_message(surface_zig)
            self.assertEqual(surface_zig.read_text().count("child_write: WriteReq,"), 1)

    def test_patch_child_write_dispatch_adds_handle_message_arm(self):
        with tempfile.TemporaryDirectory() as tmp:
            surface = Path(tmp) / "Surface.zig"
            surface.write_text(
                "        .close => self.close(),\n"
                "\n"
                "        .child_exited => |v| self.childExited(v),\n"
            )
            bootstrap.patch_child_write_dispatch(surface)
            contents = surface.read_text()
            self.assertIn(".child_write => |w| {", contents)
            self.assertIn("self.rt_surface.childWrite(w.slice());", contents)
            bootstrap.patch_child_write_dispatch(surface)
            self.assertEqual(surface.read_text().count(".child_write => |w| {"), 1)

    def test_patch_child_write_embedded_adds_option_and_method(self):
        with tempfile.TemporaryDirectory() as tmp:
            embedded = Path(tmp) / "embedded.zig"
            embedded.write_text(
                "        /// Close the current surface given by this function.\n"
                "        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,\n"
                "    };\n"
                "\n"
                "    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {\n"
                "        return self.cursor_pos;\n"
                "    }\n"
            )
            bootstrap.patch_child_write_embedded(embedded)
            contents = embedded.read_text()
            self.assertIn(
                "child_write: ?*const fn (SurfaceUD, [*]const u8, usize) callconv(.c) void = null,",
                contents,
            )
            self.assertIn(
                "pub fn childWrite(self: *const Surface, data: []const u8) void {",
                contents,
            )
            bootstrap.patch_child_write_embedded(embedded)
            self.assertEqual(
                embedded.read_text().count(
                    "pub fn childWrite(self: *const Surface, data: []const u8) void {"
                ),
                1,
            )

    def test_patch_child_write_termio_mirrors_queue_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            termio = Path(tmp) / "Termio.zig"
            termio.write_text(
                "pub inline fn queueWrite(\n"
                "    self: *Termio,\n"
                "    td: *ThreadData,\n"
                "    data: []const u8,\n"
                "    linefeed: bool,\n"
                ") !void {\n"
                "    try self.backend.queueWrite(self.alloc, td, data, linefeed);\n"
                "}\n"
            )
            bootstrap.patch_child_write_termio(termio)
            contents = termio.read_text()
            self.assertIn(".child_write = req", contents)
            self.assertIn("req.deinit();", contents)
            self.assertIn(
                "self.surface_mailbox.push(.{ .child_write = req }, .{ .instant = {} }) == 0",
                contents,
            )
            bootstrap.patch_child_write_termio(termio)
            self.assertEqual(termio.read_text().count(".child_write = req"), 1)
            self.assertEqual(termio.read_text().count("req.deinit();"), 1)

    def test_patch_apple_silicon_xcframework_target_adds_arm64_only_option(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            target_enum = root / "src" / "build" / "xcframework.zig"
            target_enum.parent.mkdir(parents=True)
            target_enum.write_text(
                "pub const Target = enum { native, universal };\n"
            )
            ghostty_xcframework = root / "src" / "build" / "GhosttyXCFramework.zig"
            ghostty_xcframework.write_text(
                """const GhosttyXCFramework = @This();

const Config = @import("Config.zig");
const GhosttyLib = @import("GhosttyLib.zig");

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    const xcframework = XCFrameworkStep.create(b, .{
        .libraries = switch (target) {
            .native => &.{.{
                .library = macos_native.output,
                .headers = b.path("include"),
                .dsym = macos_native.dsym,
            }},
        },
    });
}
"""
            )
            ghostty_xcodebuild = root / "src" / "build" / "GhosttyXcodebuild.zig"
            ghostty_xcodebuild.write_text(
                """const builtin = @import("builtin");

pub fn init() void {
    const xc_arch: ?[]const u8 = switch (deps.xcframework.target) {
        .universal => null,

        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
    };
}
"""
            )

            bootstrap.patch_apple_silicon_xcframework_target(
                target_enum,
                ghostty_xcframework,
                ghostty_xcodebuild,
            )
            bootstrap.patch_apple_silicon_xcframework_target(
                target_enum,
                ghostty_xcframework,
                ghostty_xcodebuild,
            )

            self.assertIn(
                "pub const Target = enum { native, universal, aarch64 };",
                target_enum.read_text(),
            )
            contents = ghostty_xcframework.read_text()
            self.assertEqual(contents.count("const macos_aarch64"), 1)
            self.assertIn(
                "Config.genericMacOSTarget(b, .aarch64)",
                contents,
            )
            self.assertIn(".aarch64 => &.{.{", contents)
            self.assertIn(
                '        },\n\n        .aarch64 => "arm64",\n',
                ghostty_xcodebuild.read_text(),
            )

    def test_ensure_supported_zig_version_rejects_incompatible_version(self) -> None:
        with self.assertRaisesRegex(
            bootstrap.BootstrapError,
            "requires Zig 0.15.2 or newer, but found 0.14.1",
        ):
            bootstrap.ensure_supported_zig_version("0.14.1", "0.15.2")

    def test_ensure_metal_toolchain_reports_actionable_install_hint(self) -> None:
        with mock.patch.object(
            bootstrap,
            "read_tool_output",
            side_effect=bootstrap.subprocess.CalledProcessError(1, ["xcrun"]),
        ):
            with self.assertRaisesRegex(bootstrap.BootstrapError, "downloadComponent MetalToolchain"):
                bootstrap.ensure_metal_toolchain("/usr/bin/xcrun")

    def test_zig_executable_architecture_reads_zig_env_target(self) -> None:
        with mock.patch.object(
            bootstrap,
            "read_tool_output",
            return_value='.target = "x86_64-macos.26.5...26.5-none",',
        ):
            architecture = bootstrap.zig_executable_architecture("/usr/bin/zig")

        self.assertEqual(architecture, "x86_64")

    def test_find_compatible_macos_sdk_selects_newest_target_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            sdk_root = Path(tmpdir)
            older = self._write_sdk_stub(
                sdk_root / "MacOSX15.2.sdk",
                "arm64-macos, x86_64-macos",
            )
            newer = self._write_sdk_stub(
                sdk_root / "MacOSX15.4.sdk",
                "arm64-macos, x86_64-macos",
            )
            self._write_sdk_stub(
                sdk_root / "MacOSX26.5.sdk",
                "arm64e-macos, x86_64-macos",
            )

            selected = bootstrap.find_compatible_macos_sdk(
                frozenset(("arm64-macos",)),
                [sdk_root],
            )

            self.assertEqual(selected, newer.resolve())
            self.assertNotEqual(selected, older.resolve())

    def test_prepare_zig_build_environment_shims_incompatible_active_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir) / "repo"
            repo_root.mkdir()
            sdk_root = Path(tmpdir) / "SDKs"
            active = self._write_sdk_stub(
                sdk_root / "MacOSX26.5.sdk",
                "arm64e-macos, x86_64-macos",
            )
            fallback = self._write_sdk_stub(
                sdk_root / "MacOSX15.4.sdk",
                "arm64-macos, x86_64-macos",
            )

            with (
                mock.patch.object(bootstrap.platform, "system", return_value="Darwin"),
                mock.patch.object(
                    bootstrap,
                    "read_tool_output",
                    return_value=str(active),
                ),
                mock.patch.object(
                    bootstrap,
                    "macos_sdk_roots",
                    return_value=[sdk_root],
                ),
            ):
                environment = bootstrap.prepare_zig_build_environment(
                    repo_root,
                    "/usr/bin/xcrun",
                    "aarch64",
                    "aarch64",
                )

            shim = repo_root / ".build" / "libghostty-tools" / "xcrun"
            self.assertEqual(environment["PATH"].split(":")[0], str(shim.parent))
            self.assertTrue(shim.stat().st_mode & 0o100)
            selected = subprocess.run(
                [str(shim), "--sdk", "macosx", "--show-sdk-path"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.assertEqual(selected, str(fallback.resolve()))

    def test_intel_zig_aarch64_build_requires_both_sdk_targets(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir) / "repo"
            repo_root.mkdir()
            sdk_root = Path(tmpdir) / "SDKs"
            active = self._write_sdk_stub(
                sdk_root / "MacOSX26.5.sdk",
                "arm64e-macos, x86_64-macos",
            )
            fallback = self._write_sdk_stub(
                sdk_root / "MacOSX15.4.sdk",
                "arm64-macos, x86_64-macos",
            )

            with (
                mock.patch.object(bootstrap.platform, "system", return_value="Darwin"),
                mock.patch.object(
                    bootstrap,
                    "read_tool_output",
                    return_value=str(active),
                ),
                mock.patch.object(
                    bootstrap,
                    "macos_sdk_roots",
                    return_value=[sdk_root],
                ),
            ):
                environment = bootstrap.prepare_zig_build_environment(
                    repo_root,
                    "/usr/bin/xcrun",
                    "aarch64",
                    "x86_64",
                )

            shim = Path(environment["PATH"].split(":")[0]) / "xcrun"
            self.assertIn(str(fallback.resolve()), shim.read_text())

    def test_universal_build_requires_both_sdk_targets(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir) / "repo"
            repo_root.mkdir()
            sdk_root = Path(tmpdir) / "SDKs"
            active = self._write_sdk_stub(
                sdk_root / "MacOSX26.5.sdk",
                "arm64-macos",
            )
            fallback = self._write_sdk_stub(
                sdk_root / "MacOSX15.4.sdk",
                "arm64-macos, x86_64-macos",
            )

            with (
                mock.patch.object(bootstrap.platform, "system", return_value="Darwin"),
                mock.patch.object(
                    bootstrap,
                    "read_tool_output",
                    return_value=str(active),
                ),
                mock.patch.object(
                    bootstrap,
                    "macos_sdk_roots",
                    return_value=[sdk_root],
                ),
            ):
                environment = bootstrap.prepare_zig_build_environment(
                    repo_root,
                    "/usr/bin/xcrun",
                    "universal",
                    "aarch64",
                )

            shim = Path(environment["PATH"].split(":")[0]) / "xcrun"
            self.assertIn(str(fallback.resolve()), shim.read_text())

    def test_bootstrap_wraps_build_failures_with_setup_guidance(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            with (
                mock.patch.object(bootstrap, "ensure_source_checkout"),
                mock.patch.object(bootstrap, "apply_ghosthub_source_patches"),
                mock.patch.object(bootstrap, "resolve_tool", side_effect=lambda tool: f"/usr/bin/{tool}"),
                mock.patch.object(bootstrap, "read_tool_output", return_value="0.15.2"),
                mock.patch.object(bootstrap, "ensure_metal_toolchain"),
                mock.patch.object(bootstrap, "zig_executable_architecture", return_value="aarch64"),
                mock.patch.object(bootstrap, "prepare_zig_build_environment", return_value={}),
                mock.patch.object(
                    bootstrap.subprocess,
                    "run",
                    side_effect=bootstrap.subprocess.CalledProcessError(
                        1,
                        ["/usr/bin/zig", "build"],
                    ),
                ),
            ):
                with self.assertRaisesRegex(
                    bootstrap.BootstrapError,
                    "full Xcode installation selected via `xcode-select`",
                ):
                    bootstrap.bootstrap(
                        paths=paths,
                        metadata=metadata,
                        git="git",
                        zig="zig",
                        xcodebuild="xcodebuild",
                        xcrun="xcrun",
                        xcframework_target="native",
                        optimize="Debug",
                    )

    def _write_sdk_stub(self, sdk_path: Path, targets: str) -> Path:
        stub = sdk_path / "usr" / "lib" / "libSystem.B.tbd"
        stub.parent.mkdir(parents=True)
        stub.write_text(
            "--- !tapi-tbd\n"
            "tbd-version: 4\n"
            f"targets: [ {targets} ]\n"
            "install-name: '/usr/lib/libSystem.B.dylib'\n"
        )
        return sdk_path

    def test_bootstrap_is_noop_when_artifacts_are_current(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            self._write_ready_artifacts(paths.cached_artifacts, metadata)
            self._write_ready_artifacts(paths.staged_artifacts, metadata)

            with (
                mock.patch.object(bootstrap, "ensure_source_checkout") as ensure_source_checkout,
                mock.patch.object(bootstrap, "resolve_tool") as resolve_tool,
                mock.patch.object(bootstrap, "read_tool_output") as read_tool_output,
                mock.patch.object(bootstrap, "ensure_metal_toolchain") as ensure_metal_toolchain,
                mock.patch.object(bootstrap.subprocess, "run") as run,
            ):
                result = bootstrap.bootstrap(
                    paths=paths,
                    metadata=metadata,
                    git="git",
                    zig="zig",
                    xcodebuild="xcodebuild",
                    xcrun="xcrun",
                    xcframework_target="native",
                    optimize="Debug",
                )

            self.assertFalse(result.rebuilt_variant)
            self.assertFalse(result.staged_synced)
            ensure_source_checkout.assert_not_called()
            resolve_tool.assert_not_called()
            read_tool_output.assert_not_called()
            ensure_metal_toolchain.assert_not_called()
            run.assert_not_called()

    def test_bootstrap_syncs_cached_variant_into_staged_root_without_rebuild(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            self._write_ready_artifacts(paths.cached_artifacts, metadata)

            # Create a source checkout directory so the symlink can be created.
            paths.source_checkout_root.mkdir(parents=True, exist_ok=True)
            (paths.source_checkout_root / "zig-out" / "share" / "ghostty").mkdir(parents=True)

            with (
                mock.patch.object(bootstrap, "ensure_source_checkout") as ensure_source_checkout,
                mock.patch.object(bootstrap, "resolve_tool") as resolve_tool,
                mock.patch.object(bootstrap, "read_tool_output") as read_tool_output,
                mock.patch.object(bootstrap, "ensure_metal_toolchain") as ensure_metal_toolchain,
                mock.patch.object(bootstrap.subprocess, "run") as run,
            ):
                result = bootstrap.bootstrap(
                    paths=paths,
                    metadata=metadata,
                    git="git",
                    zig="zig",
                    xcodebuild="xcodebuild",
                    xcrun="xcrun",
                    xcframework_target="native",
                    optimize="Debug",
                )

            self.assertFalse(result.rebuilt_variant)
            self.assertTrue(result.staged_synced)
            self.assertTrue(paths.staged_artifacts.manifest_path.exists())
            self.assertEqual(
                json.loads(paths.staged_artifacts.manifest_path.read_text())["optimize"],
                "Debug",
            )

            source_link = paths.staged_artifacts.root / "source"
            self.assertTrue(
                source_link.is_symlink(),
                "Staged artifacts should symlink source to cached variant",
            )
            self.assertTrue(
                (source_link / "zig-out" / "share" / "ghostty").is_dir(),
                "Ghostty resources should be reachable via staged source symlink",
            )

            ensure_source_checkout.assert_not_called()
            resolve_tool.assert_not_called()
            read_tool_output.assert_not_called()
            ensure_metal_toolchain.assert_not_called()
            run.assert_not_called()

    def test_refresh_swiftpm_manifest_touches_package_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            del metadata
            package_manifest = repo_root / "Package.swift"
            package_manifest.write_text("// package manifest\n")
            paths = self._paths(repo_root)
            original_mtime = package_manifest.stat().st_mtime_ns

            time.sleep(0.01)
            bootstrap.refresh_swiftpm_manifest(paths)

            self.assertGreater(package_manifest.stat().st_mtime_ns, original_mtime)

    def test_artifact_state_reports_missing_bootstrap_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            message = bootstrap.artifact_state_message(
                paths.cached_artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty bootstrap artifacts are missing or stale. Run `python3 tools/bootstrap_libghostty.py` from the repo root.",
            )

    def test_artifact_state_reports_stale_manifest_when_commit_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                '  "ghosttyCommit": "different",\n'
                f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
                '  "embeddedEnvIsolation": true,\n'
                '  "macosLoginQuiet": true,\n'
                '  "ghosttyConfigLoadExport": true,\n'
                '  "sentryEnabled": false,\n'
                f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built against a different Ghostty revision. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_artifact_state_reports_stale_manifest_when_bootstrap_schema_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION - 1},\n'
                f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
                '  "embeddedEnvIsolation": true,\n'
                '  "macosLoginQuiet": true,\n'
                '  "ghosttyConfigLoadExport": true,\n'
                f'  "ghosttyCommit": "{metadata.commit}",\n'
                f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
                '  "sentryEnabled": false,\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built against an older Ghosthub bootstrap schema. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_artifact_state_reports_stale_manifest_when_zig_version_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION},\n'
                f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
                '  "embeddedEnvIsolation": true,\n'
                '  "macosLoginQuiet": true,\n'
                '  "ghosttyConfigLoadExport": true,\n'
                f'  "ghosttyCommit": "{metadata.commit}",\n'
                f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
                '  "requiredZigVersion": "0.13.",\n'
                '  "sentryEnabled": false,\n'
                '  "optimize": "Debug",\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built with a different Zig version requirement. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_artifact_state_reports_stale_manifest_when_optimize_mode_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION},\n'
                f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
                '  "embeddedEnvIsolation": true,\n'
                '  "macosLoginQuiet": true,\n'
                '  "ghosttyConfigLoadExport": true,\n'
                f'  "ghosttyCommit": "{metadata.commit}",\n'
                f'  "requiredZigVersion": "{metadata.required_zig_version}",\n'
                '  "sentryEnabled": false,\n'
                f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
                '  "optimize": "ReleaseFast",\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built with a different optimize mode. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_ensure_source_checkout_initializes_local_cache_and_fetches_pinned_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)
            git_path = "/usr/bin/git"
            commands: list[list[str]] = []

            def fake_run(
                command: list[str],
                cwd: str | None = None,
                check: bool = True,
                capture_output: bool = False,
                text: bool = False,
            ) -> bootstrap.subprocess.CompletedProcess[str]:
                del cwd, check, capture_output, text
                commands.append(command)
                if command[:2] == [git_path, "init"]:
                    source_root = Path(command[2])
                    (source_root / ".git").mkdir(parents=True, exist_ok=True)
                if command[:4] == [git_path, "-C", str(paths.source_checkout_root), "checkout"]:
                    include_root = paths.source_checkout_root / "include"
                    include_root.mkdir(parents=True, exist_ok=True)
                    (paths.source_checkout_root / "build.zig").write_text("// build\n")
                    (include_root / "ghostty.h").write_text("// header\n")
                    (include_root / "module.modulemap").write_text("module GhosttyKit {}\n")
                return bootstrap.subprocess.CompletedProcess(command, 0, "", "")

            with (
                mock.patch.object(bootstrap, "resolve_tool", return_value=git_path),
                mock.patch.object(bootstrap.subprocess, "run", side_effect=fake_run),
            ):
                bootstrap.ensure_source_checkout(paths, metadata, git="git")

        self.assertIn([git_path, "init", str(paths.source_checkout_root)], commands)
        self.assertIn(
            [git_path, "-C", str(paths.source_checkout_root), "remote", "add", "origin", metadata.source],
            commands,
        )
        self.assertIn(
            [git_path, "-C", str(paths.source_checkout_root), "fetch", "--depth", "1", "origin", metadata.commit],
            commands,
        )
        self.assertIn(
            [git_path, "-C", str(paths.source_checkout_root), "checkout", "--force", metadata.commit],
            commands,
        )
        self.assertIn(
            [git_path, "-C", str(paths.source_checkout_root), "clean", "-fdx"],
            commands,
        )

    def test_ensure_source_checkout_resets_existing_cache_when_origin_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)
            git_path = "/usr/bin/git"
            (paths.source_checkout_root / ".git").mkdir(parents=True, exist_ok=True)
            commands: list[list[str]] = []

            def fake_run(
                command: list[str],
                cwd: str | None = None,
                check: bool = True,
                capture_output: bool = False,
                text: bool = False,
            ) -> bootstrap.subprocess.CompletedProcess[str]:
                del cwd, check, capture_output, text
                commands.append(command)
                if command[:2] == [git_path, "init"]:
                    source_root = Path(command[2])
                    (source_root / ".git").mkdir(parents=True, exist_ok=True)
                if command[:4] == [git_path, "-C", str(paths.source_checkout_root), "checkout"]:
                    include_root = paths.source_checkout_root / "include"
                    include_root.mkdir(parents=True, exist_ok=True)
                    (paths.source_checkout_root / "build.zig").write_text("// build\n")
                    (include_root / "ghostty.h").write_text("// header\n")
                    (include_root / "module.modulemap").write_text("module GhosttyKit {}\n")
                return bootstrap.subprocess.CompletedProcess(command, 0, "", "")

            with (
                mock.patch.object(bootstrap, "resolve_tool", return_value=git_path),
                mock.patch.object(
                    bootstrap,
                    "read_tool_output",
                    return_value="https://example.com/not-ghostty.git",
                ),
                mock.patch.object(bootstrap.subprocess, "run", side_effect=fake_run),
            ):
                bootstrap.ensure_source_checkout(paths, metadata, git="git")

        self.assertIn([git_path, "init", str(paths.source_checkout_root)], commands)
        self.assertIn(
            [git_path, "-C", str(paths.source_checkout_root), "remote", "add", "origin", metadata.source],
            commands,
        )

    def test_artifact_state_reports_stale_manifest_when_isolation_settings_change(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION},\n'
                '  "ghosttyBundleID": "com.example.ghostty",\n'
                '  "ghosttyConfigLoadExport": false,\n'
                f'  "ghosttyCommit": "{metadata.commit}",\n'
                '  "macosLoginQuiet": false,\n'
                f'  "requiredZigVersion": "{metadata.required_zig_version}",\n'
                '  "sentryEnabled": true,\n'
                '  "termProgram": "ghostty",\n'
                '  "optimize": "Debug",\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built with different Ghosthub isolation settings. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_artifact_state_reports_stale_manifest_when_inject_output_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION},\n'
                f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
                '  "ghosttyConfigLoadExport": true,\n'
                f'  "ghosttyCommit": "{metadata.commit}",\n'
                '  "macosLoginQuiet": true,\n'
                '  "embeddedEnvIsolation": true,\n'
                f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
                f'  "requiredZigVersion": "{metadata.required_zig_version}",\n'
                '  "sentryEnabled": false,\n'
                '  "surfaceInjectOutputExport": false,\n'
                '  "optimize": "Debug",\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built with different Ghosthub isolation settings. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_artifact_state_reports_stale_manifest_when_child_write_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo_root = Path(tmpdir)
            metadata = self._create_repo_layout(repo_root)
            paths = self._paths(repo_root)

            artifacts = paths.cached_artifacts
            artifacts.root.mkdir(parents=True, exist_ok=True)
            artifacts.xcframework_path.mkdir(parents=True)
            artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
            artifacts.header_path.write_text("// header\n")
            artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
            artifacts.manifest_path.write_text(
                "{\n"
                f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION},\n'
                f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
                '  "ghosttyConfigLoadExport": true,\n'
                f'  "ghosttyCommit": "{metadata.commit}",\n'
                '  "macosLoginQuiet": true,\n'
                '  "embeddedEnvIsolation": true,\n'
                f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
                f'  "requiredZigVersion": "{metadata.required_zig_version}",\n'
                '  "sentryEnabled": false,\n'
                '  "surfaceInjectOutputExport": true,\n'
                '  "childWriteCallback": false,\n'
                '  "optimize": "Debug",\n'
                '  "xcframeworkTarget": "native"\n'
                "}\n"
            )

            message = bootstrap.artifact_state_message(
                artifacts,
                metadata,
                "native",
                "Debug",
            )

            self.assertEqual(
                message,
                "libghostty artifacts were built with different Ghosthub isolation settings. Re-run `python3 tools/bootstrap_libghostty.py`.",
            )

    def test_main_quiet_noop_suppresses_already_ready_output(self) -> None:
        paths = mock.Mock()
        paths.vendor_metadata_path = Path("/tmp/ghostty.version.json")
        paths.staged_artifacts = mock.Mock(root=Path("/tmp/libghostty"))
        metadata = mock.Mock()

        with (
            mock.patch.object(
                bootstrap.BootstrapPaths,
                "from_repo_root",
                return_value=paths,
            ),
            mock.patch.object(
                bootstrap.VendorMetadata,
                "load",
                return_value=metadata,
            ),
            mock.patch.object(
                bootstrap,
                "bootstrap",
                return_value=bootstrap.BootstrapResult(
                    rebuilt_variant=False,
                    staged_synced=False,
                ),
            ),
            mock.patch("builtins.print") as print_mock,
        ):
            result = bootstrap.main(["--quiet-noop"])

        self.assertEqual(result, 0)
        print_mock.assert_not_called()

    def test_main_quiet_noop_still_prints_when_artifacts_change(self) -> None:
        paths = mock.Mock()
        paths.vendor_metadata_path = Path("/tmp/ghostty.version.json")
        paths.staged_artifacts = mock.Mock(root=Path("/tmp/libghostty"))
        metadata = mock.Mock()

        with (
            mock.patch.object(
                bootstrap.BootstrapPaths,
                "from_repo_root",
                return_value=paths,
            ),
            mock.patch.object(
                bootstrap.VendorMetadata,
                "load",
                return_value=metadata,
            ),
            mock.patch.object(
                bootstrap,
                "bootstrap",
                return_value=bootstrap.BootstrapResult(
                    rebuilt_variant=False,
                    staged_synced=True,
                ),
            ),
            mock.patch.object(
                bootstrap,
                "refresh_swiftpm_manifest",
            ) as refresh_mock,
            mock.patch("builtins.print") as print_mock,
        ):
            result = bootstrap.main(["--quiet-noop"])

        self.assertEqual(result, 0)
        refresh_mock.assert_called_once_with(paths)
        print_mock.assert_called_once_with(
            "Activated cached libghostty artifacts at /tmp/libghostty"
        )

    def _paths(
        self,
        repo_root: Path,
        *,
        xcframework_target: str = "native",
        optimize: str = "Debug",
    ) -> bootstrap.BootstrapPaths:
        return bootstrap.BootstrapPaths.from_repo_root(
            repo_root,
            xcframework_target=xcframework_target,
            optimize=optimize,
        )

    def _write_ready_artifacts(
        self,
        artifacts: bootstrap.ArtifactPaths,
        metadata: bootstrap.VendorMetadata,
        *,
        optimize: str = "Debug",
        xcframework_target: str = "native",
    ) -> None:
        artifacts.root.mkdir(parents=True, exist_ok=True)
        artifacts.xcframework_path.mkdir(parents=True)
        artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
        artifacts.header_path.write_text("// header\n")
        artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
        artifacts.manifest_path.write_text(
            "{\n"
            f'  "ghosthubBootstrapVersion": {bootstrap.GHOSTHUB_BOOTSTRAP_VERSION},\n'
            f'  "ghosttyBundleID": "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}",\n'
            '  "embeddedEnvIsolation": true,\n'
            '  "macosLoginQuiet": true,\n'
            '  "ghosttyConfigLoadExport": true,\n'
            '  "surfaceInjectOutputExport": true,\n'
            '  "childWriteCallback": true,\n'
            f'  "ghosttyCommit": "{metadata.commit}",\n'
            f'  "termProgram": "{bootstrap.GHOSTHUB_TERM_PROGRAM}",\n'
            f'  "requiredZigVersion": "{metadata.required_zig_version}",\n'
            '  "i18nEnabled": false,\n'
            '  "sentryEnabled": false,\n'
            f'  "optimize": "{optimize}",\n'
            f'  "xcframeworkTarget": "{xcframework_target}"\n'
            "}\n"
        )

    def _create_repo_layout(self, repo_root: Path) -> bootstrap.VendorMetadata:
        metadata_path = repo_root / "Vendor" / "ghostty.version.json"
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        metadata_path.write_text(
            "{\n"
            '  "source": "https://github.com/ghostty-org/ghostty.git",\n'
            '  "tag": "v1.3.0",\n'
            '  "commit": "703d11c642a96af9e54b55b04f131bf3888948a9",\n'
            '  "required_zig_version": "0.15.2"\n'
            "}\n"
        )
        return bootstrap.VendorMetadata.load(metadata_path)
