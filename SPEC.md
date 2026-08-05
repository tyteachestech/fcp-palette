# fcp-palette — Spotlight-style command palette for Final Cut Pro

One global hotkey opens a fuzzy-search palette over Final Cut's **Titles,
Generators, Video Effects, Audio Effects, and Transitions**; picking an item
applies it at the playhead. It replaces CommandPost's Search Console with
something lighter and fully ours.

## The problem in one sentence

Reaching any FCP browser item today means mousing through sidebars and typing
into per-browser search fields; the palette collapses that to
*hotkey → type → Return*.

## Vehicle

**Hammerspoon.** `hs.chooser` is the palette (built-in fuzzy filtering over
`text` + `subText`), `hs.axuielement` + simulated keystrokes drive FCP —
the same control plane CommandPost uses, since FCP has no scripting API.
The repo holds a Lua module; install = one `require` line in
`~/.hammerspoon/init.lua`.

## UX

- Global hotkey (default **⌥Space**, configurable at the top of the module)
  opens the chooser. Only active/useful when FCP is running.
- One flat result list across all five categories. The category is the row's
  `subText`, so typing "low pass audio" or "dissolve transition" narrows
  naturally — no prefix syntax to learn.
- Results are pre-sorted by **frecency** (a small JSON usage log: use count +
  last-used, ~15 lines of scoring). `hs.chooser` preserves array order among
  equal matches, so pre-sorting is the whole ranking system — no custom
  matcher.
- A permanent last row: **"Search FCP for '<typed text>'"** — bypasses the
  catalog and types the raw string into the appropriate FCP browser. This is
  the safety valve that makes a stale catalog cost one extra keystroke instead
  of a dead end.
- On failure (no match found in FCP's browser, no clip to target), show an
  `hs.notify` with the reason — never fail silently.

## Targeting semantics

| Category | Target | Mechanic |
|---|---|---|
| Titles, Generators | Playhead, connected **above the primary storyline** | Select item in sidebar browser → **Q** (Connect to Primary Storyline) |
| Video / Audio Effects | Selected clip; if nothing selected, the clip under the playhead | Focus timeline → if selection empty press **C** (Select Clip) → apply from Effects browser |
| Transitions (Phase 2) | The **explicitly targeted edit point** nearest the playhead | See Phase 2 — no clip-selection fallback (that applies to *both* ends, a different edit than asked for) |

Notes that make "at the playhead" actually true:

- **Skimmer beats playhead.** FCP edit commands act at the skimmer when
  skimming is on and the pointer is over the timeline. Before applying:
  ensure the pointer is parked outside the timeline (move it to the palette's
  own screen position, which it naturally is after a click — verify in spike;
  fall back to toggling skimming **S** off/on around the operation).
- Q connects above the primary storyline in the **lowest free lane** — which
  is the topmost visible layer in the normal case. Good enough; we do not
  chase "highest occupied lane + 1".
- Audio effect onto a clip with no audio, or effect apply with no selection,
  is a **silent no-op** in FCP — so selection is a hard precondition checked
  before applying, with a notification when it can't be met.

## Catalog

- Built by AX-scraping FCP's sidebar/browser lists into `catalog.json`
  (name, category, browser path). Display names must come from FCP's own UI —
  built-ins live inside the app bundle with localized names and audio effects
  include system Audio Units, so no filesystem scan can produce the list FCP
  actually shows.
- FCP's browsers are virtualized collection views (AX exposes only visible
  rows), so a full scrape scroll-steps through each list. This is the most
  fragile piece — which is why the palette never *depends* on it: the
  raw-search fallback row works with an empty catalog.
- **Manual refresh only** (`fcpPalette.refreshCatalog()` / a chooser row).
  No mtime watching, no version triggers — third-party content installs to
  at least three different locations, so no watch list would be complete, and
  staleness already costs only one keystroke.

## Apply-sequence robustness rules (every category)

1. **Clear the browser search field first** — FCP retains the previous query;
   typing into a dirty field applies the wrong item while looking successful.
   Send real keystrokes (⌘A, Delete, then the name); setting `AXValue`
   directly often doesn't fire the filter.
2. **Verify before committing** — read back the first result's AX title and
   compare to the intended name; mismatch → abort + notify instead of
   applying the wrong thing.
3. **Restore state** — return browser panels to their prior open/closed
   state and put focus back on the timeline, so the next spacebar plays
   instead of typing into a search field.

## Phases

### Phase 0 — spike (do first, ~an hour of manual poking in FCP + AX inspector)

Settle the facts the whole design rests on:

1. Skimmer vs playhead: where does Q land when the palette had focus? Does
   pointer position after the chooser closes keep the skimmer out of play?
2. **C** (Select Clip): confirmed binding + which clip it picks with
   connected clips present (primary vs topmost under playhead).
3. Search-field typing: does keystroke-typing into the Titles sidebar and
   Effects browser search filter reliably? Can the field be cleared with
   ⌘A+Delete?
4. Q from browser selection: does a selected title/generator in the browser
   connect at the playhead?
5. Effects apply: does Return (or double-click via AX press) on a browser
   result apply to the selected clip?

### Phase 1 — palette + titles/generators + effects

Hotkey, chooser, frecency, apply sequences for three categories, raw-search
fallback row, failure notifications. Catalog may start as whatever a simple
single-pass scrape captures — the fallback row covers gaps.

### Phase 1.5 — full catalog scrape

Scroll-stepped scrape with dedup for complete coverage of all lists +
`refreshCatalog`.

### Phase 2 — transitions

Nearest-edit-point targeting. Open questions to resolve here, not before:
how to select the edit point nearest the playhead from AX/keyboard (candidate:
Up/Down arrow moves playhead to nearest edit, then a select-edit command), and
guarding the "not enough extra media" modal (detect + dismiss + notify — an
unguarded modal hangs the AX sequence). Until Phase 2 lands, transition rows
are hidden from the palette rather than half-working.

## What was cut (and why)

- **Category prefix filters** (`t:`, `fx:`) — chooser already matches the
  category via `subText`; unrequested syntax.
- **Custom fuzzy matcher / queryChangedCallback scoring** — re-implements the
  chooser; pre-sorted choices achieve ranking.
- **Catalog auto-invalidation** (mtime/version watchers) — no complete watch
  list exists, and the fallback row makes staleness nearly free.
- **Transition clip-selection fallback** — applies to both ends of the clip:
  a different edit than the user asked for, silently.
- **Filesystem scan instead of AX scrape** — considered and rejected: disk
  walk can't reproduce FCP's displayed, localized names.

## Repo conventions

Self-contained git repo (workspace convention). Media never lives here.
`catalog.json` and the frecency log are runtime state — git-ignored.
