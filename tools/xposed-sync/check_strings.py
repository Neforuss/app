#!/usr/bin/env python3
"""Fail when a string the custom tweaks look up is missing from en.lproj.

Checks:
  * every localizedStringForKey:@"KEY" / L(@"KEY") literal in the files the
    custom tweaks touch;
  * every toggle registered in src/Core/BHTSettings.m has KEY_TITLE (the
    settings page derives the row title from the key when no titleKey is
    given), and every explicit titleKey / subtitleDefaultKey exists.

Run from the repository root:  python3 tools/xposed-sync/check_strings.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STRINGS = ROOT / "layout/Library/Application Support/BHT/BHTwitter.bundle/en.lproj/Localizable.strings"
SOURCES = [
    *sorted((ROOT / "src/Custom").glob("*.[mx]")),
    ROOT / "src/Hooks/Profile.x",
    ROOT / "src/Download/DownloadInlineButton.m",
]
SETTINGS = ROOT / "src/Core/BHTSettings.m"

ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
LOOKUP = re.compile(r'(?:localizedStringForKey:\s*|\bL\(\s*)@"([A-Z0-9_]+)"')


def main():
    text = re.sub(r"/\*.*?\*/", "", STRINGS.read_text(encoding="utf-8"), flags=re.S)
    known = {m.group(1) for m in ENTRY.finditer(text)}
    missing = []

    for path in SOURCES:
        for key in LOOKUP.findall(path.read_text(encoding="utf-8")):
            if key not in known:
                missing.append(f"{path.relative_to(ROOT)}: {key}")

    settings = SETTINGS.read_text(encoding="utf-8")
    for block in re.findall(r"@\{([^{}]*)\}", settings):
        key = re.search(r'@"key":\s*@"([a-z0-9_]+)"', block)
        title_key = re.search(r'@"titleKey":\s*@"([A-Z0-9_]+)"', block)
        subtitle_key = re.search(r'@"subtitleDefaultKey":\s*@"([A-Z0-9_]+)"', block)
        if title_key:
            wanted = [title_key.group(1)]
        elif key:
            wanted = [key.group(1).upper() + "_TITLE"]
        else:
            wanted = []
        if subtitle_key:
            wanted.append(subtitle_key.group(1))
        missing += [f"BHTSettings.m: {w}" for w in wanted if w not in known]

    if missing:
        print("missing from en.lproj/Localizable.strings:")
        for item in missing:
            print("  " + item)
        return 1
    print(f"ok: {len(SOURCES)} sources and the settings registry resolve against {len(known)} strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
