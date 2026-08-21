# fcp-palette

A Spotlight-style command palette for Final Cut Pro.

**⇧Space** → type → **Return**. Any title, generator, video effect, audio
effect, or saved effect preset lands at the playhead, without touching a
sidebar or a browser search field.

It's a small, self-contained replacement for the part of
[CommandPost](https://commandpost.io) most people actually use — the Search
Console. One Lua file, one Python scanner, no app to install.

<!-- TODO: demo.gif — ⇧Space, type "gauss", Return, effect lands on the clip -->

## Why

Reaching a browser item in Final Cut means: find the right browser, click the
right sidebar category, click into the search field, type, then drag or
double-click the result. Every time. The palette collapses all of that into a
hotkey and a few characters, fuzzy-matched across *everything* installed at
once — built-ins, third-party packs, and your own saved presets in the same
list.

## Requirements

- macOS with **Final Cut Pro** — developed and verified against **12.3**
  (English UI: the scanner reads FCP's English strings tables, so other
  languages will produce wrong names)
- [Hammerspoon](https://www.hammerspoon.org) with **Accessibility** permission
  granted (System Settings → Privacy & Security → Accessibility)
- Python 3 (ships with macOS; only used to build the catalog)

## Install

```bash
git clone https://github.com/tyteachestech/fcp-palette.git ~/fcp-palette
cd ~/fcp-palette
python3 build_catalog.py
```

Then add two lines to `~/.hammerspoon/init.lua`:

```lua
package.path = package.path .. ";" .. os.getenv("HOME") .. "/fcp-palette/?.lua"
fcpPalette = require("fcp_palette").start()
```

Reload Hammerspoon. The module finds its own files relative to itself, so
clone it wherever you like — just point `package.path` at that directory.

`build_catalog.py` scans your installed plugins and writes `catalog.lua` next
to the module. It takes a few seconds and prints how many items it found.

## Use

- **⇧Space** (Final Cut frontmost) → fuzzy-search everything → **Return** to
  apply.
  - Titles and generators connect at the playhead, above the primary
    storyline.
  - Effects apply to the selected clip, or the topmost clip under the playhead
    if nothing is selected.
  - The last two rows fall back to raw-searching FCP's own browsers, for when
    the catalog misses something.
- **⌘1–⌘9** applies one of the first nine rows directly (Hammerspoon's own
  chooser shortcut — the badge column it draws is always visible and can't be
  hidden).
- **Esc**, **⌘W**, the **✕**, or a click outside closes it.
- Recently used items float to the top (frecency).
- Every apply is verified. If it didn't land, you get a notification — it
  never fails silently.

## Maintenance

| Task | How |
|---|---|
| Installed new plugins | Nothing — path watchers rebuild the catalog automatically (~15 s after the install settles) |
| Force a rebuild | `hs -c 'fcpPalette.refreshCatalog()'` or `python3 build_catalog.py` |
| Change the hotkey | `M.config.hotkey` at the top of `fcp_palette.lua` |
| Debug a flow | `fcpPalette.config.debug = true` → `/tmp/fcp-palette.log` |
| Apply from a script | `fcpPalette.apply("Video Effect", "Gaussian")` |
| Export the open timeline as FCPXML | `fcpPalette.exportXML("/abs/path/no-ext")` — see below |
| Restore items auto-hidden as not-in-browser | `hs -c 'fcpPalette.resetMissing()'` |

## Exporting the open timeline as FCPXML

Final Cut has no export API, so getting the current timeline out of it means a
human clicking through *File → Export XML…* and a save dialog. The palette can
do that for you:

```lua
fcpPalette.exportXML("/Users/you/exports/my-cut", {resultFile = "/tmp/x.json"})
```

The path is **absolute and has no extension** — Final Cut appends its own (on
12.x that's a `.fcpxmld` package containing `Info.fcpxml`, FCPXML version
1.14). It must not already exist; the "Replace?" prompt is reported as an
error rather than answered, so pass a unique name.

It makes Final Cut frontmost, targets the **timeline's** project (not whatever
is selected in a browser), drives the save panel, waits for the file to finish
being written, and hands the screen back to whatever app you were using.

Read the outcome from the **result file**, not from the command's output — the
`hs` command-line tool's reply channel is unreliable for anything slow, so run
it in the background and poll:

```bash
hs -t 45 -c 'fcpPalette.exportXML("/Users/you/exports/my-cut")' >/dev/null 2>&1 &
# …then poll /tmp/fcp-palette-export.json (override with opts.resultFile)
```

`-t 45` matters: the tool's own timeout defaults to **four seconds**, which is
shorter than the export takes.

```json
{"ok": true, "path": "…/my-cut.fcpxmld/Info.fcpxml", "project": "My Cut",
 "bytes": 101917, "ms": 4441}
```

A failure writes `{"ok": false, "error": "…"}` and posts a notification. A
typical run takes 4–8 seconds and gives up after 30.

## How it works

FCP has no scripting API, so everything runs through macOS accessibility:
menu commands, keyboard focus, and stable AX identifiers — **never screen
positions**, so any workspace layout works.

The searchable list comes from disk rather than the browser, which is what
lets one query span every category at once. `build_catalog.py` reads Motion
template folders (user, system, and three roots inside the FCP bundle), Logic
audio effect presets, FCP's own audio effect bundles, Audio Units via
`auval`, and your saved effect presets.

It drops templates whose `<template>` `<flags>` carry the obsolete bit —
Final Cut's own hide marker, and how some plugin stores ship thousands of
placeholder folders for packs you haven't bought — and skips the bundle's
unlisted iMovie "Simple" titles. So the palette offers what the browser
actually shows. Anything that slips through gets tombstoned at runtime the
first time a verified search turns up nothing.

[SPEC.md](SPEC.md) has the full design and, more usefully, the **falsified
assumptions** — the AX behaviours that look like they should work and don't.
Read it before changing apply logic.

## Status

Titles, generators, video effects, audio effects, and effect presets are
wired and verified. **Transitions are not** — they need nearest-edit targeting
and a guard for the no-handles modal (Phase 2 in the spec).

Every mechanic is verified against **Final Cut Pro 12.3**. Nearby versions will
probably work — nothing here depends on a version number, only on the shape of
the accessibility tree — but they're untested. Apple can move that tree in any
update; when something breaks, set `fcpPalette.config.debug = true` and the log
will show which step lost the thread.

## Contributing

Issues and PRs welcome. If you're changing how an item gets applied, please
keep the fail-loud rule: an apply that can silently do the *wrong* thing is a
regression no matter how much simpler it makes the code. `AGENTS.md` holds the
working rules (it's written for AI coding assistants, but they apply to
humans too).

## Credits

The plugin-scanning approach — the obsolete `<flags>` bit, `<theme>` group
names, the unlisted "Simple" category, the audio effect bundles — is derived
from [CommandPost](https://github.com/CommandPost/CommandPost)'s scanner by
LateNite Films, Chris Hocking and David Peterson. CommandPost is the
full-featured original; this is a deliberately smaller tool that does one
thing.

## License

MIT — see [LICENSE](LICENSE).
