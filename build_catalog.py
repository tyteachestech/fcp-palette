#!/usr/bin/env python3
"""Build catalog.json for fcp-palette from on-disk sources.

Sources (all name-accurate for an English-language install):
- User Motion templates:   ~/Movies/Motion Templates.localized/<Cat>.localized/<Set>/<Item>/
- Built-in templates:      FCP bundle MotionEffect.fxp Templates.localized (same layout)
- Logic audio effects:     FCP bundle EDELPresets/Plug-In Settings/<Name>/
- Audio Units:             `auval -s aufx` ("Vendor: Name" lines)
- Tyler's effect presets:  ~/Library/Application Support/ProApps/Effects Presets/*.effectsPreset
"""
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
USER_TEMPLATES = os.path.join(HOME, "Movies", "Motion Templates.localized")
_FXP_RES = (
    "/Applications/Final Cut Pro.app/Contents/PlugIns/MediaProviders/"
    "MotionEffect.fxp/Contents/Resources"
)
# Built-in Motion templates are split across three roots (PE holds most of the
# stock titles/generators/transitions, e.g. "Basic Title").
BUNDLE_TEMPLATE_ROOTS = [
    os.path.join(_FXP_RES, "Templates.localized"),
    os.path.join(_FXP_RES, "PETemplates.localized"),
    os.path.join(_FXP_RES, "METemplates.localized"),
]
INTERNAL_FILTER_STRINGS = (
    "/Applications/Final Cut Pro.app/Contents/PlugIns/InternalFiltersXPC.pluginkit/"
    "Contents/Resources/en.lproj/Localizable.strings"
)
EDEL = (
    "/Applications/Final Cut Pro.app/Contents/Frameworks/Flexo.framework/"
    "Versions/A/Resources/EDELPresets/Plug-In Settings"
)
PRESETS = os.path.join(HOME, "Library", "Application Support", "ProApps", "Effects Presets")

CATEGORY_MAP = {
    "Titles": "Title",
    "Generators": "Generator",
    "Effects": "Video Effect",
    "Transitions": "Transition",
}

def strip_localized(name):
    return name[:-len(".localized")] if name.endswith(".localized") else name

def keep_name(name):
    return name and not name.startswith(".") and not name.startswith("_")

def scan_templates(root, items, seen):
    for folder, category in CATEGORY_MAP.items():
        for suffix in (folder + ".localized", folder):
            base = os.path.join(root, suffix)
            if not os.path.isdir(base):
                continue
            for set_entry in sorted(os.listdir(base)):
                set_dir = os.path.join(base, set_entry)
                if not os.path.isdir(set_dir):
                    continue
                set_name = strip_localized(set_entry)
                for item_entry in sorted(os.listdir(set_dir)):
                    item_dir = os.path.join(set_dir, item_entry)
                    if not os.path.isdir(item_dir):
                        continue
                    name = strip_localized(item_entry)
                    # some sets nest one more level (Theme/Item); a template dir
                    # contains a .moti/.motn/.moef/.motr file
                    if not keep_name(name):
                        continue
                    if any(fn.endswith((".moti", ".motn", ".moef", ".motr"))
                           for fn in os.listdir(item_dir)):
                        key = (category, name.lower())
                        if key not in seen:
                            seen.add(key)
                            items.append({"name": name, "category": category, "set": set_name})
                    else:
                        for sub in sorted(os.listdir(item_dir)):
                            sub_dir = os.path.join(item_dir, sub)
                            sub_name = strip_localized(sub)
                            if keep_name(sub_name) and os.path.isdir(sub_dir) and any(
                                fn.endswith((".moti", ".motn", ".moef", ".motr"))
                                for fn in os.listdir(sub_dir)
                            ):
                                key = (category, sub_name.lower())
                                if key not in seen:
                                    seen.add(key)
                                    items.append({"name": sub_name, "category": category,
                                                  "set": name})
            break  # matched a suffix form; don't double-scan

def scan_internal_filters(items, seen):
    """Built-in (compiled FxPlug) video effect display names from the
    internal filters' localization table: keys of form `X::Filter Name`.
    Note: a handful may have been renamed in the browser since (fails loud
    at apply time via verification, reachable via the raw-search fallback)."""
    if not os.path.isfile(INTERNAL_FILTER_STRINGS):
        return
    try:
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-",
                              INTERNAL_FILTER_STRINGS],
                             capture_output=True, text=True, timeout=30)
        table = json.loads(out.stdout)
    except Exception as e:
        print(f"internal filters scan skipped: {e}", file=sys.stderr)
        return
    for k, v in table.items():
        if k.endswith("::Filter Name") and keep_name(v):
            key = ("Video Effect", v.lower())
            if key not in seen:
                seen.add(key)
                items.append({"name": v, "category": "Video Effect", "set": "Built-in"})

def main():
    items, seen = [], set()
    scan_templates(USER_TEMPLATES, items, seen)
    for root in BUNDLE_TEMPLATE_ROOTS:
        scan_templates(root, items, seen)
    scan_internal_filters(items, seen)

    if os.path.isdir(EDEL):
        for entry in sorted(os.listdir(EDEL)):
            if os.path.isdir(os.path.join(EDEL, entry)):
                key = ("Audio Effect", entry.lower())
                if key not in seen:
                    seen.add(key)
                    items.append({"name": entry, "category": "Audio Effect", "set": "Logic"})

    try:
        out = subprocess.run(["auval", "-s", "aufx"], capture_output=True, text=True,
                             timeout=30).stdout
        for m in re.finditer(r"^\s*aufx\s+\S+\s+\S+\s+-\s+([^:]+):\s+(.+?)\s*$", out, re.M):
            vendor, name = m.group(1).strip(), m.group(2).strip()
            key = ("Audio Effect", name.lower())
            if key not in seen:
                seen.add(key)
                items.append({"name": name, "category": "Audio Effect", "set": vendor})
    except Exception as e:
        print(f"auval scan skipped: {e}", file=sys.stderr)

    if os.path.isdir(PRESETS):
        for entry in sorted(os.listdir(PRESETS)):
            if entry.endswith(".effectsPreset"):
                name = entry[:-len(".effectsPreset")]
                key = ("Effect Preset", name.lower())
                if key not in seen:
                    seen.add(key)
                    items.append({"name": name, "category": "Effect Preset", "set": "My Presets"})

    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog.json")
    with open(out_path, "w") as fh:
        json.dump(items, fh, ensure_ascii=False, indent=1)
    counts = {}
    for it in items:
        counts[it["category"]] = counts.get(it["category"], 0) + 1
    print(f"{len(items)} items -> {out_path}")
    for cat, n in sorted(counts.items()):
        print(f"  {cat}: {n}")

if __name__ == "__main__":
    main()
