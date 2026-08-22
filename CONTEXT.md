# fcp-palette

A Spotlight-style command palette for Final Cut Pro (FCP). It lets someone
search every installed title, generator, effect, and saved preset in one
list and drop the pick onto the open project with a hotkey, instead of
hunting through FCP's own sidebars and search fields.

## Language

### The palette itself

**Palette**:
The pop-up search window this tool draws, opened with ⇧Space while Final Cut
is the frontmost app. Type to filter, Return to apply the highlighted row.
_Avoid_: chooser (that's the underlying macOS component), search bar

**Apply**:
The act of taking the selected palette row and making Final Cut actually add
it to the project — connecting a title/generator, or applying an effect/
preset to a clip. Every apply is checked afterward to prove it really landed
("fail-loud"); nothing is allowed to silently do nothing or do the wrong
thing.
_Avoid_: insert, drop, add (use "apply" for the mechanism specifically)

**Fail-loud**:
The project's core promise: if an apply can't be verified as having worked,
the user is told so with a notification and a reason, rather than the tool
staying quiet and letting them assume it worked. Never trade this away for
simpler code.
_Avoid_: error handling (this is a design principle, not a code pattern)

**Catalog**:
The full list of everything the palette can offer — titles, generators,
video effects, audio effects, and effect presets — built by scanning what's
actually installed on disk. Lives in the generated file `catalog.lua`.
_Avoid_: index, database, library (Motion Template Library is a different,
FCP-owned thing)

**Frecency**:
The ranking that floats recently- and often-used items to the top of
palette results. Tracked as a usage count plus a 7-day recency boost, stored
in `frecency.json`.
_Avoid_: recent items, history

**Tombstone**:
A catalog item that got marked "don't offer this again" because a real,
verified search for it in Final Cut's browser came back empty — meaning the
disk scan thought it existed but FCP's browser doesn't actually show it.
Recorded in `missing.json`; `fcpPalette.resetMissing()` clears the list (do
this after a plugin update, in case an item comes back).
_Avoid_: blacklist, hidden item

**Fallback row**:
One of two permanent rows at the bottom of every search ("Search Titles &
Generators for '…'" and "Search Effects for '…'") that skip the catalog
entirely and hand the raw typed text to Final Cut's own browser search, for
the rare item the catalog missed.
_Avoid_: escape hatch, manual search

**Quick-pick badge**:
The ⌘1–⌘9 number badges the palette draws on its first nine result rows,
letting a number key apply that row directly instead of arrowing down and
hitting Return. A built-in feature of the underlying chooser component, not
something this tool can turn off.
_Avoid_: hotkey number, shortcut badge

**Row wash / category band**:
The tinted background color painted behind each result row to signal its
category (title, generator, video effect, audio effect) at a glance, drawn
by a transparent overlay layer this tool adds on top of the plain search
list.
_Avoid_: row color, highlight

### What gets applied, and where

**Title / Generator**:
The two FCP browser categories that apply as their own timeline clip,
positioned at the playhead and connected above the video already there
(FCP's "primary storyline" — the main row of clips). A title is text/graphic
content; a generator is a background or effect clip with no source footage
(e.g. solid colors, patterns).
_Avoid_: template (that's the underlying file format, not the applied
category)

**Video Effect / Audio Effect**:
FCP browser categories that apply as a filter stacked onto an existing
clip — the one selected, or if nothing is selected, the topmost clip sitting
under the playhead — rather than creating a new clip.
_Avoid_: filter, plugin (a plugin may supply many effects)

**Effect Preset**:
A saved, named combination of effect settings the user (or a third party)
created and saved from within Final Cut, stored on disk under FCP's own
Effects Presets folder and applied the same way as a plain effect.
_Avoid_: saved effect, custom effect

**Transition**:
An FCP browser category (the animated cut between two adjacent clips) that
the catalog scans and lists but the palette cannot yet apply — flagged in
this project as not-yet-built ("Phase 2").
_Avoid_: cut, wipe (those are specific transition types, not the category)

**Primary storyline**:
Final Cut's term (borrowed as-is) for the main row of clips a timeline is
built from. Titles and generators connect above it rather than replacing
clips in it.
_Avoid_: main track, base layer

**Playhead**:
The current position marker in Final Cut's timeline; new titles/generators
land there, and effects target whatever clip sits under it when nothing is
explicitly selected.
_Avoid_: cursor, current time

### Building and refreshing the catalog

**`build_catalog.py`**:
The Python script that scans every place Final Cut and its plugins store
content (Motion template folders, FCP's own bundle, Logic/Audio Unit effect
folders, saved presets) and writes the result as `catalog.lua`. Run by hand
or automatically in the background.
_Avoid_: scanner, indexer

**Obsolete flag**:
A marker inside a Motion template's own file (`<template><flags>`, bit 2)
that means "this template is disabled/hidden," which some plugin stores
leave on thousands of not-actually-installed placeholder templates. The
catalog scan checks this flag and drops anything marked obsolete so the
palette never offers a phantom item.
_Avoid_: hidden bit, disabled template

**Self-refresh**:
The catalog automatically rebuilding itself roughly 15 seconds after the
tool notices a change in the folders it scans (a new plugin installed, a
preset saved) — no manual rebuild needed in normal use.
_Avoid_: auto-rebuild, watch mode

### Verifying an apply actually worked

**Occlusion check**:
A safety check run right before every click: confirming no other app's
window is covering the exact screen point about to be clicked, so the
palette never blindly clicks through something else and hits the wrong
target.
_Avoid_: window check

**Undo-title verification**:
Reading Final Cut's own Edit → Undo menu label (e.g. "Undo Connect to
Primary Storyline") right after an apply to confirm Final Cut registered the
action — used because Final Cut has no direct "did that work" signal to
query.
_Avoid_: undo check

**waitForCell**:
The wait this tool performs before reading Final Cut's search results,
because the results grid keeps showing its old, unfiltered contents for
about a quarter-second after a new search is typed. Reading too early risks
clicking the wrong, stale item.
_Avoid_: debounce, settle time

**Verified typing**:
Typing a search term into Final Cut and then reading it back to confirm the
text actually landed, since a silent typing failure would otherwise apply
the first item in an unfiltered list — the wrong item — without any error.
_Avoid_: type-and-check

### Exporting the timeline

**`exportXML`**:
The scripted function (`fcpPalette.exportXML(path, opts)`) that drives Final
Cut's own File → Export XML… command and save dialog with no human clicking,
so the currently open timeline can be pulled out of Final Cut by another
tool or script.
_Avoid_: XML export (that's the general concept; this is the specific
function name)

**Result file**:
The JSON file `exportXML` writes with the outcome of an export
(`{"ok": true, "path": …}` or `{"ok": false, "error": …}`), which callers
must read instead of relying on the command-line tool's own response, since
that response channel is unreliable for anything slow.
_Avoid_: output, response

**Running breadcrumb**:
A small marker `exportXML` writes to the result file the moment it starts,
before anything that could block — so a caller can tell "export is in
progress" apart from "the request was refused and nothing ran at all."
_Avoid_: status flag, lock file

**`.fcpxmld` package**:
The folder-shaped file Final Cut actually writes when exporting XML on
version 12.x — a folder ending `.fcpxmld` containing the real `Info.fcpxml`
file inside it — rather than a single flat file.
_Avoid_: fcpxml file (only accurate for the file inside the package)

### Everything runs over accessibility, not an API

**AX** / **Accessibility**:
macOS's Accessibility system — the same feature that lets screen readers
work — which this tool uses to read Final Cut's on-screen elements and send
it clicks/keystrokes, because Final Cut has no scripting API of its own.
_Avoid_: UI automation, scripting API (FCP has none)

**Frontmost gate**:
The check-and-refocus this tool performs before typing anything, since
keystrokes go to whatever app is currently in front — if Final Cut isn't
frontmost, another app silently eats the keystrokes meant for it.
_Avoid_: focus check

**Stable identifier**:
A named tag Final Cut attaches to a specific on-screen element (e.g. the
search field, a save-dialog button) that stays the same across app restarts
and window layouts, letting this tool find that exact element reliably
instead of guessing its screen position.
_Avoid_: AX ID, selector
