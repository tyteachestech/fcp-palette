# fcp-palette — Spotlight-style command palette for Final Cut Pro

One hotkey (**⇧Space**, enabled only while FCP is frontmost — globally it
would fire mid-typing in every other app) opens a fuzzy-search palette over
Final Cut's
**Titles, Generators, Video Effects, Audio Effects, and Effect Presets**;
picking an item applies it at the playhead. A lighter, fully-owned replacement
for CommandPost's Search Console. Transitions are designed but not yet wired
(Phase 2 below).

## The problem in one sentence

Reaching any FCP browser item means mousing through sidebars and typing into
per-browser search fields; the palette collapses that to *hotkey → type →
Return*.

## Vehicle

**Hammerspoon.** `hs.chooser` is the palette; `hs.axuielement` + synthetic
keystrokes/clicks drive FCP — the same control plane CommandPost uses, since
FCP has no scripting API. The repo holds one Lua module; install is two lines
in `~/.hammerspoon/init.lua` (see README).

## How FCP is driven (all verified on FCP 11, 2026-08-05)

Workspace-independence rule: **locate by structure, never by screen position.**
Three anchors:

1. **Menu commands** — *Window → Go To → Titles and Generators / Timeline*,
   *Window → Show in Workspace → Effects* (ticked state readable). These work
   wherever the panels live. (There is no *Go To → Effects*.)
2. **Keyboard focus** — after a Go To command, FCP moves focus into the target:
   *Titles and Generators* focuses the browser **search field** directly
   (`editor/browserMedia/search/textField`); *Timeline* focuses the timeline
   `AXLayoutArea`. The focused element hands us the right subtree with zero
   tree-walking. The Effects browser doesn't take focus when shown, so its
   field (`editor/browserContent/search/textField`) is found from the
   timeline's ancestor split (default workspaces) with a shallow per-window
   scan as fallback (floating workspaces).
3. **Stable AX identifiers** — FCP tags its search groups
   (`editor/browserMedia/search/…`, `editor/browserContent/search/…`,
   including per-field clear buttons pressed via `AXPress`).

Hard-won AX facts the design rests on:

- **Browser result grids ARE readable** (FCP 11): the results `AXGrid`'s
  children are one `AXImage` per item, each with the item name as `AXTitle`
  and a real `AXFrame`. This is what makes the palette click the *named* cell
  instead of guessing a y-offset, and lets "FCP has no such item" be detected
  from an empty result set. **The grid holds the previous, unfiltered contents
  for ~250 ms after typing**, and that stale list contains the wanted name
  too — so a match must never be read until the child count has changed and
  then held still (`waitForCell`); reading early clicks a stale position.
- **Writing the grid's `AXSelectedChildren` does not work**: the write is
  accepted and reads back, and *Connect to Primary Storyline* even reads as
  enabled, but the connect then does nothing — FCP's internal browser
  selection is only driven by a real click. Falsified 2026-08-05.
- **`AXEnabled` on FCP's menu items goes stale**: it can still read `true`
  from a previous state milliseconds after a click that hasn't registered, so
  it is a hint, never proof.
- **The sidebar lists ARE readable**: the T&G sidebar is an `AXOutline` whose
  root rows ("Titles"/"Generators") are selected by writing `AXSelectedRows`;
  the Effects sidebar is an `AXTable` (rows enumerable by name; its
  `AXSelectedRows` is NOT writable — scroll-to-top + click instead). Effects
  row 1, **"All Video & Audio"**, makes one search span every effect + preset.
- **Timeline items are readable**: clips are `AXLayoutItem`s with
  `AXDescription` of the form `Type:Name` (`Title:Basic Title`); the playhead
  is an `AXValueIndicator`; the layout area's `AXSelectedChildren` is
  **writable** — this is how clips get targeted.
- **The `C` (Select Clip) key is pointer/skimmer-driven** — it does nothing
  with the pointer parked outside the timeline. Falsified as a targeting
  mechanism; `AXSelectedChildren` writes replace it (and implement true
  topmost-lane-first targeting).
- **Skimmer beats playhead** for edit commands, so the pointer is parked on
  FCP's toolbar before any connect.
- **Blind AX tree searches stall** (the timeline subtree is enormous, and FCP
  attribute reads flake right after keystrokes) — every lookup is scoped and
  retry-wrapped.

## Targeting semantics

| Category | Target | Mechanic |
|---|---|---|
| Title, Generator | Playhead, connected **above the primary storyline** (lowest free lane = topmost in the normal case) | Select sidebar root → type exact name → wait for the grid to re-filter → click the cell whose `AXTitle` matches → *Edit → Connect to Primary Storyline* |
| Video/Audio Effect, Effect Preset | Selected clip; else the **topmost clip under the playhead** | Ensure selection via `AXSelectedChildren` write → type exact name in Effects search (scope "All Video & Audio") → double-click the matching cell |

## Verification & fail-loud rules (every apply)

- **Frontmost gate**: keystrokes go to the frontmost app, so FCP is
  re-activated (with retry) before any typing. (Found the hard way: a floating
  Claude window was eating keystrokes.)
- **Occlusion check**: before clicking, `systemElementAtPosition` must resolve
  to FCP's pid; if another app's window covers the click point, the palette
  notifies *which* window and aborts.
- **Typing is verified** (`AXValue` readback, 3 attempts) — a silent typing
  failure would otherwise apply the first cell of an *unfiltered* grid: the
  wrong-item failure mode.
- **Undo-title verification**: the *Edit → Undo* menu title (read via
  `AXMenuBar`) must become the expected one after the apply ("Undo Connect to
  Primary Storyline", "Undo Add Video Effect").
- **Repeat applies need a second signal.** The undo title only proves an apply
  when it *changes*, so connecting two titles in a row leaves it identical and
  a change-test calls a landed clip a failure — which invites a re-apply and
  silently duplicates clips (this bit hard on 2026-08-05). The palette
  therefore picks its verification before touching anything: if the undo title
  *already* reads "Undo Connect to Primary Storyline", it counts the timeline
  clips whose `AXDescription` is `Title:<name>` before and after and requires
  the count to rise — a bounded, position-deduped scan (the AX tree reaches
  each clip by several paths), ~5 ms, run only on a repeat. Effects have no
  equivalent count (nothing observable changes on the clip), so a repeat there
  is reported honestly as *couldn't confirm*, quoting the undo title it saw,
  rather than as a failure.
- **Exact-cell clicking**: the click lands on the center of the grid cell
  whose `AXTitle` matches the request, so a section header rendering above the
  results cannot shift the target (this replaced a 45/75/105 pt offset ladder).
- **Cleanup**: search fields are cleared (clear-button `AXPress`) and focus
  returns to the timeline, so the next spacebar plays instead of typing.

## Catalog (`build_catalog.py` → `catalog.json`)

Disk-scanned display names (English install), deduped per category:

| Source | Yields |
|---|---|
| `~/Movies/Motion Templates.localized/{Titles,Generators,Effects,Transitions}.localized` | All third-party/user templates |
| `/Library/Application Support/Final Cut Pro/Templates.localized` | System-level third-party templates (CineMatch, Spherico, …) |
| FCP bundle `MotionEffect.fxp …/{Templates,PETemplates,METemplates}.localized` | Built-in Motion templates (PE holds most stock titles/generators/transitions, e.g. "Basic Title"). The bundle's "Simple" category is skipped — unlisted iMovie titles FCP never shows |
| FCP bundle `InternalFiltersXPC` `Localizable.strings` keys `*::Filter Name` | Built-in compiled video effects |
| FCP bundle `Flexo …/EDELPresets/Plug-In Settings/` folder names | Logic audio effects (Channel EQ, Compressor, …) |
| FCP bundle `Flexo …/Resources/Effect Bundles/*.audio.effectBundle` | FCP-native audio effects (Alien, Doubler, Cathedral, …), names via `FFEffectBundleLocalizable.strings` |
| `auval -s aufx` | Apple + third-party Audio Units |
| `~/Library/Application Support/ProApps/Effects Presets/*.effectsPreset` | Tyler's saved effect presets |

**Obsolete-flag filter** (the disk marker behind "items that don't exist",
learned from CommandPost's scanner): every Motion template's `<template>`
element carries `<flags>`; bit 2 marks it obsolete/hidden — FCP's browser
never shows it. This is how mExt/motionVFX-style stores ship thousands of
placeholder templates (uninstalled store items) alongside installed ones, and
why FCB's "+"-theme titles were invisible. The scan parses each template's
flags and drops obsolete ones (~10k placeholder phantoms on this machine),
and reads the `<theme>` element as the item's set name (the browser's real
group) with the folder name as fallback. Runtime tombstoning (below) stays as
the backstop for anything the flag doesn't predict (e.g. renamed built-ins).

The palette loads the catalog from a generated **`catalog.lua`** via `dofile`
(milliseconds); `hs.json.decode` on the equivalent 1.7 MB JSON freezes
Hammerspoon's main thread for tens of seconds (verified 2026-08-05 — it also
masqueraded as an "IPC wedge"). `build_catalog.py` writes both files; the JSON
stays as the tool-agnostic record.

~10k items on this machine. The catalog self-refreshes: `hs.pathwatcher`s on
the user/system template roots and the effect-presets folder trigger a
debounced (15 s) background `build_catalog.py` run when template/preset files
change, so plugin installs and newly saved presets appear without manual
action (`fcpPalette.refreshCatalog()` still works for a forced rebuild). A few
built-ins may carry renamed browser labels (e.g. strings say "Gaussian Blur",
browser says "Gaussian" — the template scan has the right one, but the strings
lane can drift): those fail loud at apply and stay reachable via raw search.

## Palette UX

- A title apply runs ~2.5 s hotkey-to-notification. What that budget is spent
  on: FCP's browser filtering (~0.5 s, observed not slept through), its own
  edit + menu latency (~1 s), and the AX round-trips around them. Waits poll at
  30 ms because a slower poll used to add up to a second of pure overshoot
  across the half-dozen waits in one apply, and the outcome notification fires
  before the field-clearing cleanup rather than after it.
- One flat list, frecency-pre-sorted (JSON usage log: count + 7-day recency
  boost), category + set as each row's subtext, and the template's own browser
  thumbnail (`small.png` inside each Motion template dir) as the row image —
  loaded lazily for displayed rows only and cached; compiled video/audio
  effects and presets have no on-disk thumbnail (FCP renders those live), so
  their rows are text-only. A ~20-line subsequence filter
  runs in `queryChangedCallback` (needed because the fallback rows below
  require the live query, which disables the chooser's built-in filtering);
  substring matches rank above scattered ones; results cap at 50.
- Two permanent fallback rows: **"Search Titles & Generators for '…'"** and
  **"Search Effects for '…'"** — bypass the catalog, filter the real browser
  to the raw text, and leave FCP showing the results for a manual pick.
- **Placement**: the palette opens on the screen of FCP's focused window
  (mouse screen as fallback), ~680px wide, Spotlight position. `hs.chooser`
  always opens on the primary screen and sizes off it, so the panel is
  repositioned via an `AXPosition` write on show, and `chooser:width()` is fed
  a primary-screen percentage computed for the target screen.
- **Dismissal**: Esc (chooser-native), ⌘W, an ✕ button top-right, or clicking
  anywhere outside the palette (the click still lands where aimed,
  Spotlight-style). Click-off uses the panel's AX frame (Hammerspoon's window
  titled "Chooser") with pid-under-point as fallback; the ✕ is an `hs.canvas`
  overlay positioned from that same frame, read fresh each show.
- **⌘1–⌘9 quick-pick** is `hs.chooser`'s own: it draws the badges on the first
  nine rows and handles the shortcut. The badges are always visible — the
  column is hardcoded in Hammerspoon's chooser cell, exposed through no API and
  read-only over AX (`AXValue` on those labels is not settable), so it can only
  be changed by replacing `hs.chooser` with a custom palette surface.
- Hammerspoon gotcha baked in: `hs.timer.doAfter` handles must be anchored in
  module-level variables — unreferenced timers are GC'd before firing.
- **Self-healing catalog**: the obsolete-flag filter (Catalog section) removes
  browser-hidden templates at scan time, but not everything is predictable
  from disk (renamed built-ins; any hiding rule the flag doesn't cover). When
  a verified-typed search selects nothing, the item is tombstoned in
  `missing.json` and never offered again; `fcpPalette.resetMissing()` clears
  the list (e.g. after a plugin update).
- All failures surface as notifications with the reason; nothing fails silent.
- Scripting surface: `fcpPalette.apply(category, name)`, `.show()`,
  `.refreshCatalog()`, `.config.debug = true` (logs to `/tmp/fcp-palette.log`).

## Known limitations (accepted for v1)

- **Fuzzy-match fallback**: cells carry their names, so an exact title match is
  picked whenever FCP's search returns one — the old "first result might be a
  prefix sibling" hazard is gone for catalog names that exist verbatim. When no
  cell matches exactly (e.g. a built-in renamed in the browser: catalog
  "Gaussian Blur" vs browser "Gaussian"), the palette still takes FCP's best
  match, and that pick is unverified.
- Audio effect onto a clip with no audio is FCP-silent → surfaced as "nothing
  applied", which is correct but can't name the cause.
- English display names assumed throughout.
- Timeline scans cap at 800 AX visits; enormous timelines may miss the
  playhead-clip fallback (selection-first targeting is unaffected).

## Phases

- **Phase 0 — spike**: done (all facts above).
- **Phase 1 — palette + titles/generators/effects/presets**: done, verified
  end-to-end (hotkey → type → Return → clip lands, plus every failure path).
- **Phase 1.5 — catalog polish**: done — UUID-named third-party sets/items
  resolve through their `.localized/<lang>.strings` (`{"<UUID>": "Dynamic
  Title 03"}`); unresolvable UUID names are dropped (unsearchable in the
  browser); template thumbnails recorded per item. Remaining: reconcile
  renamed built-ins (strings-lane names like "Gaussian Blur" vs browser
  "Gaussian").
- **Phase 2 — transitions**: nearest-edit-point targeting + the "not enough
  extra media" modal guard (an unguarded modal hangs the AX sequence).
  Catalog already scans them; rows stay hidden until this lands.
