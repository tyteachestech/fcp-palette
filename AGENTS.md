# fcp-palette — agent guidance

Hammerspoon command palette for Final Cut Pro (⌥Space → type → Return applies
titles/generators/effects at the playhead). Read [SPEC.md](SPEC.md) before
changing anything — it records the verified AX mechanics and, critically, the
falsified assumptions (the `C` key, browser-side verification, filesystem-only
catalogs). Don't re-derive those.

Working rules:

- **Never locate FCP UI by screen position.** Menu commands + focused element
  + stable AX identifiers only. Frames are read fresh immediately before any
  click (display topology changes mid-session are real).
- **Every apply must stay fail-loud**: verified typing, occlusion check,
  undo-title change. A change that can apply the *wrong* item silently is a
  regression regardless of how much it simplifies.
- Test against real catalog names (`catalog.json`), never guessed ones.
- Debugging: `fcpPalette.config.debug = true` logs to `/tmp/fcp-palette.log`.
  The `hs` CLI reply channel can wedge while the Lua side completes — log to a
  file and treat IPC timeouts as cosmetic.
- Runtime state (`catalog.json`, `frecency.json`) stays git-ignored.
