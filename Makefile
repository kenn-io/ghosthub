SHELL = /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
UV ?= uv
SWIFT ?= swift
PNPM ?= pnpm
VERCEL ?= vercel
GHOSTHUB_APP ?= Ghosthub
HOST_KEY ?= local
LIBGHOSTTY_ZIG ?=
LIBGHOSTTY_GIT ?=
LIBGHOSTTY_XCRUN ?=
LIBGHOSTTY_XCFRAMEWORK_TARGET ?= aarch64
LIBGHOSTTY_OPTIMIZE ?= Debug
# Themes, shell integration, and terminfo staged by the libghostty bootstrap.
# Bundles copy this tree into Contents/Resources.
LIBGHOSTTY_SHARE_DIR ?= $(abspath .build/libghostty/share)
DIST_ROOT ?= dist
DEBUG_ROOT ?= $(DIST_ROOT)/debug
RELEASE_ROOT ?= $(DIST_ROOT)/release
NIGHTLY_RELEASE_ROOT ?= $(DIST_ROOT)/nightly
DEBUG_APP_PATH ?= $(DEBUG_ROOT)/$(GHOSTHUB_APP).app
RELEASE_APP_PATH ?= $(RELEASE_ROOT)/$(GHOSTHUB_APP).app
RELEASE_BUNDLE_ID ?= com.ghosthub
RELEASE_CHANNEL ?= stable
NIGHTLY_SPARKLE_FEED_URL ?=
NIGHTLY_SPARKLE_PUBLIC_ED_KEY ?=
NIGHTLY_SOURCE_REVISION ?=
NIGHTLY_BUILD_DATE ?=
DEBUG_BUNDLE_ID ?= $(RELEASE_BUNDLE_ID).debug
RELEASE_VERSION_FILE ?= RELEASE_VERSION
RELEASE_APP_VERSION ?= $(shell tr -d '[:space:]' < "$(RELEASE_VERSION_FILE)")
ifeq ($(origin DEVELOPMENT_APP_VERSION),undefined)
DEVELOPMENT_APP_VERSION := $(shell $(PYTHON) tools/development_version.py --component short)
endif
ifeq ($(origin DEVELOPMENT_VERSION_DESCRIPTION),undefined)
DEVELOPMENT_VERSION_DESCRIPTION := $(shell $(PYTHON) tools/development_version.py --component display)
endif
RELEASE_BUILD_VERSION ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
RELEASE_MIN_MACOS ?= 15.0
APP_ICON_PATH ?= Resources/AppIcon/Ghosthub.icns
APP_COPYRIGHT ?= Copyright © 2026 Kenn Software LLC. Licensed under the GNU AGPL v3.0 or later.
APP_LICENSE_PATH ?= LICENSE
KWT_REPOSITORY ?= https://github.com/kenn-io/kwt.git
KWT_REF ?= $(shell tr -d '[:space:]' < KWT_REVISION)
KWT_SOURCE_DIR ?= $(abspath .build/kwt-source)
KWT_BINARY_PATH ?= $(abspath .build/kwt/kwt)
KWT_VARIANTS_DIR ?= $(abspath .build/kwt/variants)
THIRD_PARTY_LICENSES_DIR ?= LICENSES

# Only the helper this Makefile builds is the pinned one. A developer-supplied
# KWT_BINARY_PATH must not inherit the pin's provenance in the bundle, so ask
# that binary to identify itself instead. An explicit KWT_VERSION or
# KWT_SOURCE_REVISION still wins either way, which is how release CI records
# the helper it built.
KWT_REPORTED_VERSION = $(shell "$(KWT_BINARY_PATH)" --version 2>/dev/null \
	| sed -n '1s/^kwt version //p')
ifeq ($(origin KWT_BINARY_PATH),file)
KWT_VERSION ?= $(KWT_REF)
KWT_SOURCE_REVISION ?= $(KWT_REF)
else
KWT_VERSION ?= $(or $(KWT_REPORTED_VERSION),unknown)
KWT_SOURCE_REVISION ?= unpinned
endif
SWIFT_TEST_FILTER ?=

.PHONY: help ensure-go ensure-tmux bootstrap-kwt bootstrap-kwt-variants ensure-kwt ensure-kwt-variants bootstrap-libghostty bootstrap-libghostty-release check-libghostty check-libghostty-release test-libghostty-bootstrap test-terminal-fallback test-stage-release-app-bundles test-assemble-app-bundle test-kwt-contract test-essential-workflows test-ssh-authentication-live build swift-warning-check build-release debug-app release-app release-dmg release-appcast nightly-app nightly-dmg nightly-appcast run-release-app run-app swift-test test-tmux-attach purge-test-tmux python-test sandbox-image-check sandbox-image-prepare-candidate sandbox-image-refresh sandbox-image-vet sandbox-image-pin sandbox-image-promote sandbox-image-clean sandbox-image-status sandbox-image-authority-configure sandbox-image-authority-enable sandbox-image-authority-audit sandbox-image-python-lint sandbox-image-python-typecheck zizmor test smoke-test docs-build docs-serve site-docs-serve site-deploy reset-app-state install-hooks format format-check

help:
	@printf '%s\n' \
		'Ghosthub developer shortcuts' \
		'' \
		'Targets:' \
		'  make bootstrap-kwt' \
		'      Build the exact kwt revision embedded by local debug app bundles.' \
		'  make bootstrap-kwt-variants' \
		'      Cross-compile the pinned remote kwt helper matrix.' \
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
		'  make test-kwt-contract' \
		'      Exercise the exact pinned kwt helper through its daemon-backed project lifecycle.' \
		'  make test-essential-workflows' \
		'      Run the pinned kwt contract and focused host, inventory, sidebar, and tmux workflows.' \
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
		'  make nightly-app' \
		'      Package the release-optimized app with the nightly display name, feed, and key.' \
		'  make nightly-dmg' \
		'      Build a nightly DMG through the release signing and notarization path.' \
		'  make nightly-appcast' \
		'      Generate the nightly appcast for the current workflow run and attempt.' \
		'  make run-release-app' \
		'      Build and open the packaged release Ghosthub.app bundle.' \
		'  make run-app' \
		'      Build and open the debug Ghosthub.app bundle.' \
		'  make swift-test' \
		'      Run SwiftPM tests. Set SWIFT_TEST_FILTER=... for a narrower slice.' \
		'  make test-ssh-authentication-live GHOSTHUB_SSH_INTEGRATION_DESTINATION=user@host' \
		'      Establish an opt-in live master through Ghosthub SSH authentication.' \
		'  make test-tmux-attach' \
		'      Run the native tmux attachment tests.' \
		'  make purge-test-tmux' \
		'      Stop leaked test tmux processes and remove their sockets.' \
		'  make python-test' \
		'      Run the full Python test suite via uv-managed pytest.' \
		'  make test' \
		'      Run both the Swift and Python test suites.' \
		'  make format' \
		'      Apply the repository SwiftFormat rules in place.' \
		'  make format-check' \
		'      Report Swift files that do not match the repository SwiftFormat rules.' \
		'  make smoke-test' \
		'      Run terminal runtime smoke tests (requires bootstrapped libghostty).' \
		'  make docs-build' \
		'      Build the Zensical documentation site under docs/site.' \
		'  make docs-serve' \
		'      Serve the internal Zensical engineering documentation locally.' \
		'  make site-docs-serve' \
		'      Serve the public Zensical user documentation locally.' \
		'  make site-deploy' \
		'      Build the marketing site and deploy it to production with Vercel.' \
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
		'  DEVELOPMENT_APP_VERSION=X.Y.Z' \
		'  DEVELOPMENT_VERSION_DESCRIPTION=X.Y.Z-N-gHASH' \
		'  RELEASE_VERSION_FILE=/path/to/release-version' \
		'  RELEASE_APP_VERSION=X.Y.Z' \
		'  RELEASE_BUILD_VERSION=123' \
		'  KWT_BINARY_PATH=/absolute/path/to/kwt' \
		'  SWIFT_TEST_FILTER=WorkspaceDatabaseTests' \
		'  HOST_KEY=local' \
		'' \
		'Notes:' \
		'  bootstrap-libghostty is idempotent: if the staged artifacts already match the pinned Ghostty revision, it exits without rebuilding.' \
		'  Debug and release libghostty variants are cached separately; switching LIBGHOSTTY_OPTIMIZE modes re-activates the requested variant into .build/libghostty and only rebuilds when that cached variant is missing or stale.' \
		'  bootstrap-libghostty and check-libghostty prefer LIBGHOSTTY_ZIG first, then ~/.local/bin/zig-0.15.2-x86_64, then zig from PATH, and finally /opt/homebrew/bin/zig as a fallback.' \
		'  libghostty bootstrap requires a full Xcode install and the Metal Toolchain, not just Command Line Tools.'

ensure-go:
	@if ! command -v go >/dev/null; then \
		if [[ "$${GITHUB_ACTIONS:-}" == "true" \
			&& "$$(uname -s)" == "Darwin" \
			&& -x /opt/homebrew/bin/brew ]]; then \
			/opt/homebrew/bin/brew install go; \
		else \
			printf 'Go is required to build the pinned kwt helper.\n' >&2; \
			exit 1; \
		fi; \
	fi

bootstrap-kwt: ensure-go
	@tools/build_pinned_kwt.sh \
		"$(KWT_REPOSITORY)" \
		"$(KWT_REF)" \
		"$(KWT_SOURCE_DIR)" \
		"$(KWT_BINARY_PATH)"

bootstrap-kwt-variants:
	@tools/build_pinned_kwt_variants.sh \
		"$(KWT_REPOSITORY)" \
		"$(KWT_REF)" \
		"$(KWT_SOURCE_DIR)" \
		"$(KWT_VARIANTS_DIR)" \
		"$(abspath tools/build_pinned_kwt.sh)"
	@$(UV) run --frozen $(PYTHON) tools/validate_kwt_variants.py \
		--variants-dir "$(KWT_VARIANTS_DIR)" \
		--revision "$(KWT_REF)"

ensure-kwt:
	@if [[ "$(origin KWT_BINARY_PATH)" == "file" ]]; then \
		$(MAKE) --no-print-directory bootstrap-kwt; \
	elif [[ ! -x "$(KWT_BINARY_PATH)" ]]; then \
		printf 'KWT_BINARY_PATH must name an existing executable kwt binary.\n' >&2; \
		exit 1; \
	fi

ensure-kwt-variants:
	@if [[ "$(origin KWT_VARIANTS_DIR)" == "file" ]]; then \
		$(MAKE) --no-print-directory bootstrap-kwt-variants; \
	else \
		$(UV) run --frozen $(PYTHON) tools/validate_kwt_variants.py \
			--variants-dir "$(KWT_VARIANTS_DIR)" \
			--revision "$(KWT_REF)"; \
	fi

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
	@$(UV) run --frozen --group dev pytest tools/tests/test_libghostty_bootstrap.py

test-terminal-fallback:
	@GHOSTHUB_FORCE_TERMINAL_UNAVAILABLE=1 $(SWIFT) build --scratch-path .build/terminal-unavailable

test-stage-release-app-bundles:
	@$(UV) run --frozen --group dev pytest tools/tests/test_stage_release_app_bundles.py

test-assemble-app-bundle:
	@$(UV) run --frozen --group dev pytest tools/tests/test_assemble_app_bundle.py

ensure-tmux:
	@command -v tmux >/dev/null || { \
		command -v brew >/dev/null || { \
			echo "tmux is required for the pinned kwt contract tests" >&2; \
			exit 1; \
		}; \
		brew install tmux; \
	}

test-kwt-contract: ensure-kwt ensure-tmux
	@GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS=1 \
		GHOSTHUB_KWT_CONTRACT_BINARY="$(KWT_BINARY_PATH)" \
		sh tools/run_with_timeout.sh 600 sh tools/run_swift_tests.sh \
			$(SWIFT) test --filter PinnedKwtContractTests

# Bounds the render work a key-window switch may trigger; catches
# focus-driven view invalidation regressions in seconds.
test-activation-gate:
	@sh tools/run_swift_tests.sh $(SWIFT) test \
		--disable-xctest --filter ActivationWorkGateTests

# Essential workflow smoke for kwt inventory and ordinary tmux attachment.
test-essential-workflows: test-kwt-contract
	@set -euo pipefail; \
	for filter in \
		KwtInventoryClientTests \
		CommandHostResolverTests \
		TmuxAttachmentInfoTests \
		WorkspaceSidebarModelTests \
	; do \
		sh tools/run_with_timeout.sh 600 sh tools/run_swift_tests.sh \
			$(SWIFT) test --filter $$filter; \
	done

test-ssh-authentication-live: bootstrap-libghostty
	@test -n "$(GHOSTHUB_SSH_INTEGRATION_DESTINATION)" || \
		{ printf 'Set GHOSTHUB_SSH_INTEGRATION_DESTINATION=user@host\n' >&2; exit 2; }
	@GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS=1 \
		GHOSTHUB_SSH_INTEGRATION_DESTINATION="$(GHOSTHUB_SSH_INTEGRATION_DESTINATION)" \
		sh tools/run_swift_tests.sh $(SWIFT) test \
			--filter SSHAuthenticationSessionTests/liveAuthenticationMaster

build: bootstrap-libghostty
	@$(SWIFT) build

# This gate is about warnings in Ghosthub's own Swift code. Ghostty's umbrella
# header deliberately omits the ghostty/vt headers, and clang only reports that
# while building the GhosttyKit module, so leaving it fatal made the gate pass
# or fail on whether the module cache happened to be warm.
swift-warning-check: bootstrap-libghostty
	@$(SWIFT) build --build-tests -Xswiftc -warnings-as-errors \
		-Xcc -Wno-incomplete-umbrella

bootstrap-libghostty-release: LIBGHOSTTY_OPTIMIZE = ReleaseFast
bootstrap-libghostty-release: bootstrap-libghostty

check-libghostty-release: LIBGHOSTTY_OPTIMIZE = ReleaseFast
check-libghostty-release: check-libghostty

build-release: LIBGHOSTTY_OPTIMIZE = ReleaseFast
build-release: bootstrap-libghostty-release
	@$(SWIFT) build --configuration release --product "$(GHOSTHUB_APP)"

debug-app: LIBGHOSTTY_QUIET_NOOP = 1
debug-app: ensure-kwt ensure-kwt-variants bootstrap-libghostty
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
		--version "$(DEVELOPMENT_APP_VERSION)" \
		--build-version "$(RELEASE_BUILD_VERSION)" \
		--release-channel development \
		--development-version "$(DEVELOPMENT_VERSION_DESCRIPTION)" \
		--min-macos "$(RELEASE_MIN_MACOS)" \
		--icon-path "$(APP_ICON_PATH)" \
		--app-license-path "$(APP_LICENSE_PATH)" \
		--kwt-binary "$$kwt_bin" \
		--kwt-variants-dir "$(KWT_VARIANTS_DIR)" \
		--libghostty-share-dir "$(LIBGHOSTTY_SHARE_DIR)" \
		--third-party-licenses-dir "$(THIRD_PARTY_LICENSES_DIR)" \
		--copyright "$(APP_COPYRIGHT)" \
		--kwt-version "$(KWT_VERSION)" \
		--kwt-source-revision "$(KWT_SOURCE_REVISION)" \
		--remote-kwt-source-revision "$(KWT_REF)" >/dev/null; \
	codesign --force --deep --sign - "$(DEBUG_APP_PATH)" >/dev/null; \
	codesign --verify --deep --strict "$(DEBUG_APP_PATH)"; \
	printf 'Built debug app bundle: %s\n' "$(DEBUG_APP_PATH)"

release-app: LIBGHOSTTY_OPTIMIZE = ReleaseFast
release-app: ensure-kwt ensure-kwt-variants build-release
	@set -euo pipefail; \
	kwt_bin="$(KWT_BINARY_PATH)"; \
	if [[ -z "$$kwt_bin" || ! -x "$$kwt_bin" ]]; then \
		printf 'KWT_BINARY_PATH must name an executable kwt binary.\n' >&2; \
		exit 1; \
	fi; \
	bin_dir="$$($(SWIFT) build --configuration release --show-bin-path)"; \
	app_bin="$$bin_dir/$(GHOSTHUB_APP)"; \
	app_root="$(RELEASE_APP_PATH)"; \
	assemble_arguments=($(UV) run --frozen $(PYTHON) tools/assemble_app_bundle.py \
		--source-bin-dir "$$bin_dir" \
		--app-root "$$app_root" \
		--app-binary "$$app_bin" \
		--bundle-id "$(RELEASE_BUNDLE_ID)" \
		--display-name "$(GHOSTHUB_APP)" \
		--version "$(RELEASE_APP_VERSION)" \
		--build-version "$(RELEASE_BUILD_VERSION)" \
		--release-channel "$(RELEASE_CHANNEL)" \
		--min-macos "$(RELEASE_MIN_MACOS)" \
		--icon-path "$(APP_ICON_PATH)" \
		--app-license-path "$(APP_LICENSE_PATH)" \
		--kwt-binary "$$kwt_bin" \
		--kwt-variants-dir "$(KWT_VARIANTS_DIR)" \
		--libghostty-share-dir "$(LIBGHOSTTY_SHARE_DIR)" \
		--third-party-licenses-dir "$(THIRD_PARTY_LICENSES_DIR)" \
		--copyright "$(APP_COPYRIGHT)" \
		--kwt-version "$(KWT_VERSION)" \
		--kwt-source-revision "$(KWT_SOURCE_REVISION)" \
		--remote-kwt-source-revision "$(KWT_REF)"); \
	if [[ "$(RELEASE_CHANNEL)" == "nightly" ]]; then \
		assemble_arguments+=( \
			--nightly-feed-url "$(NIGHTLY_SPARKLE_FEED_URL)" \
			--nightly-public-ed-key "$(NIGHTLY_SPARKLE_PUBLIC_ED_KEY)" \
			--source-revision "$(NIGHTLY_SOURCE_REVISION)" \
			--build-date "$(NIGHTLY_BUILD_DATE)" \
		); \
	fi; \
	"$${assemble_arguments[@]}" >/dev/null; \
	printf 'Built release app bundle: %s\n' "$(RELEASE_APP_PATH)"

run-release-app: release-app
	@open "$(RELEASE_APP_PATH)"

release-dmg: LIBGHOSTTY_OPTIMIZE = ReleaseFast
release-dmg:
	@RELEASE_APP_VERSION="$(RELEASE_APP_VERSION)" \
		./tools/build_release_dmg.sh

release-appcast:
	@RELEASE_APP_VERSION="$(RELEASE_APP_VERSION)" \
		./tools/generate_update_appcast.sh

nightly-app:
	@$(MAKE) release-app \
		RELEASE_CHANNEL=nightly \
		RELEASE_ROOT="$(NIGHTLY_RELEASE_ROOT)"

nightly-dmg:
	@RELEASE_CHANNEL=nightly \
		RELEASE_ROOT="$(NIGHTLY_RELEASE_ROOT)" \
		./tools/build_release_dmg.sh

nightly-appcast:
	@RELEASE_ROOT="$(NIGHTLY_RELEASE_ROOT)" \
		./tools/generate_nightly_update_appcast.sh

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
	cmd=(sh tools/run_swift_tests.sh $(SWIFT) test); \
	if [[ -n "$(SWIFT_TEST_FILTER)" ]]; then \
		cmd+=(--filter "$(SWIFT_TEST_FILTER)"); \
	fi; \
	printf 'Running:'; \
	printf ' %q' "$${cmd[@]}"; \
	printf '\n'; \
	"$${cmd[@]}"

test-tmux-attach: bootstrap-libghostty
	@set -euo pipefail; \
	sh tools/run_with_timeout.sh 600 sh tools/run_swift_tests.sh \
		$(SWIFT) test --filter GhosthubTmuxTests; \
	sh tools/run_with_timeout.sh 600 sh tools/run_swift_tests.sh \
		$(SWIFT) test --filter TmuxInjectionSmokeTests

purge-test-tmux:
	@sh tools/purge_test_tmux.sh

python-test:
	@$(UV) run --frozen --group dev pytest

sandbox-image-check:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py check

sandbox-image-prepare-candidate:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py prepare-candidate

unexport VERSION IMAGE APP_ID CLIENT_ID PRIVATE_KEY
override SANDBOX_IMAGE_VERSION_VALUE := $(value VERSION)
override SANDBOX_IMAGE_REFERENCE_VALUE := $(value IMAGE)

sandbox-image-refresh: export SANDBOX_IMAGE_VERSION_INPUT := $(SANDBOX_IMAGE_VERSION_VALUE)
sandbox-image-refresh:
	@test -n "$${SANDBOX_IMAGE_VERSION_INPUT:-}" || { echo 'Set VERSION=X.Y.Z' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py refresh \
		--version "$${SANDBOX_IMAGE_VERSION_INPUT}"

sandbox-image-vet sandbox-image-pin sandbox-image-promote: export SANDBOX_IMAGE_REFERENCE_INPUT := $(SANDBOX_IMAGE_REFERENCE_VALUE)
sandbox-image-vet:
	@test -n "$${SANDBOX_IMAGE_REFERENCE_INPUT:-}" || { echo 'Set IMAGE=<candidate@digest>' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py vet \
		--image "$${SANDBOX_IMAGE_REFERENCE_INPUT}"

sandbox-image-pin:
	@test -n "$${SANDBOX_IMAGE_REFERENCE_INPUT:-}" || { echo 'Set IMAGE=<candidate@digest>' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py pin \
		--image "$${SANDBOX_IMAGE_REFERENCE_INPUT}"

sandbox-image-promote: export SANDBOX_IMAGE_VERSION_INPUT := $(SANDBOX_IMAGE_VERSION_VALUE)
sandbox-image-promote:
	@test -n "$${SANDBOX_IMAGE_REFERENCE_INPUT:-}" || { echo 'Set IMAGE=<candidate@digest>' >&2; exit 2; }
	@test -n "$${SANDBOX_IMAGE_VERSION_INPUT:-}" || { echo 'Set VERSION=X.Y.Z' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py promote \
		--image "$${SANDBOX_IMAGE_REFERENCE_INPUT}" \
		--version "$${SANDBOX_IMAGE_VERSION_INPUT}"

sandbox-image-clean:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py clean

sandbox-image-status:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py status

override SANDBOX_APP_ID_VALUE := $(value APP_ID)
override SANDBOX_CLIENT_ID_VALUE := $(value CLIENT_ID)
override SANDBOX_PRIVATE_KEY_VALUE := $(value PRIVATE_KEY)

sandbox-image-authority-configure: export SANDBOX_APP_ID_INPUT := $(SANDBOX_APP_ID_VALUE)
sandbox-image-authority-configure: export SANDBOX_CLIENT_ID_INPUT := $(SANDBOX_CLIENT_ID_VALUE)
sandbox-image-authority-configure: export SANDBOX_PRIVATE_KEY_INPUT := $(SANDBOX_PRIVATE_KEY_VALUE)
sandbox-image-authority-configure:
	@test -n "$${SANDBOX_APP_ID_INPUT:-}" || { echo 'Set APP_ID=<numeric GitHub App ID>' >&2; exit 2; }
	@test -n "$${SANDBOX_CLIENT_ID_INPUT:-}" || { echo 'Set CLIENT_ID=<GitHub App client ID>' >&2; exit 2; }
	@test -n "$${SANDBOX_PRIVATE_KEY_INPUT:-}" || { echo 'Set PRIVATE_KEY=<PEM path>' >&2; exit 2; }
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py authority-configure \
		--app-id "$${SANDBOX_APP_ID_INPUT}" \
		--client-id "$${SANDBOX_CLIENT_ID_INPUT}" \
		--private-key "$${SANDBOX_PRIVATE_KEY_INPUT}"

sandbox-image-authority-enable:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py authority-enable

sandbox-image-authority-audit:
	@$(UV) run --frozen $(PYTHON) tools/sandbox_image.py authority-audit

sandbox-image-python-lint:
	@$(UV) run --frozen --group dev ruff check \
		tools/sandbox_image.py tools/sandbox_image tools/tests/test_sandbox_image_*.py

sandbox-image-python-typecheck:
	@$(UV) run --frozen --group dev ty check \
		tools/sandbox_image.py tools/sandbox_image tools/tests/test_sandbox_image_*.py

zizmor:
	@$(UV) tool run --from zizmor==1.29.0 zizmor --pedantic \
		.github/workflows/sandbox-image*.yml

test: swift-test python-test

smoke-test: bootstrap-libghostty
	@sh tools/run_swift_tests.sh \
		$(SWIFT) test --filter LibghosttyRuntimeSmokeTests

docs-build:
	@cd docs && $(UV) run --frozen ./zensical-docs.sh build

docs-serve:
	@cd docs && $(UV) run --frozen ./zensical-docs.sh serve

site-docs-serve:
	@cd website && bash scripts/sync-changelog.sh && \
		./scripts/run-uv.sh run --project docs --frozen zensical serve --config-file zensical.toml

site-deploy:
	@cd website && $(PNPM) build
	@$(VERCEL) deploy --prod

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

format:
	@if ! command -v swiftformat >/dev/null 2>&1; then \
		echo "swiftformat not found. Install with: brew install swiftformat" >&2; \
		exit 1; \
	fi
	swiftformat --quiet .

format-check:
	@if ! command -v swiftformat >/dev/null 2>&1; then \
		echo "swiftformat not found. Install with: brew install swiftformat" >&2; \
		exit 1; \
	fi
	swiftformat --lint .
