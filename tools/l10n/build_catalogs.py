#!/usr/bin/env python3
# Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the String Catalogs (English source, German translation).

Source of truth are the JSON files next to this script:
  de.json            English UI text -> German
  infoplist_de.json  Info.plist values -> German

Run after every change:  python3 tools/l10n/build_catalogs.py
The output uses Xcode's own formatting (" : ", sorted keys), so opening
the catalog in Xcode does not produce unrelated diffs.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
NO_TRANSLATE = {"Schnittwerk"}


def sort_key(s: str):
    # Close to Xcode's localizedStandardCompare: case-insensitive first
    return (s.casefold(), s)


def entry(value: str):
    return {"localizations": {"de": {"stringUnit": {"state": "translated", "value": value}}}}


def build(src: pathlib.Path, dst: pathlib.Path, extra_untranslated=()):
    de = json.loads(src.read_text(encoding="utf-8"))
    strings = {}
    for key in sorted(set(de) | set(extra_untranslated), key=sort_key):
        if key in NO_TRANSLATE or key not in de:
            strings[key] = {"shouldTranslate": False}
        else:
            strings[key] = entry(de[key])
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(text + "\n", encoding="utf-8")
    print(f"{dst.relative_to(ROOT)}: {len(strings)} entries")


def extracted_keys():
    """UI texts the compiler found in the app (needs a build in ./build)."""
    keys = set()
    base = ROOT / "build" / "Build" / "Intermediates.noindex"
    for f in base.glob("Schnittwerk.build/*/Schnittwerk.build/Objects-normal/*/*.stringsdata"):
        data = json.loads(f.read_text(encoding="utf-8"))
        for entries in data.get("tables", {}).values():
            keys.update(e["key"] for e in entries)
    return keys


def main():
    res = ROOT / "Schnittwerk" / "Resources"
    build(HERE / "de.json", res / "Localizable.xcstrings", extra_untranslated=NO_TRANSLATE)
    build(HERE / "infoplist_de.json", res / "InfoPlist.xcstrings")

    found = extracted_keys()
    if not found:
        print("Hint: build the app into ./build to check for missing translations.")
        return 0
    known = set(json.loads((HERE / "de.json").read_text(encoding="utf-8"))) | NO_TRANSLATE
    missing = sorted(found - known, key=sort_key)
    unused = sorted(known - found, key=sort_key)
    for key in missing:
        print(f"MISSING German translation: {key!r}")
    for key in unused:
        print(f"unused: {key!r}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
