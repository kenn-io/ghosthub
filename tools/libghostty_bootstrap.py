from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

GHOSTHUB_BOOTSTRAP_VERSION = 28
GHOSTHUB_GHOSTTY_BUNDLE_ID = "com.ghosthub"
GHOSTHUB_TERM_PROGRAM = "ghosthub"
SOURCE_FETCH_ATTEMPTS = 3
SOURCE_FETCH_RETRY_DELAY_SECONDS = 5.0

class BootstrapError(RuntimeError):
    pass


# libghostty resolves themes, shell integration, and terminfo from a `share`
# tree it locates by climbing from the running executable. `zig build` emits
# that tree next to the xcframework; it is then staged as a first-class
# artifact that both the repo-local dev layout and app bundles read.
EMITTED_SHARE_RELATIVE_PATH = ("zig-out", "share")
THEMES_RELATIVE_PATH = ("ghostty", "themes")
SHELL_INTEGRATION_RELATIVE_PATH = ("ghostty", "shell-integration")
TERMINFO_RELATIVE_PATH = ("terminfo", "78", "xterm-ghostty")


def share_tree_problem(share_root: Path) -> str | None:
    """Describe why a `share` tree cannot serve libghostty, if it cannot.

    Existence alone is not enough: an empty theme directory resolves no
    theme names at all, and the terminfo sentinel is what libghostty
    matches when it climbs for a resources directory.
    """
    themes = share_root.joinpath(*THEMES_RELATIVE_PATH)
    if not themes.is_dir():
        return f"the bundled theme corpus at {themes} is missing"
    if not any(themes.iterdir()):
        return f"the bundled theme corpus at {themes} is empty"

    shell_integration = share_root.joinpath(*SHELL_INTEGRATION_RELATIVE_PATH)
    if not shell_integration.is_dir():
        return f"{shell_integration} is missing"

    terminfo = share_root.joinpath(*TERMINFO_RELATIVE_PATH)
    if not terminfo.is_file():
        return f"the compiled terminfo entry at {terminfo} is missing"

    return None


@dataclass(frozen=True)
class VendorMetadata:
    source: str
    tag: str
    commit: str
    required_zig_version: str

    @classmethod
    def load(cls, path: Path) -> "VendorMetadata":
        if not path.exists():
            raise BootstrapError(
                f"Ghostty version metadata is missing at {path}. "
                "Restore `Vendor/ghostty.version.json` before bootstrapping libghostty."
            )

        payload = json.loads(path.read_text())
        return cls(
            source=payload["source"],
            tag=payload["tag"],
            commit=payload["commit"],
            required_zig_version=payload["required_zig_version"],
        )


@dataclass(frozen=True)
class ArtifactPaths:
    root: Path
    xcframework_path: Path
    share_path: Path
    header_path: Path
    modulemap_path: Path
    manifest_path: Path

    @classmethod
    def from_root(cls, root: Path) -> "ArtifactPaths":
        include_root = root / "include"
        return cls(
            root=root,
            xcframework_path=root / "GhosttyKit.xcframework",
            share_path=root / "share",
            header_path=include_root / "ghostty.h",
            modulemap_path=include_root / "module.modulemap",
            manifest_path=root / "manifest.json",
        )


@dataclass(frozen=True)
class BootstrapPaths:
    repo_root: Path
    package_manifest_path: Path
    vendor_metadata_path: Path
    staged_artifacts: ArtifactPaths
    cached_artifacts: ArtifactPaths
    source_checkout_root: Path

    @classmethod
    def from_repo_root(
        cls,
        repo_root: Path,
        *,
        xcframework_target: str,
        optimize: str,
    ) -> "BootstrapPaths":
        resolved_root = repo_root.resolve()
        staged_build_root = resolved_root / ".build" / "libghostty"
        cached_build_root = (
            resolved_root / ".build" / "libghostty-variants" / f"{xcframework_target}-{optimize}"
        )
        return cls(
            repo_root=resolved_root,
            package_manifest_path=resolved_root / "Package.swift",
            vendor_metadata_path=resolved_root / "Vendor" / "ghostty.version.json",
            staged_artifacts=ArtifactPaths.from_root(staged_build_root),
            cached_artifacts=ArtifactPaths.from_root(cached_build_root),
            source_checkout_root=cached_build_root / "source",
        )


@dataclass(frozen=True)
class BootstrapResult:
    rebuilt_variant: bool
    staged_synced: bool


def render_build_command(
    zig_path: str,
    xcframework_target: str,
    optimize: str,
) -> list[str]:
    command = [
        zig_path,
        "build",
        "-Dapp-runtime=none",
        "-Demit-xcframework=true",
        "-Demit-macos-app=false",
        # The bundled iTerm2 theme corpus is the source for `theme = <name>`.
        # Without it libghostty resolves only user themes under
        # ~/.config/ghostty/themes.
        "-Demit-themes=true",
        "-Di18n=false",
        "-Dsentry=false",
        f"-Doptimize={optimize}",
        f"-Dxcframework-target={xcframework_target}",
    ]
    # LIBGHOSTTY_ZIG_BUILD_ARGS appends machine-specific target flags to the
    # `zig build` invocation. A `--sysroot` value here does not affect Zig's
    # own build-runner compile; prepare_zig_build_environment handles that SDK
    # selection before this command runs.
    extra = os.environ.get("LIBGHOSTTY_ZIG_BUILD_ARGS", "").strip()
    if extra:
        command.extend(shlex.split(extra))
    return command


def resolve_tool(tool: str) -> str:
    if Path(tool).is_absolute():
        if not Path(tool).exists():
            raise BootstrapError(f"Required tool not found: {tool}")
        return tool

    resolved = shutil.which(tool)
    if resolved is None:
        raise BootstrapError(f"Required tool not found on PATH: {tool}")
    return resolved


def read_tool_output(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def ensure_source_checkout_layout(paths: BootstrapPaths) -> None:
    required_paths = [
        paths.source_checkout_root / "build.zig",
        paths.source_checkout_root / "include" / "ghostty.h",
        paths.source_checkout_root / "include" / "module.modulemap",
    ]
    missing = [path for path in required_paths if not path.exists()]
    if missing:
        formatted = ", ".join(str(path) for path in missing)
        raise BootstrapError(
            "Pinned Ghostty source checkout is incomplete. Missing required paths: "
            f"{formatted}"
        )


def reset_source_checkout(source_root: Path) -> None:
    if source_root.exists():
        shutil.rmtree(source_root)


def initialize_source_checkout(
    git_path: str,
    source_url: str,
    source_root: Path,
) -> None:
    source_root.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [git_path, "init", str(source_root)],
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [git_path, "-C", str(source_root), "remote", "add", "origin", source_url],
        check=True,
        capture_output=True,
        text=True,
    )


def describe_command_failure(error: subprocess.CalledProcessError) -> str:
    lines = [f"`{shlex.join(error.cmd)}` exited with status {error.returncode}."]
    for label, stream in (("stdout", error.stdout), ("stderr", error.stderr)):
        text = (stream or "").strip()
        if text:
            lines.append(f"{label}: {text}")
    return "\n".join(lines)


def fetch_source_revision(
    git_path: str,
    source_root: Path,
    metadata: VendorMetadata,
    *,
    attempts: int = SOURCE_FETCH_ATTEMPTS,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    """Fetch the pinned revision, retrying so a transient network fault is not fatal."""
    for attempt in range(1, attempts + 1):
        try:
            subprocess.run(
                [
                    git_path,
                    "-C",
                    str(source_root),
                    "fetch",
                    "--depth",
                    "1",
                    "origin",
                    metadata.commit,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            return
        except subprocess.CalledProcessError as error:
            if attempt == attempts:
                raise BootstrapError(
                    f"Failed to fetch pinned Ghostty revision {metadata.commit} "
                    f"({metadata.tag}) from {metadata.source} after {attempts} attempts. "
                    "Verify network access and confirm the pinned revision still exists.\n"
                    f"{describe_command_failure(error)}"
                ) from error
            print(
                f"Fetching Ghostty {metadata.commit} failed on attempt {attempt} of "
                f"{attempts}; retrying.\n{describe_command_failure(error)}"
            )
            sleep(SOURCE_FETCH_RETRY_DELAY_SECONDS * attempt)


def ensure_source_checkout(
    paths: BootstrapPaths,
    metadata: VendorMetadata,
    *,
    git: str = "git",
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    git_path = resolve_tool(git)
    source_root = paths.source_checkout_root

    if not (source_root / ".git").exists():
        reset_source_checkout(source_root)
        try:
            initialize_source_checkout(git_path, metadata.source, source_root)
        except subprocess.CalledProcessError as error:
            raise BootstrapError(
                f"Failed to initialize local Ghostty checkout at {source_root}.\n"
                f"{describe_command_failure(error)}"
            ) from error
    else:
        try:
            origin_url = read_tool_output(
                [git_path, "-C", str(source_root), "remote", "get-url", "origin"]
            )
        except subprocess.CalledProcessError:
            reset_source_checkout(source_root)
            try:
                initialize_source_checkout(git_path, metadata.source, source_root)
            except subprocess.CalledProcessError as error:
                raise BootstrapError(
                    f"Failed to reinitialize local Ghostty checkout at {source_root}.\n"
                    f"{describe_command_failure(error)}"
                ) from error
        else:
            if origin_url != metadata.source:
                reset_source_checkout(source_root)
                try:
                    initialize_source_checkout(git_path, metadata.source, source_root)
                except subprocess.CalledProcessError as error:
                    raise BootstrapError(
                        f"Failed to reinitialize local Ghostty checkout at {source_root}."
                    ) from error

    fetch_source_revision(git_path, source_root, metadata, sleep=sleep)

    try:
        subprocess.run(
            [git_path, "-C", str(source_root), "checkout", "--force", metadata.commit],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        raise BootstrapError(
            f"Failed to check out pinned Ghostty revision {metadata.commit} in {source_root}. "
            "Delete that directory and rerun `python3 tools/bootstrap_libghostty.py`.\n"
            f"{describe_command_failure(error)}"
        ) from error

    try:
        subprocess.run(
            [git_path, "-C", str(source_root), "clean", "-fdx"],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        raise BootstrapError(
            f"Failed to clean the Ghostty checkout at {source_root}. "
            "Delete that directory and rerun `python3 tools/bootstrap_libghostty.py`.\n"
            f"{describe_command_failure(error)}"
        ) from error

    ensure_source_checkout_layout(paths)


def apply_ghosthub_source_patches(paths: BootstrapPaths) -> None:
    patch_build_config_bundle_id(paths.source_checkout_root / "src" / "build_config.zig")
    patch_public_header(paths.source_checkout_root / "include" / "ghostty.h")
    patch_preserve_presented_frame(paths.source_checkout_root / "src" / "renderer" / "metal" / "Target.zig")
    patch_embedded_runtime_env(paths.source_checkout_root / "src" / "apprt" / "embedded.zig")
    patch_surface_child_pid_export(paths.source_checkout_root / "src" / "apprt" / "embedded.zig")
    patch_surface_child_exit_code_state(paths.source_checkout_root / "src" / "Surface.zig")
    patch_surface_child_exit_code_export(
        paths.source_checkout_root / "src" / "apprt" / "embedded.zig"
    )
    patch_surface_inject_output_export(
        paths.source_checkout_root / "src" / "apprt" / "embedded.zig"
    )
    patch_clipboard_request_type_export(
        paths.source_checkout_root / "src" / "apprt" / "embedded.zig"
    )
    patch_child_write_header(paths.source_checkout_root / "include" / "ghostty.h")
    patch_child_write_message(paths.source_checkout_root / "src" / "apprt" / "surface.zig")
    patch_child_write_dispatch(paths.source_checkout_root / "src" / "Surface.zig")
    patch_clipboard_write_origin(paths.source_checkout_root / "src" / "Surface.zig")
    patch_child_write_embedded(paths.source_checkout_root / "src" / "apprt" / "embedded.zig")
    patch_child_write_termio(paths.source_checkout_root / "src" / "termio" / "Termio.zig")
    patch_macos_login_quiet(paths.source_checkout_root / "src" / "termio" / "Exec.zig")
    patch_term_program_env(paths.source_checkout_root / "src" / "termio" / "Exec.zig")
    patch_libintl_i18n_guard(
        paths.source_checkout_root / "src" / "build" / "SharedDeps.zig"
    )
    patch_apple_silicon_xcframework_target(
        paths.source_checkout_root / "src" / "build" / "xcframework.zig",
        paths.source_checkout_root / "src" / "build" / "GhosttyXCFramework.zig",
        paths.source_checkout_root / "src" / "build" / "GhosttyXcodebuild.zig",
    )


def patch_build_config_bundle_id(path: Path) -> None:
    original = 'pub const bundle_id = "com.mitchellh.ghostty";'
    replacement = f'pub const bundle_id = "{GHOSTHUB_GHOSTTY_BUNDLE_ID}";'
    patch_source_file(
        path,
        original=original,
        replacement=replacement,
        already_applied=replacement,
        description="Ghostty bundle id override",
    )


def patch_preserve_presented_frame(path: Path) -> None:
    patch_source_file(
        path,
        original="""pub fn deinit(self: *Self) void {
    self.surface.deinit();
    self.texture.release();
}""",
        replacement="""pub fn deinit(self: *Self) void {
    // Core Animation may still display these pixels in previews or other Spaces.
    // Release our reference without marking the shared image purgeable.
    self.surface.release();
    self.texture.release();
}""",
        already_applied="    self.surface.release();",
        description="Ghosthub retained preview image lifetime",
    )


def patch_public_header(path: Path) -> None:
    declarations = {
        "GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);": (
            "GHOSTTY_API int ghostty_surface_child_pid(ghostty_surface_t);\n"
            "GHOSTTY_API int ghostty_surface_child_exit_code(ghostty_surface_t);"
        ),
        "GHOSTTY_API void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);":
            "GHOSTTY_API void ghostty_surface_inject_output(ghostty_surface_t, const char*, uintptr_t);",
        "GHOSTTY_API void ghostty_surface_complete_clipboard_request(":
            "GHOSTTY_API ghostty_clipboard_request_e ghostty_clipboard_request_type(void*);",
    }
    for anchor, declaration in declarations.items():
        patch_source_file(
            path,
            original=anchor,
            replacement=declaration + "\n" + anchor,
            already_applied=declaration,
            description="Ghosthub embedding API declarations",
        )


def patch_embedded_runtime_env(path: Path) -> None:
    original = """        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
"""
    replacement = """        stripGhosthubLauncherEnv(&env);
        return env;
    }

    fn stripGhosthubLauncherEnv(
        env: *std.process.Environ.Map,
    ) void {
        const exact_keys = [_][]const u8{
            "__CFBundleIdentifier",
            "EDITOR",
            "OLDPWD",
            "PROMPT",
            "PROMPT_COMMAND",
            "PWD",
            "RPROMPT",
            "SHLVL",
            "TERMINFO",
            "TERM_PROGRAM",
            "TERM_PROGRAM_VERSION",
            "VISUAL",
            "WINDOWID",
            "_",
        };
        inline for (exact_keys) |key| _ = env.orderedRemove(key);

        const prefixes = [_][]const u8{
            "ALACRITTY_",
            "CONDA_",
            "FZF_",
            "ITERM",
            "KITTY_",
            "NVM_",
            "PYENV_",
            "STARSHIP_",
            "VIRTUAL_ENV",
            "WEZTERM_",
            "WT_",
        };

        // Remove backwards because orderedRemove shifts the remaining keys.
        var index = env.keys().len;
        while (index > 0) {
            index -= 1;
            const key = env.keys()[index];
            inline for (prefixes) |prefix| {
                if (std.mem.startsWith(u8, key, prefix)) {
                    _ = env.orderedRemove(key);
                    break;
                }
            }
        }
    }

    /// The cursor position from the host directly is in screen coordinates but
"""
    patch_source_file(
        path,
        original=original,
        replacement=replacement,
        already_applied="stripGhosthubLauncherEnv(&env);",
        description="Ghostty embedded launcher environment isolation",
    )


def patch_surface_child_pid_export(path: Path) -> None:
    patch_source_file(
        path,
        original="""    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }
""",
        replacement="""    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    export fn ghostty_surface_child_pid(surface: *Surface) c_int {
        return switch (surface.core_surface.io.backend) {
            .exec => |exec_backend| blk: {
                const process = exec_backend.subprocess.process orelse break :blk 0;
                const command = switch (process) {
                    .fork_exec => |command| command,
                    else => break :blk 0,
                };
                const pid = command.pid orelse break :blk 0;
                break :blk @intCast(pid);
            },
        };
    }
""",
        already_applied="export fn ghostty_surface_child_pid(surface: *Surface) c_int {",
        description="Ghostty surface child-pid export",
    )


def patch_surface_child_exit_code_state(path: Path) -> None:
    patch_source_file(
        path,
        original="""/// This is set to true if our IO thread notifies us our child exited.
/// This is used to determine if we need to confirm, hold open, etc.
child_exited: bool = false,
""",
        replacement="""/// This is set to true if our IO thread notifies us our child exited.
/// This is used to determine if we need to confirm, hold open, etc.
child_exited: bool = false,

/// The child exit status reported by the IO thread.
child_exit_code: ?u32 = null,
""",
        already_applied="child_exit_code: ?u32 = null,",
        description="Ghostty surface child-exit-code state",
    )
    patch_source_file(
        path,
        original="""    // Mark our flag that we exited immediately
    self.child_exited = true;
""",
        replacement="""    // Mark our exit state immediately so close callbacks can inspect it.
    self.child_exited = true;
    self.child_exit_code = info.exit_code;
""",
        already_applied="self.child_exit_code = info.exit_code;",
        description="Ghostty surface child-exit-code capture",
    )


def patch_surface_child_exit_code_export(path: Path) -> None:
    patch_source_file(
        path,
        original="""    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }
""",
        replacement="""    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    export fn ghostty_surface_child_exit_code(surface: *Surface) c_int {
        const exit_code = surface.core_surface.child_exit_code orelse return -1;
        return @intCast(exit_code);
    }
""",
        already_applied="export fn ghostty_surface_child_exit_code(surface: *Surface) c_int {",
        description="Ghostty surface child-exit-code export",
    )


def patch_surface_inject_output_export(path: Path) -> None:
    patch_source_file(
        path,
        original="""    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }
""",
        replacement="""    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Inject raw terminal output data into the surface's terminal
    /// emulator, bypassing the PTY. This is used for tmux control mode
    /// where output arrives over a control connection rather than a PTY.
    /// Adapted from fantastty (MIT, (c) 2026 Blaine Cook).
    export fn ghostty_surface_inject_output(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.core_surface.io.processOutput(ptr[0..len]);
    }
""",
        already_applied="export fn ghostty_surface_inject_output(",
        description="Ghostty surface inject-output export",
    )


def patch_clipboard_request_type_export(path: Path) -> None:
    anchor = "    export fn ghostty_surface_complete_clipboard_request("
    declaration = """    export fn ghostty_clipboard_request_type(
        state: *apprt.ClipboardRequest,
    ) c_int {
        return @intCast(@backingInt(std.meta.activeTag(state.*)));
    }

"""
    patch_source_file(
        path,
        original=anchor,
        replacement=declaration + anchor,
        already_applied="export fn ghostty_clipboard_request_type(",
        description="libghostty clipboard request-type export",
    )


def patch_child_write_header(path: Path) -> None:
    patch_source_file(
        path,
        original="""typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
""",
        replacement="""typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef void (*ghostty_runtime_child_write_cb)(void*, const char*, uintptr_t);
""",
        already_applied="ghostty_runtime_child_write_cb)(void*, const char*, uintptr_t);",
        description="Ghostty child-write callback typedef",
    )
    patch_source_file(
        path,
        original="""  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;
""",
        replacement="""  ghostty_runtime_close_surface_cb close_surface_cb;
  ghostty_runtime_child_write_cb child_write_cb;
} ghostty_runtime_config_s;
""",
        already_applied="ghostty_runtime_child_write_cb child_write_cb;",
        description="Ghostty child-write runtime-config field",
    )


def patch_child_write_message(path: Path) -> None:
    patch_source_file(
        path,
        original="""    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,
""",
        replacement="""    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal wrote data toward its child process (mouse reports,
    /// query responses, etc.). Forwarded to the host so control-mode
    /// surfaces can relay it; the payload is owned and must be freed.
    child_write: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,
""",
        already_applied="child_write: WriteReq,",
        description="Ghostty child-write surface message",
    )


def patch_child_write_dispatch(path: Path) -> None:
    patch_source_file(
        path,
        original="""        .close => self.close(),

        .child_exited => |v| self.childExited(v),
""",
        replacement="""        .child_write => |w| {
            defer w.deinit();
            self.rt_surface.childWrite(w.slice());
        },

        .close => self.close(),

        .child_exited => |v| self.childExited(v),
""",
        already_applied=".child_write => |w| {",
        description="Ghostty child-write message dispatch",
    )


def patch_clipboard_write_origin(path: Path) -> None:
    """Tag OSC 52 writes so the embedder can distinguish them from user copy."""
    for call, data, ending in (
        ("self.rt_surface.setClipboard(loc,", "buf[0..decoded.len :0]", "confirm) catch |err| {"),
        ("try self.rt_surface.setClipboard(clipboard,", "data", "!complete.confirmed);"),
    ):
        indent = "    " if data.startswith("buf") else "            "
        original = (
            f"{indent}{call} &.{{.{{\n"
            f'{indent}    .mime = "text/plain",\n'
            f"{indent}    .data = {data},\n"
            f"{indent}}}}}, {ending}"
        )
        replacement = (
            f"{indent}{call} &.{{\n"
            f'{indent}    .{{ .mime = "text/plain", .data = {data} }},\n'
            f'{indent}    .{{ .mime = "application/x-ghosthub-osc52", .data = "" }},\n'
            f"{indent}}}, {ending}"
        )
        patch_source_file(
            path,
            original=original,
            replacement=replacement,
            already_applied=replacement,
            description="Ghostty OSC 52 write origin marker",
        )


def patch_child_write_embedded(path: Path) -> None:
    patch_source_file(
        path,
        original="""        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,
    };
""",
        replacement="""        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,

        /// Called when the terminal writes data toward its child process
        /// (e.g. mouse reports, cursor/device query responses). Used to
        /// forward those bytes elsewhere for control-mode (tmux) surfaces
        /// whose child process discards everything.
        child_write: ?*const fn (SurfaceUD, [*]const u8, usize) callconv(.c) void = null,
    };
""",
        already_applied="child_write: ?*const fn (SurfaceUD, [*]const u8, usize) callconv(.c) void = null,",
        description="Ghostty child-write app option",
    )
    patch_source_file(
        path,
        original="""    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }
""",
        replacement="""    /// Forward data the terminal wrote toward its child process to the host.
    /// Used so control-mode (tmux) surfaces can relay terminal-generated
    /// input (mouse reports, query responses) that the silent child discards.
    pub fn childWrite(self: *const Surface, data: []const u8) void {
        const func = self.app.opts.child_write orelse return;
        func(self.userdata, data.ptr, data.len);
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }
""",
        already_applied="pub fn childWrite(self: *const Surface, data: []const u8) void {",
        description="Ghostty child-write surface forwarder",
    )


def patch_child_write_termio(path: Path) -> None:
    patch_source_file(
        path,
        original="""pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}
""",
        replacement="""pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);

    // Mirror everything written toward the child to the host. Control-mode
    // (tmux) surfaces run a silent child that discards these bytes, so the
    // host forwards them (mouse reports, query responses) on to tmux. The
    // push is non-blocking; dropping a message under backpressure is
    // acceptable for these low-volume control writes, but a dropped
    // WriteReq must still be deinitialized or a large payload's heap
    // allocation leaks.
    if (apprt.surface.Message.WriteReq.init(self.alloc, data)) |req| {
        if (self.surface_mailbox.push(.{ .child_write = req }, .{ .instant = {} }) == 0) {
            req.deinit();
        }
    } else |_| {}
}
""",
        already_applied="if (self.surface_mailbox.push(.{ .child_write = req }, .{ .instant = {} }) == 0) {",
        description="Ghostty child-write termio mirror",
    )


def patch_macos_login_quiet(path: Path) -> None:
    contents = path.read_text()

    hush_original = """        const hush = if (passwd.home) |home| hush: {
            var dir = std.Io.Dir.openDirAbsolute(global.io(), home, .{}) catch |err| {
                log.warn(
                    "failed to open home dir, not checking for hushlogin err={}",
                    .{err},
                );
                break :hush false;
            };
            defer dir.close(global.io());

            break :hush if (dir.access(global.io(), ".hushlogin", .{})) true else |_| false;
        } else false;

"""
    if hush_original in contents:
        contents = contents.replace(hush_original, "", 1)

    launch_replacement = """        try args.append(alloc, "/usr/bin/login");
        try args.append(alloc, "-q");
        try args.append(alloc, "-flp");
"""
    if launch_replacement not in contents:
        launch_originals = [
            """        try args.append(alloc, "/usr/bin/login");
        if (hush) try args.append(alloc, "-q");
        try args.append(alloc, "-flp");
""",
            """        try args.append("/usr/bin/login");
        if (hush) try args.append("-q");
        try args.append("-flp");
""",
        ]
        launch_original = next(
            (candidate for candidate in launch_originals if candidate in contents),
            None,
        )
        if launch_original is None:
            raise BootstrapError(
                f"Failed to apply Ghostty macOS quiet login launch to {path}. "
                "The pinned Ghostty source layout changed and the bootstrap patch must be updated."
            )
        contents = contents.replace(launch_original, launch_replacement, 1)

    path.write_text(contents)


def patch_term_program_env(path: Path) -> None:
    original = '        try env.put("TERM_PROGRAM", "ghostty");'
    replacement = f'        try env.put("TERM_PROGRAM", "{GHOSTHUB_TERM_PROGRAM}");'
    patch_source_file(
        path,
        original=original,
        replacement=replacement,
        already_applied=replacement,
        description="Ghostty TERM_PROGRAM isolation",
    )


def patch_libintl_i18n_guard(path: Path) -> None:
    """Do not link static libintl when the embedded build disables i18n."""
    original = '''        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.root_module.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
'''
    obsolete = original.replace(
        'if (b.lazyDependency("libintl", .{',
        'if (self.config.i18n and b.lazyDependency("libintl", .{',
        1,
    )
    contents = path.read_text()
    if obsolete in contents:
        path.write_text(contents.replace(obsolete, original, 1))

    patch_source_file(
        path,
        original=original,
        replacement='''        if (self.config.i18n) {
            if (b.lazyDependency("libintl", .{
                .target = target,
                .optimize = optimize,
            })) |libintl_dep| {
                step.root_module.linkLibrary(libintl_dep.artifact("intl"));
                try static_libs.append(
                    b.allocator,
                    libintl_dep.artifact("intl").getEmittedBin(),
                );
            }
        }
''',
        already_applied="        if (self.config.i18n) {\n",
        description="Ghostty disabled-i18n libintl link guard",
    )


def patch_apple_silicon_xcframework_target(
    target_enum_path: Path,
    ghostty_xcframework_path: Path,
    ghostty_xcodebuild_path: Path,
) -> None:
    patch_source_file(
        target_enum_path,
        original="pub const Target = enum { native, universal };",
        replacement="pub const Target = enum { native, universal, aarch64 };",
        already_applied="pub const Target = enum { native, universal, aarch64 };",
        description="Ghostty Apple Silicon xcframework target enum",
    )

    macos_native_block = """    const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));
"""
    macos_aarch64_block = macos_native_block + """
    const macos_aarch64 = try GhosttyLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, .aarch64),
    ));
"""
    patch_source_file(
        ghostty_xcframework_path,
        original=macos_native_block,
        replacement=macos_aarch64_block,
        already_applied="const macos_aarch64 = try GhosttyLib.initStatic",
        description="Ghostty Apple Silicon xcframework build target",
    )

    native_switch_case = """            .native => &.{.{
                .library = macos_native.output,
                .headers = headers,
                .dsym = macos_native.dsym,
            }},
"""
    aarch64_switch_case = native_switch_case + """
            .aarch64 => &.{.{
                .library = macos_aarch64.output,
                .headers = headers,
                .dsym = macos_aarch64.dsym,
            }},
"""
    patch_source_file(
        ghostty_xcframework_path,
        original=native_switch_case,
        replacement=aarch64_switch_case,
        already_applied=".aarch64 => &.{.{",
        description="Ghostty Apple Silicon xcframework switch case",
    )

    native_arch_case = """        .native => switch (builtin.target.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS arch"),
        },
"""
    aarch64_arch_case = native_arch_case + """
        .aarch64 => "arm64",
"""
    patch_source_file(
        ghostty_xcodebuild_path,
        original=native_arch_case,
        replacement=aarch64_arch_case,
        already_applied='        },\n\n        .aarch64 => "arm64",\n',
        description="Ghostty Apple Silicon xcodebuild arch switch case",
    )


def patch_source_file(
    path: Path,
    *,
    original: str,
    replacement: str,
    already_applied: str,
    description: str,
) -> None:
    contents = path.read_text()
    if already_applied in contents:
        return
    if original not in contents:
        raise BootstrapError(
            f"Failed to apply {description} to {path}. "
            "The pinned Ghostty source layout changed and the bootstrap patch must be updated."
        )
    path.write_text(contents.replace(original, replacement, 1))


def parse_semver(version: str) -> tuple[int, int, int]:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", version)
    if match is None:
        raise BootstrapError(
            f"Could not parse Zig version from `{version}`."
        )
    return tuple(int(part) for part in match.groups())


def ensure_supported_zig_version(version: str, minimum_version: str) -> None:
    current = parse_semver(version)
    required = parse_semver(minimum_version)
    if current[:2] != required[:2] or current < required or "-" in version:
        raise BootstrapError(
            f"Ghostty requires Zig {minimum_version} or a compatible patch release, but found {version}. "
            "Install a compatible Zig toolchain and rerun "
            "`python3 tools/bootstrap_libghostty.py`."
        )


def ensure_metal_toolchain(xcrun: str) -> None:
    try:
        read_tool_output([xcrun, "-sdk", "macosx", "--find", "metal"])
    except subprocess.CalledProcessError as error:
        raise BootstrapError(
            "The Metal toolchain is not installed for the active Xcode toolchain. "
            "Run `xcodebuild -downloadComponent MetalToolchain` and rerun "
            "`python3 tools/bootstrap_libghostty.py`."
        ) from error


def zig_executable_architecture(zig_path: str) -> str:
    output = read_tool_output([zig_path, "env"])
    match = re.search(r'^\s*\.target\s*=\s*"([^"]+)"', output, re.MULTILINE)
    if match is None:
        try:
            target = json.loads(output)["target"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise BootstrapError(
                "Could not determine the Zig executable architecture from `zig env`."
            ) from error
    else:
        target = match.group(1)
    return target.split("-", 1)[0].lower()


def required_macos_sdk_targets(
    xcframework_target: str,
    zig_architecture: str,
) -> frozenset[str]:
    normalized_zig_architecture = {
        "aarch64": "arm64-macos",
        "arm64": "arm64-macos",
        "x86_64": "x86_64-macos",
    }.get(zig_architecture.lower())
    if normalized_zig_architecture is None:
        raise BootstrapError(
            f"Unsupported Zig executable architecture: {zig_architecture}."
        )

    required = {normalized_zig_architecture}
    if xcframework_target == "aarch64":
        required.add("arm64-macos")
    elif xcframework_target == "universal":
        required.update(("arm64-macos", "x86_64-macos"))
    elif xcframework_target != "native":
        raise BootstrapError(
            f"Unsupported libghostty XCFramework target: {xcframework_target}."
        )
    return frozenset(required)


def macos_sdk_targets(sdk_path: Path) -> frozenset[str]:
    stub_path = sdk_path / "usr" / "lib" / "libSystem.B.tbd"
    try:
        contents = stub_path.read_text()
    except OSError as error:
        raise BootstrapError(
            f"macOS SDK is missing its libSystem target stub: {stub_path}"
        ) from error

    match = re.search(r"^targets:\s*\[([^\]]+)\]", contents, re.MULTILINE)
    if match is None:
        raise BootstrapError(
            f"Could not read target architectures from {stub_path}."
        )
    return frozenset(
        target.strip()
        for target in match.group(1).split(",")
        if target.strip()
    )


def macos_sdk_version(sdk_path: Path) -> tuple[int, ...]:
    match = re.fullmatch(r"MacOSX(\d+(?:\.\d+)*)\.sdk", sdk_path.name)
    if match is None:
        return ()
    return tuple(int(part) for part in match.group(1).split("."))


def find_compatible_macos_sdk(
    required_targets: frozenset[str],
    sdk_roots: list[Path],
) -> Path | None:
    compatible: list[Path] = []
    seen: set[Path] = set()
    for root in sdk_roots:
        if not root.is_dir():
            continue
        for candidate in root.glob("MacOSX*.sdk"):
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            try:
                targets = macos_sdk_targets(resolved)
            except BootstrapError:
                continue
            if required_targets.issubset(targets):
                compatible.append(resolved)

    if not compatible:
        return None
    return max(compatible, key=lambda path: (macos_sdk_version(path), str(path)))


def macos_sdk_roots(active_sdk: Path) -> list[Path]:
    roots = [
        active_sdk.parent,
        Path("/Library/Developer/CommandLineTools/SDKs"),
    ]
    applications = Path("/Applications")
    if applications.is_dir():
        roots.extend(
            xcode
            / "Contents"
            / "Developer"
            / "Platforms"
            / "MacOSX.platform"
            / "Developer"
            / "SDKs"
            for xcode in applications.glob("Xcode*.app")
        )
    return roots


def write_xcrun_sdk_shim(
    repo_root: Path,
    xcrun_path: str,
    sdk_path: Path,
) -> Path:
    shim_dir = repo_root / ".build" / "libghostty-tools"
    shim_dir.mkdir(parents=True, exist_ok=True)
    shim_path = shim_dir / "xcrun"
    shim_path.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        'if [[ "$*" == "--sdk macosx --show-sdk-path" || '
        '"$*" == "--show-sdk-path --sdk macosx" ]]; then\n'
        f"  printf '%s\\n' {shlex.quote(str(sdk_path))}\n"
        "  exit 0\n"
        "fi\n"
        f"exec {shlex.quote(xcrun_path)} \"$@\"\n"
    )
    shim_path.chmod(0o755)
    return shim_path


def prepare_zig_build_environment(
    repo_root: Path,
    xcrun_path: str,
    xcframework_target: str,
    zig_architecture: str,
) -> dict[str, str]:
    environment = os.environ.copy()
    if platform.system() != "Darwin":
        return environment

    required_targets = required_macos_sdk_targets(
        xcframework_target,
        zig_architecture,
    )

    try:
        active_sdk = Path(
            read_tool_output([xcrun_path, "--sdk", "macosx", "--show-sdk-path"])
        ).resolve()
        active_targets = macos_sdk_targets(active_sdk)
    except (BootstrapError, subprocess.CalledProcessError) as error:
        raise BootstrapError(
            "Could not inspect the active macOS SDK used by Zig. Verify the "
            "selected full Xcode installation with `xcode-select -p`."
        ) from error

    if required_targets.issubset(active_targets):
        return environment

    roots = macos_sdk_roots(active_sdk)
    fallback_sdk = find_compatible_macos_sdk(required_targets, roots)
    if fallback_sdk is None:
        searched = ", ".join(str(root) for root in roots)
        targets = ", ".join(sorted(active_targets)) or "none"
        required = ", ".join(sorted(required_targets))
        raise BootstrapError(
            f"The active macOS SDK {active_sdk} advertises [{targets}], but the "
            f"selected Zig and XCFramework targets require [{required}]. No compatible "
            f"SDK was found under: {searched}. Install or select Xcode 26.0.1, "
            "then rerun `make bootstrap-libghostty`."
        )

    shim_path = write_xcrun_sdk_shim(repo_root, xcrun_path, fallback_sdk)
    existing_path = environment.get("PATH", "")
    environment["PATH"] = str(shim_path.parent)
    if existing_path:
        environment["PATH"] += os.pathsep + existing_path
    print(
        f"Using macOS SDK {fallback_sdk} for the pinned Zig build runner; "
        f"the active SDK {active_sdk} does not advertise every required target: "
        f"{', '.join(sorted(required_targets))}."
    )
    return environment


def artifact_state_message(
    artifacts: ArtifactPaths,
    metadata: VendorMetadata,
    xcframework_target: str,
    optimize: str,
) -> str | None:
    required_paths = [
        artifacts.xcframework_path,
        artifacts.header_path,
        artifacts.modulemap_path,
        artifacts.manifest_path,
    ]
    missing = [path for path in required_paths if not path.exists()]
    if missing:
        return (
            "libghostty bootstrap artifacts are missing or stale. "
            "Run `python3 tools/bootstrap_libghostty.py` from the repo root."
        )

    manifest = json.loads(artifacts.manifest_path.read_text())
    if manifest.get("ghosttyCommit") != metadata.commit:
        return (
            "libghostty artifacts were built against a different Ghostty revision. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("ghosthubBootstrapVersion") != GHOSTHUB_BOOTSTRAP_VERSION:
        return (
            "libghostty artifacts were built against an older Ghosthub bootstrap schema. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("xcframeworkTarget") != xcframework_target:
        return (
            "libghostty artifacts were built for a different xcframework target. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("optimize") != optimize:
        return (
            "libghostty artifacts were built with a different optimize mode. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("requiredZigVersion") != metadata.required_zig_version:
        return (
            "libghostty artifacts were built with a different Zig version requirement. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("ghosttyBundleID") != GHOSTHUB_GHOSTTY_BUNDLE_ID:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("sentryEnabled") is not False:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("ghosttyConfigLoadExport") is not True:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("embeddedEnvIsolation") is not True:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("termProgram") != GHOSTHUB_TERM_PROGRAM:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("macosLoginQuiet") is not True:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("surfaceInjectOutputExport") is not True:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("childWriteCallback") is not True:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    if manifest.get("i18nEnabled") is not False:
        return (
            "libghostty artifacts were built with different Ghosthub isolation settings. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )
    # Checked as a tree rather than a manifest flag: artifacts built before
    # themes were emitted and artifacts whose resources were later pruned are
    # equally unusable, and only the tree itself distinguishes them.
    share_problem = share_tree_problem(artifacts.share_path)
    if share_problem is not None:
        return (
            f"libghostty resources are incomplete: {share_problem}. "
            "Re-run `python3 tools/bootstrap_libghostty.py`."
        )

    # Upstream normalizes and combines archives before applying its libSystem
    # symbol overrides. Check the emitted library without reassembling it.
    for fat_path in sorted(artifacts.xcframework_path.rglob(LIBRARY_ARCHIVE_NAME)):
        if not archive_defines_symbol(fat_path, GHOSTTY_SENTINEL_SYMBOL):
            return (
                f"libghostty artifacts at {fat_path} lack the ghostty API "
                "(the static library is incomplete). "
                "Re-run `python3 tools/bootstrap_libghostty.py`."
            )

    return None


LIBRARY_ARCHIVE_NAME = "libghostty-internal.a"
GHOSTTY_SENTINEL_SYMBOL = "_ghostty_app_new"


def archive_defines_symbol(archive: Path, symbol: str) -> bool:
    result = subprocess.run(
        ["nm", "-gU", str(archive)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    return any(
        line.split()[-1] == symbol
        for line in result.stdout.splitlines()
        if line
    )


def ensure_emitted_resources(paths: BootstrapPaths) -> None:
    """Fail the bootstrap when the build did not emit a usable share tree.

    The theme corpus is a lazy Zig dependency, so a build can otherwise
    succeed while silently omitting it, and every `theme = <name>` lookup
    then falls through to the user theme directory.
    """
    share_root = Path(paths.source_checkout_root, *EMITTED_SHARE_RELATIVE_PATH)
    problem = share_tree_problem(share_root)
    if problem is not None:
        raise BootstrapError(
            f"The Ghostty build emitted an unusable resources tree: {problem}. "
            "Verify network access to the pinned iTerm2-Color-Schemes "
            "dependency and rerun `python3 tools/bootstrap_libghostty.py`."
        )


def copy_outputs(paths: BootstrapPaths) -> None:
    source_xcframework = paths.source_checkout_root / "macos" / "GhosttyKit.xcframework"
    source_share = Path(paths.source_checkout_root, *EMITTED_SHARE_RELATIVE_PATH)
    source_header = paths.source_checkout_root / "include" / "ghostty.h"
    source_modulemap = paths.source_checkout_root / "include" / "module.modulemap"
    artifacts = paths.cached_artifacts

    if not source_xcframework.exists():
        raise BootstrapError(
            f"Expected Ghostty build output at {source_xcframework}, but it was not produced."
        )

    artifacts.root.mkdir(parents=True, exist_ok=True)
    include_root = artifacts.root / "include"
    include_root.mkdir(parents=True, exist_ok=True)

    if artifacts.xcframework_path.exists():
        shutil.rmtree(artifacts.xcframework_path)
    shutil.copytree(source_xcframework, artifacts.xcframework_path)
    # Cache the resources alongside the library so a pruned or re-cleaned
    # source checkout cannot leave a "ready" variant without themes.
    if artifacts.share_path.exists():
        shutil.rmtree(artifacts.share_path)
    shutil.copytree(source_share, artifacts.share_path, symlinks=True)
    shutil.copy2(source_header, artifacts.header_path)
    shutil.copy2(source_modulemap, artifacts.modulemap_path)


def sync_cached_artifacts_to_staged(paths: BootstrapPaths) -> None:
    staged = paths.staged_artifacts
    cached = paths.cached_artifacts

    if staged.root.exists():
        shutil.rmtree(staged.root)
    staged.root.mkdir(parents=True, exist_ok=True)
    (staged.root / "include").mkdir(parents=True, exist_ok=True)

    shutil.copytree(cached.xcframework_path, staged.xcframework_path)
    shutil.copytree(cached.share_path, staged.share_path, symlinks=True)
    shutil.copy2(cached.header_path, staged.header_path)
    shutil.copy2(cached.modulemap_path, staged.modulemap_path)
    shutil.copy2(cached.manifest_path, staged.manifest_path)

    source_link = staged.root / "source"
    if paths.source_checkout_root.exists():
        source_link.symlink_to(paths.source_checkout_root)


def write_manifest(
    paths: BootstrapPaths,
    metadata: VendorMetadata,
    zig_version: str,
    xcframework_target: str,
    optimize: str,
) -> None:
    manifest = {
        "ghosttySource": metadata.source,
        "ghosttyTag": metadata.tag,
        "ghosttyCommit": metadata.commit,
        "ghosthubBootstrapVersion": GHOSTHUB_BOOTSTRAP_VERSION,
        "ghosttyBundleID": GHOSTHUB_GHOSTTY_BUNDLE_ID,
        "ghosttyConfigLoadExport": True,
        "surfaceInjectOutputExport": True,
        "childWriteCallback": True,
        "embeddedEnvIsolation": True,
        "macosLoginQuiet": True,
        "termProgram": GHOSTHUB_TERM_PROGRAM,
        "requiredZigVersion": metadata.required_zig_version,
        "i18nEnabled": False,
        "sentryEnabled": False,
        "zigVersion": zig_version,
        "xcframeworkTarget": xcframework_target,
        "optimize": optimize,
        "builtAt": datetime.now(timezone.utc).isoformat(),
    }
    paths.cached_artifacts.manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )


def refresh_swiftpm_manifest(paths: BootstrapPaths) -> None:
    if not paths.package_manifest_path.exists():
        return
    paths.package_manifest_path.touch()


def bootstrap(
    paths: BootstrapPaths,
    metadata: VendorMetadata,
    git: str,
    zig: str,
    xcodebuild: str,
    xcrun: str,
    xcframework_target: str,
    optimize: str,
) -> BootstrapResult:
    rebuilt_variant = False
    if artifact_state_message(paths.cached_artifacts, metadata, xcframework_target, optimize) is not None:
        ensure_source_checkout(paths, metadata, git=git)
        apply_ghosthub_source_patches(paths)

        zig_path = resolve_tool(zig)
        _ = resolve_tool(xcodebuild)
        xcrun_path = resolve_tool(xcrun)
        zig_version = read_tool_output([zig_path, "version"])
        ensure_supported_zig_version(zig_version, metadata.required_zig_version)
        ensure_metal_toolchain(xcrun_path)
        zig_architecture = zig_executable_architecture(zig_path)
        build_environment = prepare_zig_build_environment(
            paths.repo_root,
            xcrun_path,
            xcframework_target,
            zig_architecture,
        )

        command = render_build_command(zig_path, xcframework_target, optimize)
        try:
            subprocess.run(
                command,
                cwd=str(paths.source_checkout_root),
                check=True,
                env=build_environment,
            )
        except subprocess.CalledProcessError as error:
            raise BootstrapError(
                "Ghostty build failed. Common macOS setup requirements are a compatible Zig "
                "toolchain, a full Xcode installation selected via `xcode-select`, and the "
                "Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)."
            ) from error
        ensure_emitted_resources(paths)
        copy_outputs(paths)
        write_manifest(paths, metadata, zig_version, xcframework_target, optimize)
        rebuilt_variant = True

    staged_synced = rebuilt_variant
    if not staged_synced and (
        artifact_state_message(paths.staged_artifacts, metadata, xcframework_target, optimize) is not None
    ):
        staged_synced = True

    if staged_synced:
        sync_cached_artifacts_to_staged(paths)

    return BootstrapResult(rebuilt_variant=rebuilt_variant, staged_synced=staged_synced)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build and stage repo-local libghostty artifacts.")
    parser.add_argument(
        "--repo-root",
        default=Path(__file__).resolve().parents[1],
        type=Path,
        help="Path to the Ghosthub repository root.",
    )
    parser.add_argument(
        "--git",
        default="git",
        help="Path to the git executable used to fetch the pinned Ghostty source revision.",
    )
    parser.add_argument(
        "--zig",
        default="zig",
        help="Path to the Zig executable to use for the Ghostty build.",
    )
    parser.add_argument(
        "--xcodebuild",
        default="xcodebuild",
        help="Path to the xcodebuild executable to verify before bootstrapping.",
    )
    parser.add_argument(
        "--xcrun",
        default="xcrun",
        help="Path to the xcrun executable used to locate the Metal toolchain.",
    )
    parser.add_argument(
        "--xcframework-target",
        choices=("native", "universal", "aarch64"),
        default="aarch64",
        help="Ghostty xcframework target to build.",
    )
    parser.add_argument(
        "--optimize",
        choices=("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"),
        default="Debug",
        help="Zig optimize mode to use for the Ghostty build.",
    )
    parser.add_argument(
        "--print-command",
        action="store_true",
        help="Print the Ghostty build command and exit.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate that repo-local libghostty artifacts exist and match the pinned Ghostty revision.",
    )
    parser.add_argument(
        "--quiet-noop",
        action="store_true",
        help="Suppress success output when the staged artifacts already match the requested state.",
    )
    args = parser.parse_args(argv)

    paths = BootstrapPaths.from_repo_root(
        args.repo_root,
        xcframework_target=args.xcframework_target,
        optimize=args.optimize,
    )
    metadata = VendorMetadata.load(paths.vendor_metadata_path)

    if args.print_command:
        zig_path = resolve_tool(args.zig)
        print(
            shlex.join(
                render_build_command(
                    zig_path,
                    args.xcframework_target,
                    args.optimize,
                )
            )
        )
        return 0

    if args.check:
        message = artifact_state_message(
            paths.staged_artifacts,
            metadata,
            args.xcframework_target,
            args.optimize,
        )
        if message is not None:
            raise BootstrapError(message)
        if not args.quiet_noop:
            print(f"libghostty artifacts are ready at {paths.staged_artifacts.root}")
        return 0

    result = bootstrap(
        paths=paths,
        metadata=metadata,
        git=args.git,
        zig=args.zig,
        xcodebuild=args.xcodebuild,
        xcrun=args.xcrun,
        xcframework_target=args.xcframework_target,
        optimize=args.optimize,
    )
    if result.staged_synced:
        refresh_swiftpm_manifest(paths)
    if result.rebuilt_variant:
        print(f"Bootstrapped libghostty artifacts at {paths.staged_artifacts.root}")
    elif result.staged_synced:
        print(f"Activated cached libghostty artifacts at {paths.staged_artifacts.root}")
    elif not args.quiet_noop:
        print(f"libghostty artifacts are already ready at {paths.staged_artifacts.root}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as error:
        print(error)
        raise SystemExit(1) from error
