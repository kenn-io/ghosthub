#!/usr/bin/env python3

import argparse
import plistlib
import sys
from pathlib import Path
from xml.etree import ElementTree


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def verify_appcast(
    appcast_path: Path,
    info_plist_path: Path,
    expected_url: str,
) -> None:
    with info_plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    if not isinstance(plist, dict) or "CFBundleVersion" not in plist:
        raise ValueError("app Info.plist is missing CFBundleVersion")
    app_build_value = plist["CFBundleVersion"]
    if not isinstance(app_build_value, (str, int)) or isinstance(
        app_build_value, bool
    ):
        raise ValueError("app CFBundleVersion must be a string or integer")
    app_build = str(app_build_value)

    root = ElementTree.parse(appcast_path)
    items = root.findall(".//item")
    enclosures = [
        (item, enclosure)
        for item in items
        for enclosure in item.findall("enclosure")
    ]
    if len(enclosures) != 1:
        raise ValueError("appcast must contain exactly one enclosure")
    item, enclosure = enclosures[0]
    if enclosure.get("url") != expected_url:
        raise ValueError("appcast enclosure URL does not match the artifact")
    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        raise ValueError("appcast enclosure is missing its Sparkle signature")
    if item.findtext(f"{{{SPARKLE_NAMESPACE}}}version") != app_build:
        raise ValueError("appcast version does not match CFBundleVersion")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--expected-url", required=True)
    args = parser.parse_args()
    try:
        verify_appcast(args.appcast, args.info_plist, args.expected_url)
    except (OSError, ValueError, ElementTree.ParseError) as error:
        print(f"Could not verify appcast: {error}", file=sys.stderr)
        return 1
    with args.info_plist.open("rb") as handle:
        build = plistlib.load(handle)["CFBundleVersion"]
    print(f"Verified Sparkle appcast build {build}: {args.expected_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
