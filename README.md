# fcp-palette

Spotlight-style command palette for Final Cut Pro. **⇧Space** (while FCP is
frontmost) → type → Return applies any title, generator, video/audio effect,
or saved effect preset at the playhead. Design + verified mechanics:
[SPEC.md](SPEC.md).

## Install

Already wired on this machine. In general:

```lua
-- ~/.hammerspoon/init.lua
package.path = package.path .. ";" .. os.getenv("HOME") .. "/content/tools/fcp-palette/?.lua"
fcpPalette = require("fcp_palette").start()
```

Requires Hammerspoon with Accessibility permission, and a built `catalog.json`:

```bash
python3 build_catalog.py
```

## Use

- **⇧Space** with FCP frontmost → fuzzy-search everything, Return to apply.
  - Titles/generators connect at the playhead, above the primary storyline.
  - Effects apply to the selected clip, else the topmost clip under the
    playhead.
  - The last two rows raw-search FCP's own browser when the catalog misses.
- Hold **⌘** to see ⌘1–⌘9 badges on the first nine rows; press ⌘*n* to apply
  that row directly.
- Close with **Esc**, **⌘W**, the **✕** in the top-right, or by clicking
  anywhere outside the palette.
- Every apply is verified; failures arrive as notifications, never silently.

## Maintenance

| Task | How |
|---|---|
| New plugins installed | `hs -c 'fcpPalette.refreshCatalog()'` (or rerun `build_catalog.py`) |
| Change hotkey | `M.config.hotkey` at the top of `fcp_palette.lua` |
| Debug a flow | `fcpPalette.config.debug = true` → `/tmp/fcp-palette.log` |
| Scripted apply | `fcpPalette.apply("Video Effect", "Gaussian")` |

`catalog.json`, `catalog.lua`, and `frecency.json` are runtime state
(git-ignored). The palette loads `catalog.lua` (`hs.json.decode` freezes
Hammerspoon for tens of seconds on a file this size; `dofile` is milliseconds)
— `build_catalog.py` writes both.
