# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Put a release into the appcast Sparkle reads.

    uv run Scripts/appcast.py --version 1.1 --build 2 --dmg dist/AirStats.dmg \\
        --signature 'sparkle:edSignature="..." length="123"'

`Scripts/release.sh` calls this with what `sign_update` just printed. The file it edits
lives in the *site* repo, which is a separate checkout with its own branch and its own
push: this writes it and stops there, deliberately, because the appcast going live
before the GitHub release exists points every installed copy at a download that 404s.

Sparkle's own `generate_appcast` is not used. It derives an appcast from a folder of
archives and wants each one under its own name, and every AirStats release is called
AirStats.dmg so that releases/latest/download keeps resolving. One filename and many
versions is exactly the shape that tool cannot express.

Items are keyed by build number, replaced rather than duplicated when a version is
built twice, and sorted newest first. Sparkle reads the whole feed and picks the
highest `sparkle:version` it can run, so the order is for whoever opens the file.

Release notes come from `src/changelog.json` in the site checkout, the file the site's
/changelog page is built from, so the update window and the page say the same thing.
A version with no entry there is refused: `--check` runs that test alone, which is how
`Scripts/release.sh` finds out before notarizing rather than after.
"""

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DOWNLOAD_URL = "https://github.com/byrencheema/airstats/releases/download/v{version}/AirStats.dmg"
# What Sparkle's Version History button opens. The item's own notes are embedded rather
# than linked, so the update window never depends on a page having deployed first.
CHANGELOG_URL = "https://airstats.app/changelog"
SITE = Path(__file__).resolve().parents[2] / "airstat-site"

# What the running copy's LSMinimumSystemVersion says. Offering an update a Mac cannot
# launch is worse than offering none: Sparkle installs it and the app stops opening.
MINIMUM_SYSTEM_VERSION = "14.0"

# Four spaces, because that is what the file in the site repo uses and rewriting its
# indentation on every release would bury one new item in a whole-file diff.
INDENT = "    "

# Only reached when the site checkout has no appcast at all, and written to match the
# one that is there so the two cannot drift.
EMPTY_APPCAST = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{ns}">
    <channel>
        <title>AirStats</title>
        <link>https://airstats.app</link>
        <description>AirStats releases.</description>
        <language>en</language>
    </channel>
</rss>
""".format(ns=SPARKLE_NS)


def parse_signature(text, dmg):
    """The two enclosure attributes out of what `sign_update` printed.

    The length is re-derived from the file and compared rather than trusted, because a
    signature and a length that describe different files is the one failure Sparkle
    reports to the user as a corrupt download.
    """
    signature = re.search(r'sparkle:edSignature="([^"]+)"', text)
    length = re.search(r'length="(\d+)"', text)
    if not signature or not length:
        sys.exit(f"error: could not read a signature out of {text!r}")
    actual = os.path.getsize(dmg)
    if int(length.group(1)) != actual:
        sys.exit(f"error: the signature is for {length.group(1)} bytes, {dmg} is {actual}")
    return signature.group(1), str(actual)


# The headings a release's notes fall under, in order. The site's Changelog page lists
# the same three.
GROUPS = [("new", "New"), ("improved", "Improved"), ("fixed", "Fixed")]


def release_notes(changelog, version):
    """The notes `changelog` lists for `version` as (heading, bullets) pairs, or exit."""
    if not changelog.exists():
        sys.exit(f"error: no changelog at {changelog}")
    for release in json.loads(changelog.read_text(encoding="utf-8")):
        if release.get("version") == version:
            groups = [(title, release[key]) for key, title in GROUPS if release.get(key)]
            if groups:
                return groups
            break
    sys.exit(f"error: {changelog} has no notes for {version}. Write them before releasing.")


def build_number(item):
    """An item's `sparkle:version` as an integer, or -1 if it has none."""
    element = item.find(f"{{{SPARKLE_NS}}}version")
    if element is None or not (element.text or "").strip().isdigit():
        return -1
    return int(element.text.strip())


def make_item(version, build, signature, length, notes):
    """One release, in the element order the site repo's CLAUDE.md documents.

    Sparkle does not care about the order. The person reading a diff of the appcast
    does, and there is no reason for the generator and the documentation to disagree.
    """
    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = MINIMUM_SYSTEM_VERSION
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = CHANGELOG_URL
    ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "markdown"}).text = (
        markdown(notes))
    ET.SubElement(item, "enclosure", {
        "url": DOWNLOAD_URL.format(version=version),
        f"{{{SPARKLE_NS}}}edSignature": signature,
        "length": length,
        "type": "application/octet-stream",
    })
    return item


def markdown(groups):
    """The notes as Markdown, a heading and a list per group, which is also what
    `gh release create` takes."""
    return "\n".join(
        f"### {title}\n\n" + "".join(f"- {note}\n" for note in notes) for title, notes in groups)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, e.g. 1.1")
    parser.add_argument("--build", help="CFBundleVersion, e.g. 2")
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--signature", help="what sign_update printed")
    parser.add_argument(
        "--changelog",
        type=Path,
        default=SITE / "src" / "changelog.json",
        help="where the release notes live (default: the site checkout beside this one)",
    )
    parser.add_argument("--notes-out", type=Path, help="also write the notes here as Markdown")
    parser.add_argument("--check", action="store_true",
                        help="only confirm the changelog has notes for --version")
    parser.add_argument(
        "--appcast",
        type=Path,
        default=SITE / "public" / "appcast.xml",
        help="the appcast to edit (default: the site checkout beside this one)",
    )
    args = parser.parse_args()

    notes = release_notes(args.changelog, args.version)
    if args.check:
        count = sum(len(bullets) for _, bullets in notes)
        print(f"appcast.py: {count} notes for {args.version} in {args.changelog}")
        return
    if not (args.build and args.dmg and args.signature):
        parser.error("--build, --dmg and --signature are required unless --check is given")
    if not args.build.isdigit():
        sys.exit(f"error: build {args.build!r} is not a number, and Sparkle compares it as one")
    signature, length = parse_signature(args.signature, args.dmg)

    # Registered before parsing so the file keeps its `sparkle:` prefix. Left to itself
    # ElementTree renames every namespace it writes to ns0, which is still valid XML
    # and still unreadable to the next person to open the file.
    ET.register_namespace("sparkle", SPARKLE_NS)
    # Comments survive the round trip. The appcast is a file a human edits too, and a
    # release that silently deleted the note explaining it would be a poor trade.
    parser_with_comments = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    if args.appcast.exists():
        tree = ET.parse(args.appcast, parser=parser_with_comments)
    else:
        args.appcast.parent.mkdir(parents=True, exist_ok=True)
        tree = ET.ElementTree(ET.fromstring(EMPTY_APPCAST, parser=parser_with_comments))
        print(f"appcast.py: {args.appcast} did not exist, writing a new one")

    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit(f"error: {args.appcast} has no <channel>")

    for existing in channel.findall("item"):
        if build_number(existing) == int(args.build):
            channel.remove(existing)

    channel.append(make_item(args.version, args.build, signature, length, notes))
    items = channel.findall("item")
    for item in items:
        channel.remove(item)
    for item in sorted(items, key=build_number, reverse=True):
        channel.append(item)

    ET.indent(tree, space=INDENT)
    # The declaration is written by hand because ElementTree quotes its attributes with
    # apostrophes, and a release that flipped every quote in the file would be a diff
    # nobody can read for the one line that matters.
    body = ET.tostring(tree.getroot(), encoding="unicode")
    args.appcast.write_text(f'<?xml version="1.0" encoding="utf-8"?>\n{body}\n', encoding="utf-8")
    print(f"appcast.py: wrote AirStats {args.version} (build {args.build}) into {args.appcast}")
    if args.notes_out:
        args.notes_out.write_text(markdown(notes), encoding="utf-8")
        print(f"appcast.py: wrote the release notes to {args.notes_out}")


if __name__ == "__main__":
    main()
