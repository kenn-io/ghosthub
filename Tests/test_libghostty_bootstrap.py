from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

import pytest


TOOLS_DIR = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS_DIR))

import libghostty_bootstrap as bootstrap  # noqa: E402

SDKLayoutFactory = Callable[[str], tuple[Path, Path, Path, Path]]


@dataclass(frozen=True)
class Repo:
    root: Path
    metadata: bootstrap.VendorMetadata
    paths: bootstrap.BootstrapPaths


@pytest.fixture
def repo(tmp_path: Path) -> Repo:
    metadata = _create_repo_layout(tmp_path)
    return Repo(tmp_path, metadata, _paths(tmp_path))


@pytest.fixture
def sdk_layout(
    tmp_path: Path,
) -> SDKLayoutFactory:
    def create(active_targets: str) -> tuple[Path, Path, Path, Path]:
        repo_root = tmp_path / "repo"
        repo_root.mkdir(exist_ok=True)
        sdk_root = tmp_path / "SDKs"
        active = _write_sdk_stub(
            sdk_root / "MacOSX26.5.sdk",
            active_targets,
        )
        fallback = _write_sdk_stub(
            sdk_root / "MacOSX15.4.sdk",
            "arm64-macos, x86_64-macos",
        )
        return repo_root, sdk_root, active, fallback

    return create


def test_render_build_command_uses_repo_bootstrap_flags(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Shield the baseline from a caller's real
    # LIBGHOSTTY_ZIG_BUILD_ARGS (a supported override).
    monkeypatch.delenv("LIBGHOSTTY_ZIG_BUILD_ARGS", raising=False)
    command = bootstrap.render_build_command(
        "/opt/homebrew/bin/zig",
        "native",
        "Debug",
    )

    assert command == [
        "/opt/homebrew/bin/zig",
        "build",
        "-Dapp-runtime=none",
        "-Demit-xcframework=true",
        "-Demit-macos-app=false",
        "-Demit-themes=true",
        "-Di18n=false",
        "-Dsentry=false",
        "-Doptimize=Debug",
        "-Dxcframework-target=native",
    ]


@pytest.mark.parametrize(
    ("extra_args", "expected_tail"),
    [
        ("--sysroot /tmp/patched-sdk", ["--sysroot", "/tmp/patched-sdk"]),
        ("  ", ["-Dxcframework-target=native"]),
    ],
)
def test_render_build_command_honors_extra_zig_args(
    monkeypatch: pytest.MonkeyPatch,
    extra_args: str,
    expected_tail: list[str],
) -> None:
    monkeypatch.setenv("LIBGHOSTTY_ZIG_BUILD_ARGS", extra_args)
    command = bootstrap.render_build_command("/opt/homebrew/bin/zig", "native", "Debug")
    assert command[-len(expected_tail) :] == expected_tail


@pytest.mark.parametrize(
    "target_args",
    [[], ["--xcframework-target", "aarch64"]],
    ids=["default", "explicit"],
)
def test_main_print_command_uses_aarch64_target(
    repo: Repo,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    target_args: list[str],
) -> None:
    monkeypatch.setattr(bootstrap, "resolve_tool", lambda _: "/opt/homebrew/bin/zig")
    result = bootstrap.main(
        [
            "--repo-root",
            str(repo.root),
            "--zig",
            "zig",
            *target_args,
            "--print-command",
        ]
    )

    assert result == 0
    assert "-Dxcframework-target=aarch64" in capsys.readouterr().out


def test_public_header_patch_upgrades_old_config_load_signature(tmp_path: Path) -> None:
    header = tmp_path / "ghostty.h"
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
    assert (
        "void ghostty_config_load_file(ghostty_config_t, const char*, size_t);"
        in contents
    )
    assert (
        "void ghostty_config_load_file(ghostty_config_t, const char*);" not in contents
    )


def _make_archive(
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
    subprocess.run(command, check=True)
    archive = workdir / name
    subprocess.run(
        ["ar", "-q", str(archive), str(obj)],
        check=True,
        capture_output=True,
    )
    return archive


@pytest.mark.skipif(
    sys.platform != "darwin" or not shutil.which("cc"),
    reason="needs macOS cc/ar/libtool",
)
def test_rebuild_fat_archive_restores_dropped_members(tmp_path: Path) -> None:
    workdir = tmp_path
    alpha = _make_archive(workdir, "libalpha.a", "alpha_fn")
    beta = _make_archive(workdir, "libbeta.a", "beta_fn")
    # The broken fat archive only carries alpha, mimicking
    # libtool having dropped beta's member.
    fat = workdir / "libghostty-fat.a"
    shutil.copy2(alpha, fat)

    assert not bootstrap.archive_defines_symbol(fat, "_beta_fn")

    bootstrap.rebuild_fat_archive(fat, [alpha, beta])

    assert bootstrap.archive_defines_symbol(fat, "_alpha_fn")
    assert bootstrap.archive_defines_symbol(fat, "_beta_fn")


@pytest.mark.skipif(
    sys.platform != "darwin" or not shutil.which("cc") or not shutil.which("lipo"),
    reason="needs macOS cc/ar/libtool/lipo",
)
def test_repair_fat_archive_preserves_xcframework_slice_architecture(
    tmp_path: Path,
) -> None:
    repo_root = tmp_path
    paths = _paths(repo_root, xcframework_target="aarch64")
    source_root = paths.source_checkout_root
    cache_root = source_root / ".zig-cache" / "o"
    arm_cache = cache_root / "arm64"
    x86_cache = cache_root / "x86_64"
    arm_cache.mkdir(parents=True)
    x86_cache.mkdir(parents=True)
    slice_dir = source_root / "macos" / "GhosttyKit.xcframework" / "macos-arm64"
    slice_dir.mkdir(parents=True)
    fat = slice_dir / bootstrap.FAT_ARCHIVE_NAME

    sentinel_only = _make_archive(
        tmp_path,
        "libbroken.a",
        "ghostty_app_new",
        arch="arm64",
    )
    shutil.copy2(sentinel_only, fat)
    _make_archive(
        arm_cache,
        "libghostty.a",
        "ghostty_app_new",
        arch="arm64",
    )
    _make_archive(
        arm_cache,
        "libdependency.a",
        "dependency_fn",
        arch="arm64",
    )
    _make_archive(
        x86_cache,
        "libx86_only.a",
        "x86_only_fn",
        arch="x86_64",
    )
    bootstrap.repair_fat_archives(paths)

    assert bootstrap.archive_defines_symbol(
        fat,
        bootstrap.GHOSTTY_SENTINEL_SYMBOL,
    )
    assert bootstrap.archive_archs(fat) == ["arm64"]
    assert bootstrap.archive_defines_symbol(fat, "_dependency_fn")
    assert not bootstrap.archive_defines_symbol(fat, "_x86_only_fn")


@pytest.mark.skipif(
    sys.platform != "darwin" or not shutil.which("cc"),
    reason="needs macOS cc/ar/libtool",
)
def test_artifact_state_flags_archive_missing_ghostty_api(tmp_path: Path) -> None:
    workdir = tmp_path
    artifacts = bootstrap.ArtifactPaths.from_root(workdir)
    slice_dir = artifacts.xcframework_path / "macos-arm64"
    slice_dir.mkdir(parents=True)
    artifacts.header_path.parent.mkdir(parents=True)
    artifacts.header_path.write_text("// header\n")
    artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
    _write_share_tree(artifacts.share_path)
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
                "ghosthubBootstrapVersion": bootstrap.GHOSTHUB_BOOTSTRAP_VERSION,
                "xcframeworkTarget": "native",
                "optimize": "Debug",
                "requiredZigVersion": "0.15.2",
                "ghosttyBundleID": bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID,
                "i18nEnabled": False,
                "sentryEnabled": False,
                "ghosttyConfigLoadExport": True,
                "surfaceInjectOutputExport": True,
                "childWriteCallback": True,
                "embeddedEnvIsolation": True,
                "termProgram": bootstrap.GHOSTHUB_TERM_PROGRAM,
                "macosLoginQuiet": True,
            }
        )
    )

    broken = _make_archive(workdir, "libbroken.a", "other_fn")
    shutil.copy2(broken, slice_dir / "libghostty-fat.a")
    message = bootstrap.artifact_state_message(artifacts, metadata, "native", "Debug")
    assert message is not None
    assert "ghostty API" in message

    healthy = _make_archive(workdir, "libhealthy.a", "ghostty_app_new")
    shutil.copy2(healthy, slice_dir / "libghostty-fat.a")
    assert (
        bootstrap.artifact_state_message(artifacts, metadata, "native", "Debug") is None
    )


def test_component_archives_excludes_fat_outputs(tmp_path: Path) -> None:
    cache = tmp_path / ".zig-cache" / "o" / "abc"
    cache.mkdir(parents=True)
    (cache / "libdep.a").write_bytes(b"!<arch>\n")
    (cache / "libghostty-fat.a").write_bytes(b"!<arch>\n")
    nested = tmp_path / ".zig-cache" / "o" / "def"
    nested.mkdir(parents=True)
    (nested / "libghostty.a").write_bytes(b"!<arch>\n")

    found = bootstrap.component_archives(tmp_path / ".zig-cache")

    names = [p.name for p in found]
    assert names == ["libdep.a", "libghostty.a"]


def test_clipboard_write_patch_marks_both_osc52_paths(tmp_path: Path) -> None:
    surface = tmp_path / "Surface.zig"
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
    assert patched.count("application/x-ghosthub-osc52") == 2
    assert ".data = buf" in patched
    assert ".data = data" in patched


def test_apply_ghosthub_source_patches_exports_direct_config_loading(
    tmp_path: Path,
) -> None:
    repo_root = tmp_path
    _create_repo_layout(repo_root)
    paths = _paths(repo_root)
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
    shared_deps = paths.source_checkout_root / "src" / "build" / "SharedDeps.zig"

    build_config.parent.mkdir(parents=True, exist_ok=True)
    config_c_api.parent.mkdir(parents=True, exist_ok=True)
    header.parent.mkdir(parents=True, exist_ok=True)
    embedded.parent.mkdir(parents=True, exist_ok=True)
    apprt_surface.parent.mkdir(parents=True, exist_ok=True)
    core_surface.parent.mkdir(parents=True, exist_ok=True)
    exec_zig.parent.mkdir(parents=True, exist_ok=True)
    termio_zig.parent.mkdir(parents=True, exist_ok=True)
    xcframework_enum.parent.mkdir(parents=True, exist_ok=True)

    build_config.write_text('pub const bundle_id = "com.mitchellh.ghostty";\n')
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
        '        .mime = "text/plain",\n'
        "        .data = buf,\n"
        "    }}, confirm) catch |err| {\n"
        "\n"
        "        .osc_52_write => |clipboard| try self.rt_surface.setClipboard(clipboard, &.{.{\n"
        '            .mime = "text/plain",\n'
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
    xcframework_enum.write_text("pub const Target = enum { native, universal };\n")
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
        """        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
"""
    )

    bootstrap.apply_ghosthub_source_patches(paths)

    assert (
        f'pub const bundle_id = "{bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID}";'
        in build_config.read_text()
    )
    assert "export fn ghostty_config_load_file(" in config_c_api.read_text()
    assert (
        "void ghostty_config_load_file(ghostty_config_t, const char*, size_t);"
        in header.read_text()
    )
    assert "int ghostty_surface_child_pid(ghostty_surface_t);" in header.read_text()
    assert (
        "int ghostty_surface_child_exit_code(ghostty_surface_t);" in header.read_text()
    )
    assert (
        "void ghostty_surface_inject_output(ghostty_surface_t, const char*, uintptr_t);"
        in header.read_text()
    )
    assert (
        "typedef void (*ghostty_runtime_child_write_cb)(void*, const char*, uintptr_t);"
        in header.read_text()
    )
    assert "ghostty_runtime_child_write_cb child_write_cb;" in header.read_text()
    assert "try stripGhosthubLauncherEnv(alloc, &env);" in embedded.read_text()
    assert (
        "export fn ghostty_surface_child_pid(surface: *Surface) c_int {"
        in embedded.read_text()
    )
    assert (
        "export fn ghostty_surface_child_exit_code(surface: *Surface) c_int {"
        in embedded.read_text()
    )
    assert "export fn ghostty_surface_inject_output(" in embedded.read_text()
    assert "fn stripGhosthubLauncherEnv(" in embedded.read_text()
    assert '"EDITOR",' in embedded.read_text()
    assert '"VISUAL",' in embedded.read_text()
    assert (
        "child_write: ?*const fn (SurfaceUD, [*]const u8, usize) callconv(.c) void = null,"
        in embedded.read_text()
    )
    assert (
        "pub fn childWrite(self: *const Surface, data: []const u8) void {"
        in embedded.read_text()
    )
    assert "child_write: WriteReq," in apprt_surface.read_text()
    assert ".child_write => |w| {" in core_surface.read_text()
    assert "self.rt_surface.childWrite(w.slice());" in core_surface.read_text()
    assert "child_exit_code: ?u32 = null," in core_surface.read_text()
    assert "self.child_exit_code = info.exit_code;" in core_surface.read_text()
    assert ".child_write = req" in termio_zig.read_text()
    assert "req.deinit();" in termio_zig.read_text()
    assert (
        '        try args.append(alloc, "/usr/bin/login");\n'
        '        try args.append(alloc, "-q");\n'
        '        try args.append(alloc, "-flp");\n' in exec_zig.read_text()
    )
    assert "const hush = if (passwd.home)" not in exec_zig.read_text()
    assert (
        f'try env.put("TERM_PROGRAM", "{bootstrap.GHOSTHUB_TERM_PROGRAM}");'
        in exec_zig.read_text()
    )
    assert (
        "pub const Target = enum { native, universal, aarch64 };"
        in xcframework_enum.read_text()
    )
    assert "Config.genericMacOSTarget(b, .aarch64)" in ghostty_xcframework.read_text()
    assert (
        '        },\n\n        .aarch64 => "arm64",\n' in ghostty_xcodebuild.read_text()
    )


def test_patch_term_program_env_sets_ghosthub_identity(tmp_path: Path) -> None:
    path = tmp_path / "Exec.zig"
    path.write_text(
        """        // Set environment variables used by some programs (such as neovim) to detect
        // which terminal emulator and version they're running under.
        try env.put("TERM_PROGRAM", "ghostty");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);
"""
    )

    bootstrap.patch_term_program_env(path)

    assert (
        f'try env.put("TERM_PROGRAM", "{bootstrap.GHOSTHUB_TERM_PROGRAM}");'
        in path.read_text()
    )


def test_patch_libintl_i18n_guard_skips_static_gettext(tmp_path: Path) -> None:
    path = tmp_path / "SharedDeps.zig"
    path.write_text(
        """        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
"""
    )

    bootstrap.patch_libintl_i18n_guard(path)
    bootstrap.patch_libintl_i18n_guard(path)

    assert "if (self.config.i18n) {" in path.read_text()


def test_patch_surface_inject_output_export_adds_capi_function(
    tmp_path: Path,
) -> None:
    embedded = tmp_path / "embedded.zig"
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
    assert "export fn ghostty_surface_inject_output(" in contents
    assert "surface.core_surface.io.processOutput(ptr[0..len]);" in contents
    # Idempotency: double-apply must not duplicate the export.
    bootstrap.patch_surface_inject_output_export(embedded)
    assert embedded.read_text().count("ghostty_surface_inject_output") == 1


def test_patch_clipboard_request_type_export_adds_capi_function(
    tmp_path: Path,
) -> None:
    embedded = tmp_path / "embedded.zig"
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
    assert "export fn ghostty_clipboard_request_type(" in contents
    assert "std.meta.activeTag(state.*)" in contents

    bootstrap.patch_clipboard_request_type_export(embedded)
    assert embedded.read_text().count("export fn ghostty_clipboard_request_type(") == 1


def test_patch_public_header_declares_inject_output(tmp_path: Path) -> None:
    header = tmp_path / "ghostty.h"
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
    assert (
        "void ghostty_surface_inject_output(ghostty_surface_t, const char*, uintptr_t);"
        in contents
    )
    # Declaration sits between text and preedit.
    assert contents.index("ghostty_surface_text(") < contents.index(
        "ghostty_surface_inject_output("
    )
    assert contents.index("ghostty_surface_inject_output(") < contents.index(
        "ghostty_surface_preedit("
    )
    assert (
        "ghostty_clipboard_request_e ghostty_clipboard_request_type(void*);" in contents
    )


def test_patch_child_write_header_adds_typedef_and_field(tmp_path: Path) -> None:
    header = tmp_path / "ghostty.h"
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
    assert (
        "typedef void (*ghostty_runtime_child_write_cb)(void*, const char*, uintptr_t);"
        in contents
    )
    assert "ghostty_runtime_child_write_cb child_write_cb;" in contents
    bootstrap.patch_child_write_header(header)
    assert header.read_text().count("child_write_cb;") == 1


def test_patch_child_write_message_adds_union_member(tmp_path: Path) -> None:
    surface_zig = tmp_path / "surface.zig"
    surface_zig.write_text(
        "    /// The terminal has reported a change in the working directory.\n"
        "    pwd_change: WriteReq,\n"
        "\n"
        "    /// The terminal encountered a bell character.\n"
        "    ring_bell,\n"
    )
    bootstrap.patch_child_write_message(surface_zig)
    contents = surface_zig.read_text()
    assert "child_write: WriteReq," in contents
    bootstrap.patch_child_write_message(surface_zig)
    assert surface_zig.read_text().count("child_write: WriteReq,") == 1


def test_patch_child_write_dispatch_adds_handle_message_arm(tmp_path: Path) -> None:
    surface = tmp_path / "Surface.zig"
    surface.write_text(
        "        .close => self.close(),\n"
        "\n"
        "        .child_exited => |v| self.childExited(v),\n"
    )
    bootstrap.patch_child_write_dispatch(surface)
    contents = surface.read_text()
    assert ".child_write => |w| {" in contents
    assert "self.rt_surface.childWrite(w.slice());" in contents
    bootstrap.patch_child_write_dispatch(surface)
    assert surface.read_text().count(".child_write => |w| {") == 1


def test_patch_child_write_embedded_adds_option_and_method(tmp_path: Path) -> None:
    embedded = tmp_path / "embedded.zig"
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
    assert (
        "child_write: ?*const fn (SurfaceUD, [*]const u8, usize) callconv(.c) void = null,"
        in contents
    )
    assert (
        "pub fn childWrite(self: *const Surface, data: []const u8) void {" in contents
    )
    bootstrap.patch_child_write_embedded(embedded)
    assert (
        embedded.read_text().count(
            "pub fn childWrite(self: *const Surface, data: []const u8) void {"
        )
        == 1
    )


def test_patch_child_write_termio_mirrors_queue_write(tmp_path: Path) -> None:
    termio = tmp_path / "Termio.zig"
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
    assert ".child_write = req" in contents
    assert "req.deinit();" in contents
    assert (
        "self.surface_mailbox.push(.{ .child_write = req }, .{ .instant = {} }) == 0"
        in contents
    )
    bootstrap.patch_child_write_termio(termio)
    assert termio.read_text().count(".child_write = req") == 1
    assert termio.read_text().count("req.deinit();") == 1


def test_patch_apple_silicon_xcframework_target_adds_arm64_only_option(
    tmp_path: Path,
) -> None:
    root = tmp_path
    target_enum = root / "src" / "build" / "xcframework.zig"
    target_enum.parent.mkdir(parents=True)
    target_enum.write_text("pub const Target = enum { native, universal };\n")
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

    assert (
        "pub const Target = enum { native, universal, aarch64 };"
        in target_enum.read_text()
    )
    contents = ghostty_xcframework.read_text()
    assert contents.count("const macos_aarch64") == 1
    assert "Config.genericMacOSTarget(b, .aarch64)" in contents
    assert ".aarch64 => &.{.{" in contents
    assert (
        '        },\n\n        .aarch64 => "arm64",\n' in ghostty_xcodebuild.read_text()
    )


def test_ensure_supported_zig_version_rejects_incompatible_version() -> None:
    with pytest.raises(
        bootstrap.BootstrapError,
        match="requires Zig 0.15.2 or newer, but found 0.14.1",
    ):
        bootstrap.ensure_supported_zig_version("0.14.1", "0.15.2")


def test_ensure_metal_toolchain_reports_actionable_install_hint() -> None:
    with mock.patch.object(
        bootstrap,
        "read_tool_output",
        side_effect=bootstrap.subprocess.CalledProcessError(1, ["xcrun"]),
    ):
        with pytest.raises(
            bootstrap.BootstrapError, match="downloadComponent MetalToolchain"
        ):
            bootstrap.ensure_metal_toolchain("/usr/bin/xcrun")


def test_zig_executable_architecture_reads_zig_env_target() -> None:
    with mock.patch.object(
        bootstrap,
        "read_tool_output",
        return_value='.target = "x86_64-macos.26.5...26.5-none",',
    ):
        architecture = bootstrap.zig_executable_architecture("/usr/bin/zig")

    assert architecture == "x86_64"


def test_find_compatible_macos_sdk_selects_newest_target_match(tmp_path: Path) -> None:
    sdk_root = tmp_path
    older = _write_sdk_stub(
        sdk_root / "MacOSX15.2.sdk",
        "arm64-macos, x86_64-macos",
    )
    newer = _write_sdk_stub(
        sdk_root / "MacOSX15.4.sdk",
        "arm64-macos, x86_64-macos",
    )
    _write_sdk_stub(
        sdk_root / "MacOSX26.5.sdk",
        "arm64e-macos, x86_64-macos",
    )

    selected = bootstrap.find_compatible_macos_sdk(
        frozenset(("arm64-macos",)),
        [sdk_root],
    )

    assert selected == newer.resolve()
    assert selected != older.resolve()


def test_prepare_zig_build_environment_shims_incompatible_active_sdk(
    sdk_layout: SDKLayoutFactory,
) -> None:
    repo_root, sdk_root, active, fallback = sdk_layout("arm64e-macos, x86_64-macos")

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
    assert environment["PATH"].split(":")[0] == str(shim.parent)
    assert shim.stat().st_mode & 0o100
    selected = subprocess.run(
        [str(shim), "--sdk", "macosx", "--show-sdk-path"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    assert selected == str(fallback.resolve())


def test_intel_zig_aarch64_build_requires_both_sdk_targets(
    sdk_layout: SDKLayoutFactory,
) -> None:
    repo_root, sdk_root, active, fallback = sdk_layout("arm64e-macos, x86_64-macos")

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
    assert str(fallback.resolve()) in shim.read_text()


def test_universal_build_requires_both_sdk_targets(
    sdk_layout: SDKLayoutFactory,
) -> None:
    repo_root, sdk_root, active, fallback = sdk_layout("arm64-macos")

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
    assert str(fallback.resolve()) in shim.read_text()


def test_bootstrap_wraps_build_failures_with_setup_guidance(repo: Repo) -> None:
    with (
        mock.patch.object(bootstrap, "ensure_source_checkout"),
        mock.patch.object(bootstrap, "apply_ghosthub_source_patches"),
        mock.patch.object(
            bootstrap, "resolve_tool", side_effect=lambda tool: f"/usr/bin/{tool}"
        ),
        mock.patch.object(bootstrap, "read_tool_output", return_value="0.15.2"),
        mock.patch.object(bootstrap, "ensure_metal_toolchain"),
        mock.patch.object(
            bootstrap, "zig_executable_architecture", return_value="aarch64"
        ),
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
        with pytest.raises(
            bootstrap.BootstrapError,
            match="full Xcode installation selected via `xcode-select`",
        ):
            bootstrap.bootstrap(
                paths=repo.paths,
                metadata=repo.metadata,
                git="git",
                zig="zig",
                xcodebuild="xcodebuild",
                xcrun="xcrun",
                xcframework_target="native",
                optimize="Debug",
            )


def _write_sdk_stub(sdk_path: Path, targets: str) -> Path:
    stub = sdk_path / "usr" / "lib" / "libSystem.B.tbd"
    stub.parent.mkdir(parents=True)
    stub.write_text(
        "--- !tapi-tbd\n"
        "tbd-version: 4\n"
        f"targets: [ {targets} ]\n"
        "install-name: '/usr/lib/libSystem.B.dylib'\n"
    )
    return sdk_path


def test_bootstrap_is_noop_when_artifacts_are_current(repo: Repo) -> None:
    _write_ready_artifacts(repo.paths.cached_artifacts, repo.metadata)
    _write_ready_artifacts(repo.paths.staged_artifacts, repo.metadata)

    with (
        mock.patch.object(
            bootstrap, "ensure_source_checkout"
        ) as ensure_source_checkout,
        mock.patch.object(bootstrap, "resolve_tool") as resolve_tool,
        mock.patch.object(bootstrap, "read_tool_output") as read_tool_output,
        mock.patch.object(
            bootstrap, "ensure_metal_toolchain"
        ) as ensure_metal_toolchain,
        mock.patch.object(bootstrap.subprocess, "run") as run,
    ):
        result = bootstrap.bootstrap(
            paths=repo.paths,
            metadata=repo.metadata,
            git="git",
            zig="zig",
            xcodebuild="xcodebuild",
            xcrun="xcrun",
            xcframework_target="native",
            optimize="Debug",
        )

    assert not result.rebuilt_variant
    assert not result.staged_synced
    ensure_source_checkout.assert_not_called()
    resolve_tool.assert_not_called()
    read_tool_output.assert_not_called()
    ensure_metal_toolchain.assert_not_called()
    run.assert_not_called()


def test_bootstrap_syncs_cached_variant_into_staged_root_without_rebuild(
    repo: Repo,
) -> None:
    paths = repo.paths
    _write_ready_artifacts(paths.cached_artifacts, repo.metadata)

    # Create a source checkout directory so the symlink can be created.
    paths.source_checkout_root.mkdir(parents=True, exist_ok=True)
    (paths.source_checkout_root / "zig-out" / "share" / "ghostty").mkdir(parents=True)

    with (
        mock.patch.object(
            bootstrap, "ensure_source_checkout"
        ) as ensure_source_checkout,
        mock.patch.object(bootstrap, "resolve_tool") as resolve_tool,
        mock.patch.object(bootstrap, "read_tool_output") as read_tool_output,
        mock.patch.object(
            bootstrap, "ensure_metal_toolchain"
        ) as ensure_metal_toolchain,
        mock.patch.object(bootstrap.subprocess, "run") as run,
    ):
        result = bootstrap.bootstrap(
            paths=paths,
            metadata=repo.metadata,
            git="git",
            zig="zig",
            xcodebuild="xcodebuild",
            xcrun="xcrun",
            xcframework_target="native",
            optimize="Debug",
        )

    assert not result.rebuilt_variant
    assert result.staged_synced
    assert paths.staged_artifacts.manifest_path.exists()
    assert (
        json.loads(paths.staged_artifacts.manifest_path.read_text())["optimize"]
        == "Debug"
    )

    source_link = paths.staged_artifacts.root / "source"
    assert source_link.is_symlink(), (
        "Staged artifacts should symlink source to cached variant"
    )
    assert (source_link / "zig-out" / "share" / "ghostty").is_dir(), (
        "Ghostty resources should be reachable via staged source symlink"
    )

    ensure_source_checkout.assert_not_called()
    resolve_tool.assert_not_called()
    read_tool_output.assert_not_called()
    ensure_metal_toolchain.assert_not_called()
    run.assert_not_called()


def test_refresh_swiftpm_manifest_touches_package_manifest(repo: Repo) -> None:
    package_manifest = repo.root / "Package.swift"
    package_manifest.write_text("// package manifest\n")
    original_mtime = package_manifest.stat().st_mtime_ns

    time.sleep(0.01)
    bootstrap.refresh_swiftpm_manifest(repo.paths)

    assert package_manifest.stat().st_mtime_ns > original_mtime


def test_artifact_state_reports_missing_bootstrap_outputs(repo: Repo) -> None:
    message = bootstrap.artifact_state_message(
        repo.paths.cached_artifacts,
        repo.metadata,
        "native",
        "Debug",
    )

    assert (
        message
        == "libghostty bootstrap artifacts are missing or stale. Run `python3 tools/bootstrap_libghostty.py` from the repo root."
    )


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        pytest.param(
            {"ghosttyCommit": "different"},
            "against a different Ghostty revision",
            id="commit",
        ),
        pytest.param(
            {"ghosthubBootstrapVersion": bootstrap.GHOSTHUB_BOOTSTRAP_VERSION - 1},
            "against an older Ghosthub bootstrap schema",
            id="schema",
        ),
        pytest.param(
            {"requiredZigVersion": "0.13.0"},
            "with a different Zig version requirement",
            id="zig-version",
        ),
        pytest.param(
            {"optimize": "ReleaseFast"},
            "with a different optimize mode",
            id="optimize",
        ),
        pytest.param(
            {"ghosttyBundleID": "com.example.ghostty"},
            "with different Ghosthub isolation settings",
            id="bundle-id",
        ),
        pytest.param(
            {"surfaceInjectOutputExport": False},
            "with different Ghosthub isolation settings",
            id="inject-output",
        ),
        pytest.param(
            {"childWriteCallback": False},
            "with different Ghosthub isolation settings",
            id="child-write",
        ),
    ],
)
def test_artifact_state_reports_stale_manifest(
    repo: Repo,
    overrides: dict[str, object],
    reason: str,
) -> None:
    _write_artifacts(repo.paths.cached_artifacts, repo.metadata, **overrides)

    message = bootstrap.artifact_state_message(
        repo.paths.cached_artifacts,
        repo.metadata,
        "native",
        "Debug",
    )

    assert message == (
        f"libghostty artifacts were built {reason}. "
        "Re-run `python3 tools/bootstrap_libghostty.py`."
    )


def test_artifact_state_reports_pruned_resources_despite_current_manifest(
    repo: Repo,
) -> None:
    # A manifest flag cannot tell a variant that still has its resources from
    # one whose share tree was pruned, so the tree itself is the check.
    _write_artifacts(repo.paths.cached_artifacts, repo.metadata)
    assert (
        bootstrap.artifact_state_message(
            repo.paths.cached_artifacts, repo.metadata, "native", "Debug"
        )
        is None
    )
    shutil.rmtree(repo.paths.cached_artifacts.share_path)

    message = bootstrap.artifact_state_message(
        repo.paths.cached_artifacts,
        repo.metadata,
        "native",
        "Debug",
    )

    assert message is not None
    assert "libghostty resources are incomplete" in message


def test_artifact_state_reports_a_missing_theme_corpus(repo: Repo) -> None:
    _write_artifacts(repo.paths.cached_artifacts, repo.metadata)
    shutil.rmtree(
        repo.paths.cached_artifacts.share_path.joinpath(
            *bootstrap.THEMES_RELATIVE_PATH
        )
    )

    message = bootstrap.artifact_state_message(
        repo.paths.cached_artifacts,
        repo.metadata,
        "native",
        "Debug",
    )

    assert message is not None
    assert "theme corpus" in message


def test_share_tree_problem_accepts_a_complete_tree(tmp_path: Path) -> None:
    assert bootstrap.share_tree_problem(_write_share_tree(tmp_path)) is None


def _empty_theme_corpus(share_root: Path) -> None:
    for theme in share_root.joinpath(*bootstrap.THEMES_RELATIVE_PATH).iterdir():
        theme.unlink()


def _replace_theme_corpus_with_a_file(share_root: Path) -> None:
    themes = share_root.joinpath(*bootstrap.THEMES_RELATIVE_PATH)
    shutil.rmtree(themes)
    themes.write_text("not a directory\n")


def _replace_terminfo_sentinel_with_a_directory(share_root: Path) -> None:
    terminfo = share_root.joinpath(*bootstrap.TERMINFO_RELATIVE_PATH)
    terminfo.unlink()
    terminfo.mkdir()


@pytest.mark.parametrize(
    ("corrupt", "reason"),
    [
        pytest.param(_empty_theme_corpus, "empty", id="empty-themes"),
        pytest.param(
            _replace_theme_corpus_with_a_file, "missing", id="themes-not-a-directory"
        ),
        pytest.param(
            _replace_terminfo_sentinel_with_a_directory,
            "terminfo",
            id="terminfo-not-a-file",
        ),
    ],
)
def test_share_tree_problem_rejects_an_unusable_tree(
    tmp_path: Path,
    corrupt: Callable[[Path], None],
    reason: str,
) -> None:
    # Existence alone is not enough: an empty corpus resolves no theme name,
    # and the terminfo sentinel is what libghostty matches when it climbs.
    share_root = _write_share_tree(tmp_path)
    corrupt(share_root)

    problem = bootstrap.share_tree_problem(share_root)

    assert problem is not None
    assert reason in problem


def test_ensure_emitted_resources_accepts_a_complete_build(repo: Repo) -> None:
    _write_share_tree(
        Path(repo.paths.source_checkout_root, *bootstrap.EMITTED_SHARE_RELATIVE_PATH)
    )

    bootstrap.ensure_emitted_resources(repo.paths)


def test_ensure_emitted_resources_rejects_an_incomplete_build(repo: Repo) -> None:
    share_root = _write_share_tree(
        Path(repo.paths.source_checkout_root, *bootstrap.EMITTED_SHARE_RELATIVE_PATH)
    )
    shutil.rmtree(share_root.joinpath(*bootstrap.THEMES_RELATIVE_PATH))

    with pytest.raises(bootstrap.BootstrapError) as raised:
        bootstrap.ensure_emitted_resources(repo.paths)

    assert "iTerm2-Color-Schemes" in str(raised.value)


def test_ensure_source_checkout_initializes_local_cache_and_fetches_pinned_commit(
    repo: Repo,
) -> None:
    metadata, paths = repo.metadata, repo.paths
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

    assert [git_path, "init", str(paths.source_checkout_root)] in commands
    assert [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "remote",
        "add",
        "origin",
        metadata.source,
    ] in commands
    assert [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "fetch",
        "--depth",
        "1",
        "origin",
        metadata.commit,
    ] in commands
    assert [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "checkout",
        "--force",
        metadata.commit,
    ] in commands
    assert [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "clean",
        "-fdx",
    ] in commands


def test_ensure_source_checkout_resets_existing_cache_when_origin_mismatches(
    repo: Repo,
) -> None:
    metadata, paths = repo.metadata, repo.paths
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

    assert [git_path, "init", str(paths.source_checkout_root)] in commands
    assert [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "remote",
        "add",
        "origin",
        metadata.source,
    ] in commands


def _stub_source_checkout_run(
    git_path: str,
    source_root: Path,
    commands: list[list[str]],
    *,
    fetch_failures: int = 0,
    fail_checkout: bool = False,
    fail_clean: bool = False,
) -> Callable[..., bootstrap.subprocess.CompletedProcess[str]]:
    remaining_fetch_failures = [fetch_failures]

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
            (Path(command[2]) / ".git").mkdir(parents=True, exist_ok=True)
        if command[3:4] == ["fetch"] and remaining_fetch_failures[0] > 0:
            remaining_fetch_failures[0] -= 1
            raise bootstrap.subprocess.CalledProcessError(
                128,
                command,
                output="",
                stderr="fatal: unable to access 'https://github.com/': Could not resolve host",
            )
        if command[3:4] == ["checkout"]:
            if fail_checkout:
                raise bootstrap.subprocess.CalledProcessError(
                    1,
                    command,
                    output="",
                    stderr="error: pathspec did not match any file(s) known to git",
                )
            include_root = source_root / "include"
            include_root.mkdir(parents=True, exist_ok=True)
            (source_root / "build.zig").write_text("// build\n")
            (include_root / "ghostty.h").write_text("// header\n")
            (include_root / "module.modulemap").write_text("module GhosttyKit {}\n")
        if command[3:4] == ["clean"] and fail_clean:
            raise bootstrap.subprocess.CalledProcessError(
                1,
                command,
                output="",
                stderr="warning: failed to remove src/generated: Permission denied",
            )
        return bootstrap.subprocess.CompletedProcess(command, 0, "", "")

    return fake_run


def test_ensure_source_checkout_retries_a_transient_fetch_failure(
    repo: Repo,
) -> None:
    metadata, paths = repo.metadata, repo.paths
    git_path = "/usr/bin/git"
    commands: list[list[str]] = []
    delays: list[float] = []

    with (
        mock.patch.object(bootstrap, "resolve_tool", return_value=git_path),
        mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=_stub_source_checkout_run(
                git_path,
                paths.source_checkout_root,
                commands,
                fetch_failures=1,
            ),
        ),
        mock.patch("builtins.print"),
    ):
        bootstrap.ensure_source_checkout(
            paths,
            metadata,
            git="git",
            sleep=delays.append,
        )

    fetch_command = [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "fetch",
        "--depth",
        "1",
        "origin",
        metadata.commit,
    ]
    assert [command for command in commands if command == fetch_command] == [
        fetch_command
    ] * 2
    assert len(delays) == 1
    assert [
        git_path,
        "-C",
        str(paths.source_checkout_root),
        "checkout",
        "--force",
        metadata.commit,
    ] in commands


def test_ensure_source_checkout_reports_the_pinned_revision_and_git_stderr_when_fetch_never_succeeds(
    repo: Repo,
) -> None:
    metadata, paths = repo.metadata, repo.paths
    git_path = "/usr/bin/git"
    commands: list[list[str]] = []

    with (
        mock.patch.object(bootstrap, "resolve_tool", return_value=git_path),
        mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=_stub_source_checkout_run(
                git_path,
                paths.source_checkout_root,
                commands,
                fetch_failures=bootstrap.SOURCE_FETCH_ATTEMPTS,
            ),
        ),
        mock.patch("builtins.print"),
        pytest.raises(bootstrap.BootstrapError) as raised,
    ):
        bootstrap.ensure_source_checkout(
            paths, metadata, git="git", sleep=lambda _: None
        )

    message = str(raised.value)
    assert metadata.commit in message
    assert metadata.source in message
    assert "Could not resolve host" in message
    assert (
        len([command for command in commands if command[3:4] == ["fetch"]])
        == bootstrap.SOURCE_FETCH_ATTEMPTS
    )
    assert [command for command in commands if command[3:4] == ["checkout"]] == []


def test_ensure_source_checkout_distinguishes_a_checkout_failure_from_a_fetch_failure(
    repo: Repo,
) -> None:
    metadata, paths = repo.metadata, repo.paths
    git_path = "/usr/bin/git"
    commands: list[list[str]] = []

    with (
        mock.patch.object(bootstrap, "resolve_tool", return_value=git_path),
        mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=_stub_source_checkout_run(
                git_path,
                paths.source_checkout_root,
                commands,
                fail_checkout=True,
            ),
        ),
        pytest.raises(bootstrap.BootstrapError) as raised,
    ):
        bootstrap.ensure_source_checkout(
            paths, metadata, git="git", sleep=lambda _: None
        )

    message = str(raised.value)
    assert "check out" in message
    assert "pathspec did not match" in message
    assert len([command for command in commands if command[3:4] == ["fetch"]]) == 1


def test_ensure_source_checkout_distinguishes_a_clean_failure_from_a_checkout_failure(
    repo: Repo,
) -> None:
    metadata, paths = repo.metadata, repo.paths
    git_path = "/usr/bin/git"
    commands: list[list[str]] = []

    with (
        mock.patch.object(bootstrap, "resolve_tool", return_value=git_path),
        mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=_stub_source_checkout_run(
                git_path,
                paths.source_checkout_root,
                commands,
                fail_clean=True,
            ),
        ),
        pytest.raises(bootstrap.BootstrapError) as raised,
    ):
        bootstrap.ensure_source_checkout(
            paths, metadata, git="git", sleep=lambda _: None
        )

    message = str(raised.value)
    assert "clean" in message
    assert "check out" not in message
    assert "Permission denied" in message


@pytest.mark.parametrize(
    ("staged_synced", "expected_output"),
    [
        (False, ""),
        (True, "Activated cached libghostty artifacts at /tmp/libghostty\n"),
    ],
    ids=["ready", "activated"],
)
def test_main_quiet_noop_reports_only_artifact_changes(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    staged_synced: bool,
    expected_output: str,
) -> None:
    paths = mock.Mock()
    paths.vendor_metadata_path = Path("/tmp/ghostty.version.json")
    paths.staged_artifacts = mock.Mock(root=Path("/tmp/libghostty"))
    metadata = mock.Mock()
    refresh = mock.Mock()
    monkeypatch.setattr(
        bootstrap.BootstrapPaths, "from_repo_root", lambda *_, **__: paths
    )
    monkeypatch.setattr(bootstrap.VendorMetadata, "load", lambda _: metadata)
    monkeypatch.setattr(
        bootstrap,
        "bootstrap",
        lambda **_: bootstrap.BootstrapResult(False, staged_synced),
    )
    monkeypatch.setattr(bootstrap, "refresh_swiftpm_manifest", refresh)

    result = bootstrap.main(["--quiet-noop"])

    assert result == 0
    assert capsys.readouterr().out == expected_output
    assert refresh.call_args_list == ([mock.call(paths)] if staged_synced else [])


def _paths(
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
    artifacts: bootstrap.ArtifactPaths,
    metadata: bootstrap.VendorMetadata,
    *,
    optimize: str = "Debug",
    xcframework_target: str = "native",
) -> None:
    _write_artifacts(
        artifacts,
        metadata,
        optimize=optimize,
        xcframeworkTarget=xcframework_target,
    )


def _write_artifacts(
    artifacts: bootstrap.ArtifactPaths,
    metadata: bootstrap.VendorMetadata,
    **overrides: object,
) -> None:
    manifest: dict[str, object] = {
        "ghosthubBootstrapVersion": bootstrap.GHOSTHUB_BOOTSTRAP_VERSION,
        "ghosttyBundleID": bootstrap.GHOSTHUB_GHOSTTY_BUNDLE_ID,
        "embeddedEnvIsolation": True,
        "macosLoginQuiet": True,
        "ghosttyConfigLoadExport": True,
        "surfaceInjectOutputExport": True,
        "childWriteCallback": True,
        "ghosttyCommit": metadata.commit,
        "termProgram": bootstrap.GHOSTHUB_TERM_PROGRAM,
        "requiredZigVersion": metadata.required_zig_version,
        "i18nEnabled": False,
        "sentryEnabled": False,
        "optimize": "Debug",
        "xcframeworkTarget": "native",
    }
    manifest.update(overrides)

    artifacts.root.mkdir(parents=True, exist_ok=True)
    artifacts.xcframework_path.mkdir(parents=True)
    _write_share_tree(artifacts.share_path)
    artifacts.header_path.parent.mkdir(parents=True, exist_ok=True)
    artifacts.header_path.write_text("// header\n")
    artifacts.modulemap_path.write_text("module GhosttyKit {}\n")
    artifacts.manifest_path.write_text(json.dumps(manifest))


def _write_share_tree(share_root: Path) -> Path:
    themes = share_root.joinpath(*bootstrap.THEMES_RELATIVE_PATH)
    themes.mkdir(parents=True)
    (themes / "Catppuccin Macchiato").write_text("background = #24273a\n")
    share_root.joinpath(*bootstrap.SHELL_INTEGRATION_RELATIVE_PATH).mkdir(
        parents=True
    )
    terminfo = share_root.joinpath(*bootstrap.TERMINFO_RELATIVE_PATH)
    terminfo.parent.mkdir(parents=True)
    terminfo.write_bytes(b"")
    return share_root


def _create_repo_layout(repo_root: Path) -> bootstrap.VendorMetadata:
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
