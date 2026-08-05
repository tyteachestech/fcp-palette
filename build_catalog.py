#!/usr/bin/env python3
"""Build catalog.json for fcp-palette from on-disk sources.

Sources (all name-accurate for an English-language install):
- User Motion templates:   ~/Movies/Motion Templates.localized/<Cat>.localized/<Set>/<Item>/
- Built-in templates:      FCP bundle MotionEffect.fxp Templates.localized (same layout)
- Logic audio effects:     FCP bundle EDELPresets/Plug-In Settings/<Name>/
- Audio Units:             `auval -s aufx` ("Vendor: Name" lines)
- Tyler's effect presets:  ~/Library/Application Support/ProApps/Effects Presets/*.effectsPreset
"""
import html
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
# FCP-native audio effects (Alien, Doubler, Cathedral, ...) live as
# Name.Category.audio.effectBundle files, display names in the strings table.
EFFECT_BUNDLES = (
    "/Applications/Final Cut Pro.app/Contents/Frameworks/Flexo.framework/"
    "Resources/Effect Bundles"
)
EFFECT_BUNDLE_STRINGS = (
    "/Applications/Final Cut Pro.app/Contents/Frameworks/Flexo.framework/"
    "Resources/en.lproj/FFEffectBundleLocalizable.strings"
)
# Third-party installers may also drop templates at the system level.
SYSTEM_TEMPLATES = "/Library/Application Support/Final Cut Pro/Templates.localized"
PRESETS = os.path.join(HOME, "Library", "Application Support", "ProApps", "Effects Presets")

CATEGORY_MAP = {
    "Titles": "Title",
    "Generators": "Generator",
    "Effects": "Video Effect",
    "Transitions": "Transition",
}

def strip_localized(name):
    return name[:-len(".localized")] if name.endswith(".localized") else name

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$")

def keep_name(name):
    # UUID-named folders whose display name couldn't be resolved are
    # unsearchable in FCP's browser — showing them would offer items that
    # "don't exist".
    return (name and not name.startswith(".") and not name.startswith("_")
            and not UUID_RE.match(name))

TEMPLATE_EXTS = (".moti", ".motn", ".moef", ".motr")
OBSOLETE_FLAG = 2

def template_file(item_dir):
    for fn in os.listdir(item_dir):
        if fn.endswith(TEMPLATE_EXTS):
            return os.path.join(item_dir, fn)

def template_meta(path):
    """(theme, is_obsolete) from the <template> element of a Motion template.
    FCP's browser hides templates whose flags carry the obsolete bit — offering
    them would suggest items that "don't exist" (this is the on-disk marker
    behind e.g. FCB's hidden "Pro Zooms +" theme). The <theme> element is the
    browser's real group name, truer than the folder name."""
    theme, flags, in_template = None, None, False
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                line = line.rstrip()
                if not in_template and line.endswith("<template>"):
                    in_template = True
                if in_template:
                    if theme is None:
                        m = re.search(r"<theme>(.+)</theme>", line)
                        if m:
                            theme = html.unescape(m.group(1))
                    if flags is None:
                        m = re.search(r"<flags>(\d+)</flags>", line)
                        if m:
                            flags = int(m.group(1))
                    if line.endswith("</template>"):
                        break
    except OSError:
        pass
    return theme, bool((flags or 0) & OBSOLETE_FLAG)

def thumb_for(item_dir):
    """The template's own browser thumbnail (every Motion template dir ships
    small.png/large.png). Compiled effects have none — FCP renders those."""
    for fn in ("small.png", "large.png"):
        p = os.path.join(item_dir, fn)
        if os.path.isfile(p):
            return p

def display_name(parent, entry):
    """A folder's Finder display name. Third-party sets/items are often
    UUID-named on disk, with the browser name in .localized/<lang>.strings
    ({"<UUID>": "Dynamic Title 03"})."""
    base = strip_localized(entry)
    loc = os.path.join(parent, entry, ".localized")
    if os.path.isdir(loc):
        names = ["en.strings", "English.strings"]
        try:
            names += sorted(f for f in os.listdir(loc)
                            if f.endswith(".strings") and f not in names)
        except OSError:
            pass
        for fn in names:
            path = os.path.join(loc, fn)
            if not os.path.isfile(path):
                continue
            try:
                out = subprocess.run(
                    ["plutil", "-convert", "json", "-o", "-", path],
                    capture_output=True, check=True)
                mapped = json.loads(out.stdout).get(base)
                if mapped:
                    return mapped
            except Exception:
                continue
    return base

def add_template_item(items, seen, category, name, fallback_set, item_dir):
    tf = template_file(item_dir)
    if not tf:
        return False
    theme, obsolete = template_meta(tf)
    if obsolete:
        return True  # a template dir, but FCP's browser hides it
    key = (category, name.lower())
    if key not in seen:
        seen.add(key)
        item = {"name": name, "category": category, "set": theme or fallback_set}
        t = thumb_for(item_dir)
        if t:
            item["thumb"] = t
        items.append(item)
    return True

def scan_templates(root, items, seen, skip_categories=()):
    for folder, category in CATEGORY_MAP.items():
        for suffix in (folder + ".localized", folder):
            base = os.path.join(root, suffix)
            if not os.path.isdir(base):
                continue
            for set_entry in sorted(os.listdir(base)):
                set_dir = os.path.join(base, set_entry)
                if not os.path.isdir(set_dir):
                    continue
                if strip_localized(set_entry) in skip_categories:
                    continue
                set_name = display_name(base, set_entry)
                for item_entry in sorted(os.listdir(set_dir)):
                    item_dir = os.path.join(set_dir, item_entry)
                    if not os.path.isdir(item_dir):
                        continue
                    name = display_name(set_dir, item_entry)
                    # some sets nest one more level (Theme/Item); a template dir
                    # contains a .moti/.motn/.moef/.motr file
                    if not keep_name(name):
                        continue
                    if not add_template_item(items, seen, category, name,
                                             set_name, item_dir):
                        for sub in sorted(os.listdir(item_dir)):
                            sub_dir = os.path.join(item_dir, sub)
                            sub_name = display_name(item_dir, sub)
                            if keep_name(sub_name) and os.path.isdir(sub_dir):
                                add_template_item(items, seen, category,
                                                  sub_name, name, sub_dir)
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

def scan_effect_bundles(items, seen):
    """FCP-native audio effects (Alien, Doubler, Cathedral, ...) — not Audio
    Units, not EDEL presets; absent from every other source."""
    if not os.path.isdir(EFFECT_BUNDLES):
        return
    table = {}
    try:
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-",
                              EFFECT_BUNDLE_STRINGS],
                             capture_output=True, timeout=30)
        table = json.loads(out.stdout)
    except Exception as e:
        print(f"effect bundle strings skipped: {e}", file=sys.stderr)
    for entry in sorted(os.listdir(EFFECT_BUNDLES)):
        m = re.match(r"^([^.]+)\.([^.]+)\.audio\.effectBundle$", entry)
        if not m:
            continue
        name = table.get(m.group(1)) or m.group(1)
        key = ("Audio Effect", name.lower())
        if key not in seen:
            seen.add(key)
            items.append({"name": name, "category": "Audio Effect",
                          "set": m.group(2)})

def main():
    items, seen = [], set()
    scan_templates(USER_TEMPLATES, items, seen)
    scan_templates(SYSTEM_TEMPLATES, items, seen)
    for root in BUNDLE_TEMPLATE_ROOTS:
        # The bundle's "Simple" category holds unlisted iMovie titles that
        # FCP's own browser never shows.
        scan_templates(root, items, seen, skip_categories=("Simple",))
    scan_internal_filters(items, seen)
    scan_effect_bundles(items, seen)

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

    # Also emit a Lua literal: hs.json.decode takes tens of seconds on a file
    # this size (verified 2026-08-05), dofile takes milliseconds.
    def lq(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') \
                      .replace("\n", "\\n").replace("\r", "\\r") + '"'
    lua_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog.lua")
    with open(lua_path, "w") as fh:
        fh.write("-- generated by build_catalog.py; do not edit\nreturn {\n")
        for it in items:
            set_part = f",set={lq(it['set'])}" if it.get("set") else ""
            thumb_part = f",thumb={lq(it['thumb'])}" if it.get("thumb") else ""
            fh.write(f"{{category={lq(it['category'])},name={lq(it['name'])}"
                     f"{set_part}{thumb_part}}},\n")
        fh.write("}\n")
    counts = {}
    for it in items:
        counts[it["category"]] = counts.get(it["category"], 0) + 1
    print(f"{len(items)} items -> {out_path}")
    for cat, n in sorted(counts.items()):
        print(f"  {cat}: {n}")

if __name__ == "__main__":
    main()
