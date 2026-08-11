#!/usr/bin/env python3
"""Verify that managed-tool metadata and public notices stay in sync."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import date
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "ThirdPartyLicenses/managed-tools.json"

ROBOT_SENTENCE = (
    "The Android robot is reproduced or modified from work created and shared by Google "
    "and used according to terms described in the Creative Commons 3.0 Attribution License."
)
ROBOT_MARKDOWN = (
    "*The Android robot is reproduced or modified from work created and shared by Google and used "
    "according to terms described in the* [*Creative Commons*]"
    "(https://creativecommons.org/licenses/by/3.0/) *3.0 Attribution License.*"
)

OFF_HOME_PAGES = {
    "docs/connect/index.html": "Connect",
    "docs/faq/index.html": "FAQ &amp; Troubleshooting",
    "docs/phone-tools/index.html": "Phone Tools",
    "docs/privacy/index.html": "Privacy Policy",
    "docs/terms/index.html": "Terms of Service",
    "docs/third-party-notices/index.html": "Third-Party Notices",
}


class SectionTextParser(HTMLParser):
    def __init__(self, section_id: str) -> None:
        super().__init__()
        self.section_id = section_id
        self.depth = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "section" and attributes.get("id") == self.section_id:
            self.depth = 1
        elif self.depth:
            self.depth += 1

    def handle_endtag(self, tag: str) -> None:
        if self.depth:
            self.depth -= 1

    def handle_data(self, data: str) -> None:
        if self.depth:
            self.parts.append(data)

    @property
    def text(self) -> str:
        return " ".join(" ".join(self.parts).split())


def load_text(relative_path: str, errors: list[str]) -> str:
    path = ROOT / relative_path
    if not path.is_file():
        errors.append(f"Missing required file: {relative_path}")
        return ""
    return path.read_text(encoding="utf-8")


def require_snippets(relative_path: str, snippets: list[str], errors: list[str]) -> None:
    content = load_text(relative_path, errors)
    for snippet in snippets:
        if snippet not in content:
            errors.append(f"{relative_path} is missing managed-tool metadata: {snippet}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_sha(value: str, label: str, errors: list[str]) -> None:
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        errors.append(f"{label} must be a lowercase SHA-256 value")


def main() -> int:
    errors: list[str] = []
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Could not read {MANIFEST_PATH.relative_to(ROOT)}: {error}", file=sys.stderr)
        return 1

    if manifest.get("schemaVersion") != 1:
        errors.append("managed-tools.json schemaVersion must be 1")

    managed = manifest["managedToolchain"]
    scrcpy = managed["scrcpy"]
    adb = managed["adb"]
    archives = managed["archives"]
    website = manifest["website"]

    sha_fields = {
        "scrcpy license": scrcpy["licenseSHA256"],
        "upstream scrcpy license": scrcpy["upstreamLicenseSHA256"],
        "scrcpy server": scrcpy["serverSHA256"],
        "ADB executable": adb["executableSHA256"],
        "ADB notice": adb["noticeSHA256"],
        "ADB source.properties": adb["sourcePropertiesSHA256"],
    }
    for archive in archives:
        sha_fields[f"{archive['architecture']} archive"] = archive["archiveSHA256"]
        sha_fields[f"{archive['architecture']} scrcpy executable"] = archive["scrcpyExecutableSHA256"]
    for label, value in sha_fields.items():
        validate_sha(value, label, errors)

    for key in ("licenseFile",):
        if not (ROOT / scrcpy[key]).is_file():
            errors.append(f"Missing file named by managed-tools.json: {scrcpy[key]}")
    for key in ("noticeFile", "recordFile"):
        if not (ROOT / adb[key]).is_file():
            errors.append(f"Missing file named by managed-tools.json: {adb[key]}")

    license_path = ROOT / scrcpy["licenseFile"]
    if license_path.is_file() and sha256(license_path) != scrcpy["licenseSHA256"]:
        errors.append(f"{scrcpy['licenseFile']} does not match its manifest SHA-256")

    notice_path = ROOT / adb["noticeFile"]
    if notice_path.is_file() and sha256(notice_path) != adb["noticeSHA256"]:
        errors.append(f"{adb['noticeFile']} does not match its manifest SHA-256")

    swift_snippets = [
        f'version: "{scrcpy["version"]}"',
        f'adbVersionMarker: "{adb["buildMarker"]}"',
        f'scrcpyVersionMarker: "{scrcpy["versionMarker"]}"',
        f'adbSHA256: "{adb["executableSHA256"]}"',
        f'scrcpyServerSHA256: "{scrcpy["serverSHA256"]}"',
    ]
    test_snippets = [
        f'"{scrcpy["version"]}"',
        f'"{adb["buildMarker"]}"',
        f'"{scrcpy["versionMarker"]}"',
        f'"{adb["executableSHA256"]}"',
        f'"{scrcpy["serverSHA256"]}"',
    ]
    for archive in archives:
        swift_snippets.extend(
            [
                f'archiveURL: URL(string: "{archive["downloadURL"]}")!',
                f'archiveDirectoryName: "{archive["directoryName"]}"',
                f'archiveSHA256: "{archive["archiveSHA256"]}"',
                f'scrcpySHA256: "{archive["scrcpyExecutableSHA256"]}"',
            ]
        )
        test_snippets.extend(
            [
                f'"{archive["downloadURL"]}"',
                f'"{archive["directoryName"]}"',
                f'"{archive["archiveSHA256"]}"',
                f'"{archive["scrcpyExecutableSHA256"]}"',
            ]
        )

    require_snippets("Sources/AndroidFileBrowserCore/ToolchainManager.swift", swift_snippets, errors)
    require_snippets("Tests/AndroidFileBrowserCoreTests/ToolchainManagerTests.swift", test_snippets, errors)
    require_snippets(
        "scripts/package-app.sh",
        [
            f'ADB_PINNED_REVISION="{adb["version"]}"',
            f'ADB_PINNED_SHA256="{adb["executableSHA256"]}"',
            f'ADB_NOTICE_PINNED_SHA256="{adb["noticeSHA256"]}"',
            f'ADB_SOURCE_PROPERTIES_PINNED_SHA256="{adb["sourcePropertiesSHA256"]}"',
            Path(adb["noticeFile"]).name,
        ],
        errors,
    )
    require_snippets(
        adb["recordFile"],
        [adb["version"], adb["executableSHA256"], adb["noticeSHA256"], adb["sourcePropertiesSHA256"]],
        errors,
    )
    require_snippets(
        "ThirdPartyLicenses/README.md",
        [
            Path(scrcpy["licenseFile"]).name,
            Path(adb["noticeFile"]).name,
            Path(adb["recordFile"]).name,
            "managed-tools.json",
        ],
        errors,
    )
    require_snippets(
        "TOOLS.md",
        [scrcpy["version"], adb["version"], scrcpy["releaseURL"], "Managed Copy"],
        errors,
    )
    require_snippets(
        "THIRD_PARTY_NOTICES.md",
        [
            scrcpy["version"],
            adb["version"],
            Path(scrcpy["licenseFile"]).name,
            Path(adb["noticeFile"]).name,
            ROBOT_MARKDOWN,
        ]
        + [value for archive in archives for value in (archive["assetName"], archive["archiveSHA256"])],
        errors,
    )
    require_snippets(
        "README.md",
        ["Managed Copy", "Third-party notices"],
        errors,
    )

    notice_html_path = "docs/third-party-notices/index.html"
    notice_html = load_text(notice_html_path, errors)
    for snippet in (scrcpy["version"], adb["version"], "Managed Copy", 'id="android-robot"'):
        if snippet not in notice_html:
            errors.append(f"{notice_html_path} is missing managed-tool metadata: {snippet}")
    robot_parser = SectionTextParser("android-robot")
    robot_parser.feed(notice_html)
    if ROBOT_SENTENCE not in robot_parser.text:
        errors.append(f"{notice_html_path} does not contain the required Android robot attribution")
    reviewed = date.fromisoformat(manifest["reviewedOn"])
    reviewed_label = f"Managed tool versions reviewed {reviewed.strftime('%B')} {reviewed.day}, {reviewed.year}"
    if reviewed_label not in notice_html:
        errors.append(f"{notice_html_path} does not match the manifest review date")

    copyright_line = f"© {website['copyrightStartYear']} {website['copyrightHolder']}"
    all_pages = ["docs/index.html", *OFF_HOME_PAGES]
    for relative_path in all_pages:
        content = load_text(relative_path, errors)
        if copyright_line not in content:
            errors.append(f"{relative_path} is missing the canonical copyright line")

    brand_markup = '<a class="brand" href="../" aria-label="AOSP File Manager overview">'
    for relative_path, title in OFF_HOME_PAGES.items():
        content = load_text(relative_path, errors)
        header = re.search(r"<header\b.*?</header>", content, re.DOTALL)
        footer = re.search(r"<footer\b.*?</footer>", content, re.DOTALL)
        if not header or brand_markup not in header.group(0) or "page-breadcrumb" in header.group(0):
            errors.append(f"{relative_path} must keep the standard brand in its header")
        expected_title = f'<span class="breadcrumb-title" aria-current="page">{title}</span>'
        if not footer or 'class="footer-breadcrumb"' not in footer.group(0) or expected_title not in footer.group(0):
            errors.append(f"{relative_path} is missing its footer breadcrumb")

    if errors:
        print("Third-party metadata validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        "Third-party metadata is consistent: "
        f"scrcpy {scrcpy['version']}, ADB {adb['version']}, notices, website attribution, and footer breadcrumbs."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
