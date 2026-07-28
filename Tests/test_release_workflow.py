from pathlib import Path


def workflow_text() -> str:
    repo_root = Path(__file__).resolve().parents[1]
    return (repo_root / ".github" / "workflows" / "release.yml").read_text()


def release_script_text() -> str:
    repo_root = Path(__file__).resolve().parents[1]
    return (repo_root / "tools" / "build_release_dmg.sh").read_text()


def test_release_workflow_bundles_a_revision_pinned_kwt():
    text = workflow_text()

    assert "repository: ${{ env.KWT_REPOSITORY }}" in text
    assert "KWT_REPOSITORY: kenn-io/kwt" in text
    assert 'revision="$(tr -d \'[:space:]\' < KWT_REVISION)"' in text
    assert "ref: ${{ steps.kwt-pin.outputs.revision }}" in text
    assert "path: .release-inputs/kwt-source" in text
    assert "actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16" in text
    assert "KWT_BINARY_PATH=$kwt_binary" in text
    assert 'kwt_archs="$(lipo -archs "$kwt_binary")"' in text
    assert '[[ "$kwt_archs" != "arm64" ]]' in text
    assert "third_party/middleman" not in text


def test_release_workflow_matches_the_green_ghostty_toolchain():
    text = workflow_text()

    assert "runs-on: macos-26" in text
    assert "/Applications/Xcode_26.0.1.app" in text
    assert "ZIG_VERSION: 0.15.2" in text
    assert "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b" in text
    assert "brew install zig" not in text


def test_release_workflow_supports_candidates_and_same_repo_releases():
    text = workflow_text()

    assert "workflow_dispatch:" in text
    assert "permissions:\n  # The build job only checks out source" in text
    assert "contents: read" in text
    assert "publish-release:" in text
    assert "contents: write" in text
    assert "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in text
    assert "include-hidden-files: true" in text
    assert "overwrite: true" in text
    assert "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c" in text
    assert 'gh release view "$GITHUB_REF_NAME"' in text
    assert 'gh release create "$GITHUB_REF_NAME"' in text
    assert 'gh release edit "$GITHUB_REF_NAME"' in text
    assert 'gh release upload "$GITHUB_REF_NAME"' in text
    assert "--clobber" in text
    assert "GH_TOKEN: ${{ github.token }}" in text
    assert ".dist/release/SHA256SUMS" in text
    assert ".dist/release/appcast.xml" in text
    assert "softprops/action-gh-release@" not in text
    assert "BETA_RELEASE_TOKEN" not in text
    assert "wesm/ghosthub" not in text
    assert "repository: ${{ env.RELEASE_REPOSITORY }}" not in text


def test_release_workflow_signs_updates_with_the_protected_sparkle_key():
    text = workflow_text()
    prepare_start = text.index("- name: Prepare Apple signing credentials")
    prepare_end = text.index("- name: Build signed and notarized DMG")
    appcast_start = text.index("- name: Generate signed update appcast")
    appcast_end = text.index("- name: Upload notarized candidate")
    candidate_start = appcast_end
    candidate_end = text.index("- name: Upload notarized release")
    release_upload_start = candidate_end
    release_upload_end = text.index("- name: Clean up signing credentials")

    prepare = text[prepare_start:prepare_end]
    appcast = text[appcast_start:appcast_end]
    candidate = text[candidate_start:candidate_end]
    release_upload = text[release_upload_start:release_upload_end]

    assert "SPARKLE_ED_PRIVATE_KEY" not in prepare
    assert "SPARKLE_PUBLIC_ED_KEY" not in prepare
    assert (
        "if: github.event_name == 'push' && github.ref_type == 'tag'"
        in appcast
    )
    assert (
        "SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"
        in appcast
    )
    assert (
        "SPARKLE_PUBLIC_ED_KEY: ${{ vars.SPARKLE_PUBLIC_ED_KEY }}"
        in appcast
    )
    assert "run: ./tools/generate_update_appcast.sh" in appcast
    assert "if: github.event_name == 'workflow_dispatch'" in candidate
    assert ".dist/release/appcast.xml" not in candidate
    assert (
        "if: github.event_name == 'push' && github.ref_type == 'tag'"
        in release_upload
    )
    assert ".dist/release/appcast.xml" in release_upload
    assert "gh release upload" in text


def test_release_signing_is_restricted_to_trusted_refs_and_environment():
    text = workflow_text()

    assert "name: release-signing" in text
    assert "github.ref == 'refs/heads/main'" in text
    assert (
        "if: github.event_name == 'push' && github.ref_type == 'tag'"
        in text
    )
    assert "if: github.ref_type == 'tag'" not in text


def test_release_signs_nested_code_before_the_app_and_validates_notarization():
    text = release_script_text()

    assert 'xattr -cr "$RELEASE_APP_PATH"' in text
    assert 'xattr -cr "$RELEASE_APP_PATH" || true' not in text
    sparkle_sign = text.index("Codesigning Sparkle component")
    helper_sign = text.index("Codesigning kwt helper")
    remote_helper_sign = text.index("Codesigning remote kwt helper")
    app_sign = text.index("Codesigning app bundle")
    assert sparkle_sign < helper_sign < remote_helper_sign < app_sign
    assert "Versions/B/Autoupdate" in text
    assert "XPCServices/Downloader.xpc" in text
    assert "XPCServices/Installer.xpc" in text
    assert "Versions/B/Updater.app" in text
    assert "for target in darwin-amd64 darwin-arm64" in text
    assert "--preserve-metadata=identifier,entitlements" in text
    assert "entitlements,requirements" not in text
    assert 'codesign --verify --strict --verbose=2 "$KWT_HELPER_PATH"' in text
    assert (
        'codesign --verify --strict --verbose=2 "$REMOTE_KWT_HELPER_PATH"'
        in text
    )
    assert 'xcrun stapler validate "$RELEASE_DMG_PATH"' in text
    assert "spctl --assess --type open" in text


def test_individual_dmg_checksum_uses_a_portable_basename():
    text = release_script_text()

    assert 'RELEASE_DMG_BASENAME="$(basename "$RELEASE_DMG_PATH")"' in text
    assert 'shasum -a 256 "$RELEASE_DMG_BASENAME"' in text
    assert 'shasum -a 256 "$RELEASE_DMG_PATH"' not in text
