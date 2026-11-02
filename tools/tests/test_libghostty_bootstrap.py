from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

import libghostty_bootstrap as bootstrap
import pytest

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
    shutil.copy2(broken, slice_dir / "libghostty-internal.a")
    message = bootstrap.artifact_state_message(artifacts, metadata, "native", "Debug")
    assert message is not None
    assert "ghostty API" in message

    healthy = _make_archive(workdir, "libhealthy.a", "ghostty_app_new")
    shutil.copy2(healthy, slice_dir / "libghostty-internal.a")
    assert (
        bootstrap.artifact_state_message(artifacts, metadata, "native", "Debug") is None
    )


def test_clipboard_write_patch_marks_both_osc52_paths(tmp_path: Path) -> None:
    surface = tmp_path / "Surface.zig"
    surface.write_text(
        """    self.rt_surface.setClipboard(loc, &.{.{
        .mime = "text/plain",
        .data = buf[0..decoded.len :0],
    }}, confirm) catch |err| {
        return err;
    };

            try self.rt_surface.setClipboard(clipboard, &.{.{
                .mime = "text/plain",
                .data = data,
            }}, !complete.confirmed);
"""
    )
    bootstrap.patch_clipboard_write_origin(surface)
    patched = surface.read_text()
    bootstrap.patch_clipboard_write_origin(surface)
    assert surface.read_text() == patched
    assert patched.count("application/x-ghosthub-osc52") == 2
    assert ".data = buf[0..decoded.len :0]" in patched
    assert ".data = data" in patched


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
            step.root_module.linkLibrary(libintl_dep.artifact("intl"));
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
                .headers = headers,
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

        .native => switch (builtin.target.cpu.arch) {
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


@pytest.mark.parametrize("version", ["0.16.0", "0.18.0", "1.0.0", "0.17.0-dev.1"])
def test_ensure_supported_zig_version_rejects_incompatible_version(version: str) -> None:
    with pytest.raises(
        bootstrap.BootstrapError,
        match="requires Zig 0.17.0",
    ):
        bootstrap.ensure_supported_zig_version(version, "0.17.0")


@pytest.mark.parametrize("version", ["0.17.0", "0.17.1"])
def test_ensure_supported_zig_version_accepts_compatible_patch_releases(version: str) -> None:
    bootstrap.ensure_supported_zig_version(version, "0.17.0")


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


DOWNLOAD_RESET = (
    "./build.zig.zon:27:20: error: HTTP response read failure: ConnectionResetByPeer"
)
DOWNLOAD_TIMEOUT = (
    "./build.zig.zon:15:20: error: HTTP response read failure: ConnectionTimedOut"
)
COMPILE_ERROR = "src/main.zig:4:5: error: expected type 'u32', found 'bool'"


@pytest.mark.parametrize(
    ("failures", "attempts", "succeeds"),
    [
        ([], 1, True),
        ([DOWNLOAD_RESET], 2, True),
        ([DOWNLOAD_RESET, DOWNLOAD_RESET], 3, True),
        ([DOWNLOAD_RESET] * 3, 3, False),
        ([COMPILE_ERROR], 1, False),
        ([DOWNLOAD_RESET, COMPILE_ERROR], 2, False),
        (
            ["./build.zig.zon:27:20: error: bad HTTP response code: '404 Not Found'"],
            1,
            False,
        ),
        (["./build.zig.zon:27:20: error: hash mismatch"], 1, False),
        ([DOWNLOAD_RESET + "\n" + COMPILE_ERROR], 1, False),
        ([DOWNLOAD_TIMEOUT], 2, True),
        ([DOWNLOAD_RESET, DOWNLOAD_TIMEOUT], 3, True),
        ([DOWNLOAD_TIMEOUT] * 3, 3, False),
        ([DOWNLOAD_TIMEOUT + "\n" + COMPILE_ERROR], 1, False),
    ],
    ids=[
        "success",
        "recovers",
        "last-attempt",
        "exhausted",
        "compiler",
        "compiler-after-reset",
        "not-found",
        "hash",
        "mixed-errors",
        "timeout-recovers",
        "reset-then-timeout",
        "timeout-exhausted",
        "timeout-and-compiler",
    ],
)
def test_bootstrap_retries_only_interrupted_dependency_downloads(
    repo: Repo,
    capfd: pytest.CaptureFixture[str],
    failures: list[str],
    attempts: int,
    succeeds: bool,
) -> None:
    source = repo.paths.source_checkout_root
    source.mkdir(parents=True)
    _write_share_tree(source / "zig-out" / "share")
    (source / "macos" / "GhosttyKit.xcframework").mkdir(parents=True)
    (source / "include").mkdir()
    (source / "include" / "ghostty.h").write_text("// header\n")
    (source / "include" / "module.modulemap").write_text("module GhosttyKit {}\n")
    zig = repo.root / "zig"
    zig.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        "from pathlib import Path\n"
        "if sys.argv[1:] == ['version']:\n"
        f"    print({repo.metadata.required_zig_version!r})\n"
        "    sys.exit(0)\n"
        "assert sys.argv[1] == 'build'\n"
        "assert '-Dxcframework-target=native' in sys.argv\n"
        "assert os.environ['BOOTSTRAP_FIXTURE'] == 'kept'\n"
        "count = Path('attempts')\n"
        "attempt = int(count.read_text()) + 1 if count.exists() else 1\n"
        "count.write_text(str(attempt))\n"
        f"failures = {failures!r}\n"
        "if attempt <= len(failures):\n"
        "    print(failures[attempt - 1], file=sys.stderr)\n"
        "    sys.exit(1)\n"
        "print('build complete')\n"
    )
    zig.chmod(0o755)
    with (
        mock.patch.object(bootstrap, "ensure_source_checkout"),
        mock.patch.object(bootstrap, "apply_ghosthub_source_patches"),
        mock.patch.object(
            bootstrap,
            "resolve_tool",
            side_effect=lambda tool: str(zig) if tool == "zig" else tool,
        ),
        mock.patch.object(bootstrap, "ensure_metal_toolchain"),
        mock.patch.object(
            bootstrap, "zig_executable_architecture", return_value="aarch64"
        ),
        mock.patch.object(
            bootstrap,
            "prepare_zig_build_environment",
            return_value={**os.environ, "BOOTSTRAP_FIXTURE": "kept"},
        ),
        mock.patch.object(bootstrap.time, "sleep"),
    ):
        def build() -> bootstrap.BootstrapResult:
            return bootstrap.bootstrap(
                paths=repo.paths,
                metadata=repo.metadata,
                git="git",
                zig="zig",
                xcodebuild="xcodebuild",
                xcrun="xcrun",
                xcframework_target="native",
                optimize="Debug",
            )

        if succeeds:
            result = build()
            assert result.rebuilt_variant and result.staged_synced
            assert repo.paths.staged_artifacts.header_path.read_text() == "// header\n"
        else:
            with pytest.raises(bootstrap.BootstrapError) as raised:
                build()
            if failures[-1] in (DOWNLOAD_RESET, DOWNLOAD_TIMEOUT):
                assert "3 attempts" in str(raised.value)
            else:
                assert "full Xcode installation selected via `xcode-select`" in str(
                    raised.value
                )
            assert not repo.paths.cached_artifacts.manifest_path.exists()
            assert not repo.paths.staged_artifacts.root.exists()

    assert (source / "attempts").read_text() == str(attempts)
    captured = capfd.readouterr()
    output = captured.out + captured.err
    for failure in failures:
        assert failure in output
    if succeeds:
        assert "build complete" in output


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
