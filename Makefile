SHELL = /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
UV ?= uv
SWIFT ?= swift
GHOSTHUB_APP ?= Ghosthub
HOST_KEY ?= local
LIBGHOSTTY_ZIG ?=
LIBGHOSTTY_GIT ?=
LIBGHOSTTY_XCRUN ?=
LIBGHOSTTY_XCFRAMEWORK_TARGET ?= aarch64
LIBGHOSTTY_OPTIMIZE ?= Debug
DIST_ROOT ?= dist
DEBUG_ROOT ?= $(DIST_ROOT)/debug
RELEASE_ROOT ?= $(DIST_ROOT)/release
DEBUG_APP_PATH ?= $(DEBUG_ROOT)/$(GHOSTHUB_APP).app
RELEASE_APP_PATH ?= $(RELEASE_ROOT)/$(GHOSTHUB_APP).app
RELEASE_BUNDLE_ID ?= com.ghosthub
DEBUG_BUNDLE_ID ?= $(RELEASE_BUNDLE_ID).debug
RELEASE_APP_VERSION ?= 0.1.0
RELEASE_BUILD_VERSION ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
RELEASE_MIN_MACOS ?= 26.0
APP_ICON_PATH ?= Resources/AppIcon/Ghosthub.icns
APP_COPYRIGHT ?= Copyright © 2026 Kenn Software LLC. Licensed under the GNU AGPL v3.0 or later.
APP_LICENSE_PATH ?= LICENSE
KWT_BINARY_PATH ?= $(shell command -v kwt 2>/dev/null)
THIRD_PARTY_LICENSES_DIR ?= LICENSES
KWT_VERSION ?= development
KWT_SOURCE_REVISION ?= unpinned
SWIFT_TEST_FILTER ?=

.PHONY: help bootstrap-libghostty bootstrap-libghostty-release check-libghostty check-libghostty-release test-libghostty-bootstrap test-terminal-fallback test-stage-release-app-bundles test-assemble-app-bundle test-essential-workflows build swift-warning-check build-release debug-app release-app release-dmg release-appcast run-release-app run-app swift-test test-tmux-attach python-test test smoke-test docs-build docs-serve reset-app-state install-hooks

help:
	@printf '%s\n' \
		'Ghosthub developer shortcuts' \
		'' \
		'Targets:' \
		'  make bootstrap-libghostty' \
		'      Fetch the pinned Ghostty source, build libghostty, and stage the local artifacts.' \
		'  make check-libghostty' \
		'      Verify that the staged libghostty artifacts match the pinned Ghostty revision.' \
		'  make test-libghostty-bootstrap' \
		'      Run the bootstrap Python tests via uv-managed pytest.' \
		'  make test-terminal-fallback' \
		'      Compile the app with the libghostty-unavailable fallback target.' \
		'  make test-stage-release-app-bundles' \
		'      Run the Ghosthub.app SwiftPM resource-bundle staging tests.' \
		'  make test-assemble-app-bundle' \
		'      Run the shared Ghosthub.app bundle assembly Python tests via uv-managed pytest.' \
		'  make build' \
		'      Build the Swift package.' \
		'  make build-release' \
		'      Build the release Ghosthub binary with release-optimized libghostty.' \
		'  make debug-app' \
		'      Package a debug Ghosthub.app bundle under $(DEBUG_ROOT).' \
		'  make release-app' \
		'      Package a release Ghosthub.app bundle under $(RELEASE_ROOT).' \
		'  make release-dmg' \
		'      Build a release DMG. If Apple signing/notary env vars are set, it signs and notarizes it.' \
		'  make run-release-app' \
		'      Build and open the packaged release Ghosthub.app bundle.' \
		'  make run-app' \
		'      Build and open the debug Ghosthub.app bundle.' \
		'  make swift-test' \
		'      Run SwiftPM tests. Set SWIFT_TEST_FILTER=... for a narrower slice.' \
		'  make test-tmux-attach' \
		'      Run the native tmux attachment tests.' \
		'  make python-test' \
		'      Run the full Python test suite via uv-managed pytest.' \
		'  make test' \
		'      Run both the Swift and Python test suites.' \
		'  make smoke-test' \
		'      Run terminal runtime smoke tests (requires bootstrapped libghostty).' \
		'  make docs-build' \
		'      Build the Zensical documentation site under docs/site.' \
		'  make docs-serve' \
		'      Serve the Zensical documentation site locally.' \
		'  make reset-app-state' \
		'      Delete all Ghosthub preferences, database, config, and window state to simulate a first-run experience.' \
		'' \
		'Useful overrides:' \
		'  LIBGHOSTTY_ZIG=/opt/homebrew/bin/zig' \
		'  UV=uv' \
		'  LIBGHOSTTY_GIT=/opt/homebrew/bin/git' \
		'  LIBGHOSTTY_XCRUN=/usr/bin/xcrun' \
		'  LIBGHOSTTY_XCFRAMEWORK_TARGET=aarch64' \
		'  LIBGHOSTTY_OPTIMIZE=ReleaseFast' \
		'  RELEASE_ROOT=dist/release' \
		'  RELEASE_APP_VERSION=0.1.0' \
		'  RELEASE_BUILD_VERSION=0.1.0' \
		'  KWT_BINARY_PATH=/absolute/path/to/kwt' \
		'  SWIFT_TEST_FILTER=WorkspaceDatabaseTests' \
		'  HOST_KEY=local' \
		'' \
		'Notes:' \
		'  bootstrap-libghostty is idempotent: if the staged artifacts already match the pinned Ghostty revision, it exits without rebuilding.' \
		'  Debug and release libghostty variants are cached separately; switching LIBGHOSTTY_OPTIMIZE modes re-activates the requested variant into .build/libghostty and only rebuilds when that cached variant is missing or stale.' \
		'  bootstrap-libghostty and check-libghostty prefer LIBGHOSTTY_ZIG first, then ~/.local/bin/zig-0.15.2-x86_64, then zig from PATH, and finally /opt/homebrew/bin/zig as a fallback.' \
		'  Ghostty bootstrap requires a full Xcode install and the Metal Toolchain, not just Command Line Tools.'

bootstrap-libghostty:
	@set -euo pipefail; \
	cmd=($(UV) run --frozen $(PYTHON) tools/bootstrap_libghostty.py); \
	zig_path="$(LIBGHOSTTY_ZIG)"; \
	if [[ -z "$$zig_path" && -x "$$HOME/.local/bin/zig-0.15.2-x86_64" ]]; then \
		zig_path="$$HOME/.local/bin/zig-0.15.2-x86_64"; \
	fi; \
	if [[ -z "$$zig_path" ]]; then \
		zig_path="$$(command -v zig || true)"; \
	fi; \
	if [[ -z "$$zig_path" && -x /opt/homebrew/bin/zig ]]; then \
		zig_path=/opt/homebrew/bin/zig; \
	fi; \
	if [[ -n "$$zig_path" ]]; then \
		cmd+=(--zig "$$zig_path"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_GIT)" ]]; then \
		cmd+=(--git "$(LIBGHOSTTY_GIT)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_XCRUN)" ]]; then \
		cmd+=(--xcrun "$(LIBGHOSTTY_XCRUN)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_OPTIMIZE)" ]]; then \
		cmd+=(--optimize "$(LIBGHOSTTY_OPTIMIZE)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_XCFRAMEWORK_TARGET)" ]]; then \
		cmd+=(--xcframework-target "$(LIBGHOSTTY_XCFRAMEWORK_TARGET)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_QUIET_NOOP)" ]]; then \
		cmd+=(--quiet-noop); \
	else \
		printf 'Running:'; \
		printf ' %q' "$${cmd[@]}"; \
		printf '\n'; \
	fi; \
	"$${cmd[@]}"

check-libghostty:
	@set -euo pipefail; \
	cmd=($(UV) run --frozen $(PYTHON) tools/bootstrap_libghostty.py --check); \
	zig_path="$(LIBGHOSTTY_ZIG)"; \
	if [[ -z "$$zig_path" && -x "$$HOME/.local/bin/zig-0.15.2-x86_64" ]]; then \
		zig_path="$$HOME/.local/bin/zig-0.15.2-x86_64"; \
	fi; \
	if [[ -z "$$zig_path" ]]; then \
		zig_path="$$(command -v zig || true)"; \
	fi; \
	if [[ -z "$$zig_path" && -x /opt/homebrew/bin/zig ]]; then \
		zig_path=/opt/homebrew/bin/zig; \
	fi; \
	if [[ -n "$$zig_path" ]]; then \
		cmd+=(--zig "$$zig_path"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_GIT)" ]]; then \
		cmd+=(--git "$(LIBGHOSTTY_GIT)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_XCRUN)" ]]; then \
		cmd+=(--xcrun "$(LIBGHOSTTY_XCRUN)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_OPTIMIZE)" ]]; then \
		cmd+=(--optimize "$(LIBGHOSTTY_OPTIMIZE)"); \
	fi; \
	if [[ -n "$(LIBGHOSTTY_XCFRAMEWORK_TARGET)" ]]; then \
		cmd+=(--xcframework-target "$(LIBGHOSTTY_XCFRAMEWORK_TARGET)"); \
	fi; \
	printf 'Running:'; \
	printf ' %q' "$${cmd[@]}"; \
	printf '\n'; \
	"$${cmd[@]}"

test-libghostty-bootstrap:
	@$(UV) run --frozen --group dev pytest Tests/test_libghostty_bootstrap.py

test-terminal-fallback:
	@GHOSTHUB_FORCE_TERMINAL_UNAVAILABLE=1 $(SWIFT) build --scratch-path .build/terminal-unavailable

test-stage-release-app-bundles:
	@$(UV) run --frozen --group dev pytest Tests/test_stage_release_app_bundles.py

test-assemble-app-bundle:
	@$(UV) run --frozen --group dev pytest Tests/test_assemble_app_bundle.py

# Essential workflow smoke for kwt inventory and ordinary tmux attachment.
test-essential-workflows:
	@set -euo pipefail; \
	for filter in \
		KwtInventoryClientTests \
		TmuxHostResolverTests \
		TmuxAttachmentInfoTests \
		WorkspaceSidebarModelTests \
	; do \
		sh tools/run_with_timeout.sh 600 $(SWIFT) test --filter $$filter; \
	done

build: bootstrap-libghostty
	@$(SWIFT) build

swift-warning-check: bootstrap-libghostty
	@$(SWIFT) build --build-tests -Xswiftc -warnings-as-errors

bootstrap-libghostty-release: LIBGHOSTTY_OPTIMIZE = ReleaseFast
bootstrap-libghostty-release: bootstrap-libghostty

check-libghostty-release: LIBGHOSTTY_OPTIMIZE = ReleaseFast
check-libghostty-release: check-libghostty

build-release: LIBGHOSTTY_OPTIMIZE = ReleaseFast
build-release: bootstrap-libghostty-release
	@$(SWIFT) build --configuration release --product "$(GHOSTHUB_APP)"

debug-app: LIBGHOSTTY_QUIET_NOOP = 1
debug-app: bootstrap-libghostty
	@set -euo pipefail; \
	kwt_bin="$(KWT_BINARY_PATH)"; \
	if [[ -z "$$kwt_bin" || ! -x "$$kwt_bin" ]]; then \
		printf 'KWT_BINARY_PATH must name an executable kwt binary.\n' >&2; \
		exit 1; \
	fi; \
	bin_dir="$$($(SWIFT) build --show-bin-path)"; \
	$(SWIFT) build --product "$(GHOSTHUB_APP)" >/dev/null; \
	app_bin="$$bin_dir/$(GHOSTHUB_APP)"; \
	$(UV) run --frozen $(PYTHON) tools/assemble_app_bundle.py \
		--source-bin-dir "$$bin_dir" \
		--app-binary "$$app_bin" \
		--app-root "$(DEBUG_APP_PATH)" \
		--bundle-id "$(DEBUG_BUNDLE_ID)" \
		--display-name "$(GHOSTHUB_APP)" \
		--version "$(RELEASE_APP_VERSION)" \
		--build-version "$(RELEASE_BUILD_VERSION)" \
		--min-macos "$(RELEASE_MIN_MACOS)" \
		--icon-path "$(APP_ICON_PATH)" \
		--app-license-path "$(APP_LICENSE_PATH)" \
		--kwt-binary "$$kwt_bin" \
		--third-party-licenses-dir "$(THIRD_PARTY_LICENSES_DIR)" \
		--copyright "$(APP_COPYRIGHT)" \
		--kwt-version "$(KWT_VERSION)" \
		--kwt-source-revision "$(KWT_SOURCE_REVISION)" >/dev/null; \
	codesign --force --deep --sign - "$(DEBUG_APP_PATH)" >/dev/null; \
	codesign --verify --deep --strict "$(DEBUG_APP_PATH)"; \
	printf 'Built debug app bundle: %s\n' "$(DEBUG_APP_PATH)"

release-app: LIBGHOSTTY_OPTIMIZE = ReleaseFast
release-app: build-release
	@set -euo pipefail; \
	kwt_bin="$(KWT_BINARY_PATH)"; \
	if [[ -z "$$kwt_bin" || ! -x "$$kwt_bin" ]]; then \
		printf 'KWT_BINARY_PATH must name an executable kwt binary.\n' >&2; \
		exit 1; \
	fi; \
	bin_dir="$$($(SWIFT) build --configuration release --show-bin-path)"; \
	app_bin="$$bin_dir/$(GHOSTHUB_APP)"; \
	app_root="$(RELEASE_APP_PATH)"; \
	$(UV) run --frozen $(PYTHON) tools/assemble_app_bundle.py \
		--source-bin-dir "$$bin_dir" \
		--app-root "$$app_root" \
		--app-binary "$$app_bin" \
		--bundle-id "$(RELEASE_BUNDLE_ID)" \
		--display-name "$(GHOSTHUB_APP)" \
		--version "$(RELEASE_APP_VERSION)" \
		--build-version "$(RELEASE_BUILD_VERSION)" \
		--min-macos "$(RELEASE_MIN_MACOS)" \
		--icon-path "$(APP_ICON_PATH)" \
		--app-license-path "$(APP_LICENSE_PATH)" \
		--kwt-binary "$$kwt_bin" \
		--third-party-licenses-dir "$(THIRD_PARTY_LICENSES_DIR)" \
		--copyright "$(APP_COPYRIGHT)" \
		--kwt-version "$(KWT_VERSION)" \
		--kwt-source-revision "$(KWT_SOURCE_REVISION)" \
		--include-updates >/dev/null; \
	printf 'Built release app bundle: %s\n' "$(RELEASE_APP_PATH)"

run-release-app: release-app
	@open "$(RELEASE_APP_PATH)"

release-dmg: LIBGHOSTTY_OPTIMIZE = ReleaseFast
release-dmg:
	@./tools/build_release_dmg.sh

release-appcast:
	@./tools/generate_update_appcast.sh

run-app: debug-app
	@set -euo pipefail; \
	app_bin="$(DEBUG_APP_PATH)/Contents/MacOS/$(GHOSTHUB_APP)"; \
	existing_pids="$$(pgrep -f "$$app_bin" || true)"; \
	if [[ -n "$$existing_pids" ]]; then \
		printf 'Stopping %s from this workspace: %s\n' "$(GHOSTHUB_APP)" "$$existing_pids"; \
		pkill -f "$$app_bin" || true; \
		sleep 1; \
	fi; \
	printf 'Opening app bundle: %s\n' "$(DEBUG_APP_PATH)"; \
	open -n "$(DEBUG_APP_PATH)"

swift-test:
	@set -euo pipefail; \
	cmd=($(SWIFT) test); \
	if [[ -n "$(SWIFT_TEST_FILTER)" ]]; then \
		cmd+=(--filter "$(SWIFT_TEST_FILTER)"); \
	fi; \
	printf 'Running:'; \
	printf ' %q' "$${cmd[@]}"; \
	printf '\n'; \
	"$${cmd[@]}"

test-tmux-attach: bootstrap-libghostty
	@set -euo pipefail; \
	sh tools/run_with_timeout.sh 600 $(SWIFT) test --filter GhosthubTmuxTests; \
	sh tools/run_with_timeout.sh 600 $(SWIFT) test --filter TmuxInjectionSmokeTests

python-test:
	@$(UV) run --frozen --group dev pytest Tests

test: swift-test python-test

smoke-test: bootstrap-libghostty
	@$(SWIFT) test --filter GhosttyRuntimeSmokeTests

docs-build:
	@cd docs && $(UV) run --frozen ./zensical-docs.sh build

docs-serve:
	@cd docs && $(UV) run --frozen ./zensical-docs.sh serve

reset-app-state:
	@set -euo pipefail; \
	if pgrep -x "$(GHOSTHUB_APP)" >/dev/null 2>&1; then \
		printf 'Error: %s is still running. Quit the app first.\n' "$(GHOSTHUB_APP)" >&2; \
		exit 1; \
	fi; \
	printf 'Resetting Ghosthub to first-run state...\n'; \
	for domain in "$(RELEASE_BUNDLE_ID)" "$(DEBUG_BUNDLE_ID)" \
	              "$(GHOSTHUB_APP)" "$(GHOSTHUB_APP)App"; do \
		defaults delete "$$domain" 2>/dev/null || true; \
	done; \
	find "$$HOME/Library/Preferences" -name 'ghosthub.settings.tests.*.plist' -delete 2>/dev/null || true; \
	find "$$HOME/Library/Preferences" -name 'ghosthub.settings.view.*.plist' -delete 2>/dev/null || true; \
	find "$$HOME/Library/Preferences" -name 'ghosthub.workspace.terminal.settings.*.plist' -delete 2>/dev/null || true; \
	rm -rf "$$HOME/.ghosthub"; \
	rm -rf "$$HOME/.config/ghosthub"; \
	rm -rf "$$HOME/Library/Caches/$(RELEASE_BUNDLE_ID)"; \
	rm -rf "$$HOME/Library/Caches/$(DEBUG_BUNDLE_ID)"; \
	rm -rf "$$HOME/Library/Caches/$(GHOSTHUB_APP)"; \
	rm -rf "$$HOME/Library/Saved Application State/$(RELEASE_BUNDLE_ID).savedState"; \
	rm -rf "$$HOME/Library/Saved Application State/$(DEBUG_BUNDLE_ID).savedState"; \
	rm -rf "$$HOME/Library/Saved Application State/$(GHOSTHUB_APP).savedState"; \
	printf 'Done. Deleted:\n'; \
	printf '  - UserDefaults for %s, %s, %s, %sApp\n' \
		"$(RELEASE_BUNDLE_ID)" "$(DEBUG_BUNDLE_ID)" "$(GHOSTHUB_APP)" "$(GHOSTHUB_APP)"; \
	printf '  - Leaked test preference plists\n'; \
	printf '  - ~/.ghosthub (database, logs, state)\n'; \
	printf '  - ~/.config/ghosthub (configuration)\n'; \
	printf '  - ~/Library/Caches (Ghosthub caches)\n'; \
	printf '  - Saved Application State (window positions/sizes)\n'

install-hooks:
	@if ! command -v prek >/dev/null 2>&1; then \
		echo "prek not found. Install with: brew install prek" >&2; \
		exit 1; \
	fi
	prek install -f
