#!/usr/bin/env python3
"""Generates app/src/main/assets/strings.json: Blip for Android's UI strings in the 8 languages
the Mac, iPhone, Windows and Linux apps ship.

Sources, later ones winning where a key repeats:
  ../Blip/Resources/Localizable.xcstrings          (Mac)
  ../BlipMobileWidgets/Resources/Localizable.xcstrings
  ../BlipMobile/Resources/Localizable.xcstrings     (iPhone — the app Android mirrors)
  ../desktop/tools/desktop_strings.json             (Windows/Linux additions)
  tools/android_strings.json                        (Android-only wording)
Keys are the English text, as in the Apple catalogs. Run from android/:
    python3 tools/gen_strings.py
"""
import json
import pathlib
import sys

LANGS = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "zh-Hans"]
ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = ROOT.parent


def catalog(path):
    data = json.loads(path.read_text(encoding="utf-8"))["strings"]
    out = {}
    for key, entry in data.items():
        if not key or entry.get("shouldTranslate") is False:
            continue
        locs = entry.get("localizations", {})
        row = []
        for lang in LANGS:
            unit = locs.get(lang, {}).get("stringUnit", {})
            ok = unit.get("state") in ("translated", "needs_review", None)
            row.append(unit.get("value", "") if ok else "")
        if any(row):
            out[key] = row
    return out


def flat(path, required):
    data = json.loads(path.read_text(encoding="utf-8"))
    out, missing = {}, []
    for key, tr in data.items():
        if key.startswith("//"):
            continue
        row = [tr.get(lang, "") for lang in LANGS]
        if required:
            missing += [f"{key!r} → {lang}" for lang, v in zip(LANGS, row) if not v]
        out[key] = row
    if missing:
        sys.exit(f"{path.name} is missing translations:\n  " + "\n  ".join(missing))
    return out


table = {}
table.update(catalog(REPO / "Blip/Resources/Localizable.xcstrings"))
table.update(catalog(REPO / "BlipMobileWidgets/Resources/Localizable.xcstrings"))
table.update(catalog(REPO / "BlipMobile/Resources/Localizable.xcstrings"))
table.update(flat(REPO / "desktop/tools/desktop_strings.json", required=False))
table.update(flat(ROOT / "tools/android_strings.json", required=True))

out = ROOT / "app/src/main/assets/strings.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(
    json.dumps({"langs": LANGS, "strings": dict(sorted(table.items()))}, ensure_ascii=False, indent=0) + "\n",
    encoding="utf-8",
)
print(f"{len(table)} strings")
