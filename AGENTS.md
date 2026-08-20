# fcp-palette — agent guidance

Hammerspoon command palette for Final Cut Pro (⇧Space while FCP is frontmost →
type → Return applies titles/generators/effects at the playhead). Read
[SPEC.md](SPEC.md) before
changing anything — it records the verified AX mechanics and, critically, the
falsified assumptions (the `C` key, browser-side verification, filesystem-only
catalogs). Don't re-derive those.

## Commands

There is no build system, linter, or test suite — two source files, no
dependencies beyond Hammerspoon and macOS Python 3.

```bash
python3 build_catalog.py                          # rebuild catalog.lua (+ catalog.json record)
hs -c 'hs.reload()' >/dev/null 2>&1               # reload Hammerspoon after editing fcp_palette.lua
hs -c 'fcpPalette.refreshCatalog()' >/dev/null 2>&1   # force a catalog rebuild through the palette
hs -c 'fcpPalette.apply("Video Effect", "Gaussian")' >/dev/null 2>&1   # scripted apply (real project!)
tail -f /tmp/fcp-palette.log                      # after: hs -c 'fcpPalette.config.debug = true' …
pkill -9 -f '^hs -c'                              # kill wedged hs CLI clients (not Hammerspoon itself)
```

"Testing" means driving the real FCP app over AX — see the working rules
below; every applied item must be cleaned up and the cleanup verified.

## Architecture

Two source files, one direction of data flow:

- **`build_catalog.py`** — scans installed content on disk (Motion template
  roots, FCP bundle strings/presets, Audio Units via `auval`, saved effect
  presets) and writes **`catalog.lua`** (git-ignored, loaded via `dofile`).
  SPEC's "Catalog" section maps every source to what it yields.
- **`fcp_palette.lua`** — the whole runtime: `hs.chooser` UI, fuzzy filter,
  frecency ranking, and the AX apply pipelines. Two apply paths:
  `applyConnected` (titles/generators → connect at playhead) and `applyEffect`
  (effects/presets → selected or playhead clip); both go
  focus-the-browser-search → verified-type the exact name → wait for the grid
  to settle (`waitForCell`) → click the cell whose `AXTitle` matches →
  post-apply verification.
- Runtime state next to the module, all git-ignored: `catalog.lua` (the
  index), `frecency.json` (usage ranking), `missing.json` (tombstones for
  items a verified search couldn't find; cleared by
  `fcpPalette.resetMissing()`).
- Self-refresh: `hs.pathwatcher`s on the template/preset roots debounce 15 s,
  then re-run `build_catalog.py` in the background.

## Working rules

- **Never locate FCP UI by screen position.** Menu commands + focused element
  + stable AX identifiers only. Frames are read fresh immediately before any
  click (display topology changes mid-session are real).
- **Every apply must stay fail-loud**: verified typing, occlusion check,
  post-apply verification. A change that can apply the *wrong* item silently is
  a regression regardless of how much it simplifies.
- **Never verify an apply by "the undo title changed" alone.** Two applies of
  the same kind in a row leave it identical, so that test reports failure for
  work that landed — and the user re-applies, duplicating clips. Connects
  disambiguate by counting matching timeline clips; see SPEC.
- **Testing an apply modifies the user's real project.** Every test that
  connects or applies must delete/undo what it created and re-enumerate the
  timeline to prove it. Verify the cleanup — a "failed" apply may in fact have
  landed, and stacked duplicates hide behind each other at the same playhead
  position (dedupe timeline scans by frame x *and* y).
- Test against real catalog names (`catalog.lua`), never guessed ones.
- Row styling lives in `M.config` (`categoryBand`, `categoryColor`,
  `categoryGlyph`, `rowTintAlpha`, `rowBandHeight`, `nameFontSize`,
  `metaFontSize`, `metaTabStop`, `paletteWidth`, `visibleRows`, `compactRows`,
  `showThumbnails`) and the mouse-transparent `rowCanvas` layer. Read SPEC's
  "Row styling" section before touching it: `hs.chooser` still owns selection,
  scrolling and row geometry; the canvas only paints the live AX row frames.
  Keep the small native image fallback, update the overlay after filtering and
  scrolling, and judge changes from a full-screen capture because app-window
  capture omits Hammerspoon's separate canvas windows.

- Debugging: `fcpPalette.config.debug = true` logs to `/tmp/fcp-palette.log`.
  The `hs` CLI reply channel wedges routinely while the Lua side completes
  fine, and a waiting shell then hangs forever. So never block on `hs -c`
  output: redirect it (`hs -c '…' >/dev/null 2>&1`), have the Lua write its
  result to a file, and read that file. Clean up strays with
  `pkill -9 -f '^hs -c'` — it kills only CLI clients, not Hammerspoon.
- Runtime state (`catalog.lua`, `frecency.json`) stays git-ignored.
- Never load the catalog with `hs.json.decode` — it freezes Hammerspoon for
  tens of seconds at this file size (and masquerades as an IPC wedge). The
  palette loads the generated `catalog.lua` via `dofile`.
- Anchor every `hs.timer.doAfter` handle in a module-level variable —
  unreferenced timers are garbage-collected before they fire. Same for
  `hs.task` and `hs.pathwatcher` objects.
- The catalog scan filters templates whose `<template>` `<flags>` carry bit 2
  (obsolete) — that is FCP's on-disk hide marker (verified against
  CommandPost's scanner and FCB's hidden "+" theme). Don't "fix" a missing
  item by removing that filter; check the flags first.
