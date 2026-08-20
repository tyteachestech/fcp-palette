-- fcp-palette — Spotlight-style command palette for Final Cut Pro.
-- Architecture (all mechanics verified against Final Cut Pro 12.3 by AX spike, 2026-08-05):
--   * Panels are located via menu commands + where FCP moves keyboard focus,
--     plus stable AX identifiers — never screen positions, so any window /
--     workspace layout works.
--   * Titles/Generators: sidebar root selected via AXSelectedRows on the
--     outline, exact name typed into the browser search field
--     (editor/browserMedia/search/textField), first result clicked, then
--     Edit > Connect to Primary Storyline lands it at the playhead.
--   * Effects (video/audio/presets): target clip = current timeline selection,
--     else the TOPMOST clip under the playhead (computed from AXLayoutItem
--     frames vs the playhead AXValueIndicator, selected by writing
--     AXSelectedChildren — the C key does nothing when the pointer is parked).
--     Effect applied by double-clicking the first browser result.
--   * Every apply is verified post-apply and fails loud: connects confirm by
--     the Edit > Undo title, or by counting matching timeline clips when the
--     undo title can't discriminate a repeat apply.
--   * The searchable item list comes from disk (build_catalog.py) rather than
--     the browser, so the palette can fuzzy-match everything at once instead
--     of driving FCP's own one-root-at-a-time search.
-- Wire up with:
--   package.path = package.path .. ";" .. os.getenv("HOME") .. "/path/to/fcp-palette/?.lua"
--   fcpPalette = require("fcp_palette").start()

local ax = require("hs.axuielement")
-- Preload every extension used inside callbacks: loading one lazily mid-flow
-- (e.g. hs.json on the first frecency/tombstone write) errors out of the
-- callback with only an "hs.ipc … recursing" storm as evidence.
local json = require("hs.json")
require("hs.fs")
require("hs.image")
require("hs.canvas")
require("hs.task")
require("hs.pathwatcher")

local M = {}

-- The directory this file was loaded from — catalog.lua, frecency.json,
-- missing.json and build_catalog.py all live beside it, so a clone works
-- wherever it lands without editing paths.
local MODULE_DIR = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

M.config = {
  -- ⇧Space, enabled only while FCP is frontmost (a global shift+space would
  -- fire constantly mid-typing in every other app).
  hotkey     = { { "shift" }, "space" },
  stateDir   = MODULE_DIR,
  fcpBundle  = "com.apple.FinalCut",
  maxResults = 50,
  debug      = false,  -- when true, apply flows log to /tmp/fcp-palette.log

  -- Row look. Category tint uses tools/brand tokens (functional.info,
  -- categorical.4, machineGreen, uiGray) so the palette reads as part of the
  -- workspace rather than stock Hammerspoon grey.
  -- "Transition" is RESERVED: build_catalog.py doesn't scan transitions yet,
  -- so no row can carry it. The mapping is here so the colour is spoken for.
  -- Two colours per category, because the wash and the accent have different
  -- jobs. `categoryBand` is the row wash. Composited at rowTintAlpha over the
  -- panel (#272727) these land on measured targets — Title #2E3E4D, Generator
  -- #3B2F47, Effect #33453A — each ~15-18 ΔE from the panel. Equal WEIGHT is
  -- the point: an earlier set put Generator at 25 ΔE and Title at 12, which
  -- made the top of an alphabetical list look styled and the bottom look
  -- unstyled, and drowned hs.chooser's own selection plate (only ~6.5 ΔE).
  -- Separation is bought with hue, not chroma. Re-measure before changing.
  categoryBand = {
    ["Title"]         = "#3D6F9E",
    ["Generator"]     = "#654089",
    ["Video Effect"]  = "#4D8562",
    ["Audio Effect"]  = "#4D8562",
    ["Effect Preset"] = "#4D8562",
    ["Transition"]    = "#6C6C78",
  },
  -- `categoryColor` is the accent: the chip stroke and its glyph, where the
  -- colour sits on a small shape and has to stay legible.
  categoryColor = {
    ["Title"]         = "#6FA8FF",
    ["Generator"]     = "#B08CFF",
    ["Video Effect"]  = "#5BE08A",
    ["Audio Effect"]  = "#5BE08A",
    ["Effect Preset"] = "#5BE08A",
    ["Transition"]    = "#C3CAD4",
  },
  -- One glyph per category for the chip, so the left column is a second read
  -- of the band colour rather than 13 unrelated stamps.
  categoryGlyph = {
    ["Title"] = "T", ["Generator"] = "G", ["Video Effect"] = "fx",
    ["Audio Effect"] = "fx", ["Effect Preset"] = "fx", ["Transition"] = "tr",
  },
  compactRows   = true,  -- one line per row (name + tinted category inline)
  cornerRadius  = 5,     -- rounds the thumbnails and the no-thumb colour chips
  nameFontSize  = 26,    -- deliberately 2x the original 13pt row label
  metaFontSize  = 22,    -- deliberately 2x the original 11pt metadata
  rowTintAlpha  = 0.32,  -- band opacity; keep it translucent or hs.chooser's own
                         -- selection highlight stops showing through the band
  metaTabStop   = 380,   -- scales with the 2x type so the columns do not collide
  showThumbnails = true, -- false = the category glyph everywhere, no Final Cut
                         -- previews
  rowBandHeight = 48,    -- scales with the 2x type; hs.chooser pads the
                         -- line box by a fixed amount, so a taller band just makes a
                         -- taller row.
  paletteWidth  = 1180,  -- room for the enlarged name and metadata columns
  visibleRows   = 7,     -- keeps the overall panel near its former screen height
}

local function dbg(s)
  if not M.config.debug then return end
  local f = io.open("/tmp/fcp-palette.log", "a")
  if f then
    local now = hs.timer.secondsSinceEpoch()
    f:write(os.date("%H:%M:%S", math.floor(now))
      .. string.format(".%03d ", math.floor((now % 1) * 1000)) .. s .. "\n")
    f:close()
  end
end

-- catalog.lua (not the json): hs.json.decode takes tens of seconds on a file
-- this size and freezes Hammerspoon's main thread; dofile takes milliseconds.
local CATALOG_PATH  = M.config.stateDir .. "/catalog.lua"
local FRECENCY_PATH = M.config.stateDir .. "/frecency.json"
-- Items FCP's browser verifiably doesn't show (some third-party packs ship
-- template folders FCP hides — e.g. FCB's Pro Zooms "+" variants). The disk
-- scan can't predict this, so the palette learns: a verified-typed search
-- that selects nothing tombstones the item here and stops offering it.
local MISSING_PATH  = M.config.stateDir .. "/missing.json"

-- How each category applies. sidebar = Titles & Generators browser (connect at
-- playhead); effects = Effects browser (apply to target clip).
-- Transitions are Phase 2 (nearest-edit targeting + no-handles modal guard).
local CATEGORIES = {
  ["Title"]         = { browser = "sidebar", root = "Titles" },
  ["Generator"]     = { browser = "sidebar", root = "Generators" },
  ["Video Effect"]  = { browser = "effects" },
  ["Audio Effect"]  = { browser = "effects" },
  ["Effect Preset"] = { browser = "effects" },
}

-- ── Utils ────────────────────────────────────────────────────────────────

local function readJSON(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local ok, data = pcall(json.decode, f:read("*a"))
  f:close()
  return ok and data or nil
end

local function writeJSON(path, data)
  local f = io.open(path, "w")
  if f then f:write(json.encode(data)) f:close() end
end

local function notify(msg)
  hs.notify.new({ title = "FCP Palette", informativeText = msg }):send()
end

local function sleep(s) hs.timer.usleep(math.floor(s * 1000000)) end

-- Poll fn until it returns non-nil or timeout (seconds). The poll interval is
-- small on purpose: every wait in an apply used to overshoot by up to a full
-- interval, and there are half a dozen of them per apply.
local function waitFor(fn, timeout, interval)
  local deadline = hs.timer.secondsSinceEpoch() + (timeout or 2)
  while hs.timer.secondsSinceEpoch() < deadline do
    local v = fn()
    if v ~= nil and v ~= false then return v end
    sleep(interval or 0.03)
  end
end

local function fcp() return hs.application.find(M.config.fcpBundle, true) end

local function attr(el, name) return el and el:attributeValue(name) end

-- Bounded BFS for the first descendant matching pred.
local function findFirst(root, pred, maxDepth, maxVisits)
  local queue, i, visits = { { root, 0 } }, 1, 0
  while queue[i] and visits < (maxVisits or 300) do
    local el, d = queue[i][1], queue[i][2]
    i = i + 1
    visits = visits + 1
    if pred(el) then return el end
    if d < (maxDepth or 6) then
      for _, c in ipairs(attr(el, "AXChildren") or {}) do
        queue[#queue + 1] = { c, d + 1 }
      end
    end
  end
end

local function rowText(row)
  local st = findFirst(row, function(e) return attr(e, "AXRole") == "AXStaticText" end, 3, 40)
  return st and (attr(st, "AXValue") or attr(st, "AXTitle"))
end

-- ── FCP anchors ──────────────────────────────────────────────────────────

local function axApp(app) return ax.applicationElement(app) end

local function parkPointer(app)
  local win = app:mainWindow()
  if win then
    local f = win:frame()
    -- toolbar strip: outside the timeline, so the skimmer can't hijack edits
    hs.mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + 8 })
  end
end

-- Go To <target>, return the element FCP focuses (verified: Timeline focuses
-- the AXLayoutArea; Titles and Generators focuses the browser search field).
local function goTo(app, target, wantId, wantRole)
  if not app:selectMenuItem({ "Window", "Go To", target }) then
    notify("FCP menu missing: Window → Go To → " .. target)
    return nil
  end
  return waitFor(function()
    local el = attr(axApp(app), "AXFocusedUIElement")
    if not el then return nil end
    if wantId and attr(el, "AXIdentifier") ~= wantId then return nil end
    if wantRole and attr(el, "AXRole") ~= wantRole then return nil end
    return el
  end, 3)
end

-- Current Edit > Undo menu item title — changes after every successful edit,
-- our universal post-apply verification channel.
local function undoTitle(app)
  local mb = attr(axApp(app), "AXMenuBar")
  for _, m in ipairs(attr(mb, "AXChildren") or {}) do
    if attr(m, "AXTitle") == "Edit" then
      local menu = (attr(m, "AXChildren") or {})[1]
      local first = menu and (attr(menu, "AXChildren") or {})[1]
      return first and attr(first, "AXTitle")
    end
  end
end

-- Clear a browser search field via its dedicated clear button, verified empty.
local function clearField(field)
  local group = attr(field, "AXParent")
  for _, c in ipairs(attr(group, "AXChildren") or {}) do
    local id = attr(c, "AXIdentifier") or ""
    if id:find("clearButton") then c:performAction("AXPress") end
  end
  waitFor(function()
    local v = attr(field, "AXValue")
    return v == nil or v == "" or v == " "
  end, 1.5)
end

-- Returns true only when the field verifiably contains `text` — a silent
-- typing failure must abort the flow (else the first cell of an UNFILTERED
-- grid gets applied: the wrong-item failure mode).
local function typeIntoField(field, text)
  -- keystrokes go to the frontmost app: make sure that's FCP before typing
  waitFor(function()
    local front = hs.application.frontmostApplication()
    if front and front:bundleID() == M.config.fcpBundle then return true end
    local target = fcp()
    if target then target:activate(true) end
  end, 3)
  for attempt = 1, 3 do
    field:setAttributeValue("AXFocused", true)
    waitFor(function() return attr(field, "AXFocused") end, 0.5)
    clearField(field)
    field:setAttributeValue("AXFocused", true)
    dbg(string.format("type attempt %d: focused=%s val=[%s] front=%s", attempt,
      tostring(attr(field, "AXFocused")), tostring(attr(field, "AXValue")),
      tostring(hs.application.frontmostApplication():name())))
    hs.eventtap.keyStrokes(text)
    -- The grid settle (waitForCell) is what gates the click, so no fixed
    -- filter sleep here.
    if waitFor(function() return attr(field, "AXValue") == text end, 2) then
      return true
    end
    dbg(string.format("type attempt %d failed: val=[%s]", attempt, tostring(attr(field, "AXValue"))))
  end
  notify("Couldn't type “" .. text .. "” into FCP's search field — aborted.")
  return false
end

-- ── Titles & Generators browser ──────────────────────────────────────────

-- pane (SplitGroup) children: [sidebar ScrollArea>Outline] [Splitter]
-- [search Group] [results Group>ScrollArea>Grid(hollow)]
local function sidebarBrowser(app)
  local field = goTo(app, "Titles and Generators",
    "editor/browserMedia/search/textField", "AXTextField")
  if not field then
    notify("Couldn't focus the Titles & Generators search field.")
    return nil
  end
  local pane = attr(attr(field, "AXParent"), "AXParent")
  local outline, results
  for _, c in ipairs(attr(pane, "AXChildren") or {}) do
    local role = attr(c, "AXRole")
    if role == "AXScrollArea" then
      outline = findFirst(c, function(e) return attr(e, "AXRole") == "AXOutline" end, 2, 20)
    elseif role == "AXGroup" and attr(c, "AXIdentifier") == nil then
      local g1 = (attr(c, "AXChildren") or {})[1]
      if g1 and attr(g1, "AXRole") == "AXScrollArea" then results = g1 end
    end
  end
  local grid = findFirst(pane, function(e) return attr(e, "AXRole") == "AXGrid" end, 5, 120)
  return { field = field, outline = outline, results = results, grid = grid }
end

-- Select the "Titles" or "Generators" root row (disclosure level 0).
-- Verified: AXSelectedRows is writable on this outline.
local function selectSidebarRoot(browser, rootName)
  if not browser.outline then return false end
  local rows = attr(browser.outline, "AXRows") or {}
  for j = 1, #rows do
    if attr(rows[j], "AXDisclosureLevel") == 0 then
      local t = rowText(rows[j])
      if t == rootName then
        local row = rows[j]
        browser.outline:setAttributeValue("AXSelectedRows", { row })
        waitFor(function() return attr(row, "AXSelected") end, 1)
        return true
      end
    end
  end
  return false
end

-- Wait for the browser grid to reflect the typed query, and return the cell to
-- click. Verified on FCP 12.3: result grids are NOT hollow — each cell is an
-- AXImage whose AXTitle is the item name, with a real AXFrame. So the filter
-- is *observed* settling (no fixed sleep), the exact-named cell is picked
-- (rather than trusting cell 1), and its frame gives an exact click point
-- (rather than guessing y-offsets past section headers).
--
-- Returns: cell, exact  — cell nil means the browser genuinely has no result.
local function waitForCell(grid, name, timeout)
  if not grid then return nil, false end
  local want = name:lower()
  local now = hs.timer.secondsSinceEpoch
  local deadline = now() + (timeout or 3)
  -- The grid still holds the UNFILTERED list for ~250ms after typing, and that
  -- list contains the wanted name too — so matching on title alone picks a
  -- cell at its stale position and the click lands on nothing. Wait for the
  -- count to actually change and then hold still before reading any cell.
  local startCount = #(attr(grid, "AXChildren") or {})
  local lastCount, stableAt, refiltered = startCount, now(), false
  local function pick(kids)
    for _, c in ipairs(kids) do
      local t = attr(c, "AXTitle")
      if t and t:lower() == want then return c, true end
    end
    return kids[1], false   -- FCP's search is fuzzy; accept its best match
  end
  while now() < deadline do
    local kids = attr(grid, "AXChildren") or {}
    if #kids ~= lastCount then
      lastCount, stableAt = #kids, now()
      refiltered = refiltered or (#kids ~= startCount)
    elseif refiltered and now() - stableAt >= 0.15 then
      return pick(kids)
    end
    sleep(0.025)
  end
  -- Never saw the grid re-filter: fall back to what's showing rather than
  -- calling the item missing (the undo verification still gates the apply).
  return pick(attr(grid, "AXChildren") or {})
end

-- How a landed item is named in the success notification. When waitForCell
-- fell back to FCP's fuzzy best match (exact = false), the clicked cell is not
-- guaranteed to be the catalog item, so the notification must not assert that
-- name — it says what actually happened instead.
local function landedName(choice, exact)
  if exact then return "“" .. choice.name .. "”" end
  return "FCP's best match for “" .. choice.name .. "”"
end

-- NOTE: the browser grid's AXSelectedChildren is writable and a write does
-- register (AXSelectedChildren reads back, "Connect to Primary Storyline"
-- reads as enabled) — but the connect then does nothing: FCP's internal
-- browser selection is not driven by the AX write. Falsified 2026-08-05;
-- don't re-try it as a way to skip the click.
--
-- Click a specific grid cell (double-click applies effects). The occlusion
-- check runs on the actual point about to be clicked.
local function clickCell(app, cell, double)
  local f = attr(cell, "AXFrame")
  if not f then return false end
  local pt = { x = f.x + f.w / 2, y = f.y + f.h / 2 }
  local owner = ax.systemElementAtPosition(pt)
  local opid = owner and owner:pid()
  if opid and opid ~= app:pid() then
    local other = hs.application.applicationForPID(opid)
    notify("FCP's browser is covered by “" .. tostring(other and other:name() or "another window")
      .. "” — move it and retry.")
    return false
  end
  hs.eventtap.leftClick(pt, 20000)
  if double then
    sleep(0.08)
    local ev = hs.eventtap.event
    local down = ev.newMouseEvent(ev.types.leftMouseDown, pt)
    down:setProperty(ev.properties.mouseEventClickState, 2)
    down:post()
    local up = ev.newMouseEvent(ev.types.leftMouseUp, pt)
    up:setProperty(ev.properties.mouseEventClickState, 2)
    up:post()
  end
  return true
end

-- FCP searched clean for this exact name and offered nothing: the item is not
-- in the browser. Tombstone it so the palette stops offering it.
local function markMissing(choice)
  dbg("markMissing id=" .. tostring(choice.id))
  if not choice.id then return end
  local ok, err = pcall(function()
    local log = readJSON(MISSING_PATH) or {}
    log[choice.id] = os.time()
    writeJSON(MISSING_PATH, log)
  end)
  dbg("markMissing write ok=" .. tostring(ok) .. " err=" .. tostring(err))
  notify("FCP's browser has no “" .. choice.name
    .. "” — hidden from the palette (fcpPalette.resetMissing() restores).")
end

-- Count timeline clips with exactly this AXDescription ("Title:Basic Title").
-- The AX tree reaches the same clip by several paths, so dedupe by position.
local function countClips(la, desc)
  local n, seen = 0, {}
  local queue, i, visits = { { la, 0 } }, 1, 0
  while queue[i] and visits < 800 do
    local e, d = queue[i][1], queue[i][2]
    i = i + 1
    visits = visits + 1
    if attr(e, "AXRole") == "AXLayoutItem" and attr(e, "AXDescription") == desc then
      local fr = attr(e, "AXFrame")
      local key = fr and string.format("%.0f,%.0f", fr.x, fr.y) or tostring(visits)
      if not seen[key] then seen[key] = true n = n + 1 end
    end
    if d < 4 then
      for _, c in ipairs(attr(e, "AXChildren") or {}) do queue[#queue + 1] = { c, d + 1 } end
    end
  end
  return n
end

local CONNECT_UNDO = "Undo Connect to Primary Storyline"

-- Titles/Generators: select in browser, connect at the playhead.
local function applyConnected(app, choice)
  dbg("STAGE goToTimeline")
  local la = goTo(app, "Timeline", nil, "AXLayoutArea")
  -- Verification plan, decided BEFORE anything changes: the Undo menu title
  -- only proves an apply when it *changes*, so a second connect in a row
  -- (identical title) is invisible to it — that reads as "nothing applied"
  -- while the clip really landed. In that case, count the matching clips
  -- instead. The count scan runs only on a repeat, so the common path stays
  -- one cheap menu read.
  local clipDesc = (choice.category == "Generator" and "Generator:" or "Title:") .. choice.name
  local undoBefore = undoTitle(app)
  local repeatApply = (undoBefore == CONNECT_UNDO)
  local clipsBefore = repeatApply and la and countClips(la, clipDesc) or nil
  dbg("repeatApply=" .. tostring(repeatApply) .. " clipsBefore=" .. tostring(clipsBefore))
  parkPointer(app)
  dbg("STAGE sidebarBrowser")
  local browser = sidebarBrowser(app)
  if not browser then return false end
  local root = CATEGORIES[choice.category].root
  dbg("STAGE selectRoot")
  if not selectSidebarRoot(browser, root) then
    notify("Couldn't select the " .. root .. " sidebar root.")
    return false
  end
  dbg("STAGE type")
  if not typeIntoField(browser.field, choice.name) then
    goTo(app, "Timeline")
    return false
  end
  dbg("STAGE settle")
  local cell, exact = waitForCell(browser.grid, choice.name)
  dbg("cell=" .. tostring(cell and attr(cell, "AXTitle")) .. " exact=" .. tostring(exact))
  if not cell then
    markMissing(choice)
    clearField(browser.field)
    goTo(app, "Timeline")
    return false
  end
  dbg("STAGE click")
  if not clickCell(app, cell, false) then
    clearField(browser.field)
    goTo(app, "Timeline")
    return false
  end
  local enabled = waitFor(function()
    local m = app:findMenuItem({ "Edit", "Connect to Primary Storyline" })
    return m and m.enabled
  end, 2)
  dbg("connect enabled=" .. tostring(enabled))
  if not enabled then
    notify("Couldn’t select “" .. choice.name .. "” in the browser — nothing applied.")
    clearField(browser.field)
    goTo(app, "Timeline")
    return false
  end
  dbg("STAGE connect")
  parkPointer(app)   -- skimmer beats the playhead: the pointer must be off the timeline
  app:selectMenuItem({ "Edit", "Connect to Primary Storyline" })
  dbg("STAGE menu returned")
  local changed
  if not repeatApply then
    changed = waitFor(function() return undoTitle(app) == CONNECT_UNDO end, 3)
  else
    local la2 = goTo(app, "Timeline", nil, "AXLayoutArea")
    changed = la2 and waitFor(function()
      return countClips(la2, clipDesc) > clipsBefore
    end, 3)
  end
  dbg("STAGE verify done changed=" .. tostring(changed))
  -- Notify before cleanup: the cleanup (clear field, refocus timeline) is
  -- ~0.5s the user shouldn't have to wait through to learn the outcome.
  if changed then
    notify("Connected " .. landedName(choice, exact) .. " at the playhead.")
  else
    notify("Connect didn’t register for “" .. choice.name .. "” — nothing applied.")
  end
  clearField(browser.field)
  goTo(app, "Timeline")
  dbg("STAGE cleanup done")
  return changed and true or false
end

-- ── Timeline targeting ───────────────────────────────────────────────────

-- Selection, else topmost clip under the playhead (AXSelectedChildren write).
local function ensureTargetClip(app)
  local la = goTo(app, "Timeline", nil, "AXLayoutArea")
  if not la then
    notify("Couldn't focus the timeline.")
    return nil
  end
  local sel = attr(la, "AXSelectedChildren") or {}
  if #sel > 0 then return la end
  local items, playhead = {}, nil
  local queue, i, visits = { { la, 0 } }, 1, 0
  while queue[i] and visits < 800 do
    local e, d = queue[i][1], queue[i][2]
    i = i + 1
    visits = visits + 1
    local role = attr(e, "AXRole")
    if role == "AXLayoutItem" then
      items[#items + 1] = { el = e, fr = attr(e, "AXFrame") }
    elseif role == "AXValueIndicator" then
      playhead = attr(e, "AXFrame")
    end
    if d < 4 then
      for _, c in ipairs(attr(e, "AXChildren") or {}) do queue[#queue + 1] = { c, d + 1 } end
    end
  end
  if not playhead then
    notify("Couldn't locate the playhead.")
    return nil
  end
  local px = playhead.x + playhead.w / 2
  local best
  for _, it in ipairs(items) do
    if it.fr and px >= it.fr.x - 3 and px < it.fr.x + it.fr.w then
      if not best or it.fr.y < best.fr.y then best = it end   -- topmost lane wins
    end
  end
  if not best then
    notify("No clip under the playhead.")
    return nil
  end
  la:setAttributeValue("AXSelectedChildren", { best.el })
  local ok = waitFor(function()
    local s = attr(la, "AXSelectedChildren") or {}
    return #s > 0
  end, 1.5)
  if not ok then
    notify("Couldn't select the clip under the playhead.")
    return nil
  end
  return la
end

-- ── Effects browser ──────────────────────────────────────────────────────

-- Find the Effects browser search field. Primary: sibling subtree of the
-- timeline's ancestor split (default workspaces). Fallback: shallow scan of
-- every FCP window (covers torn-off/floating workspaces).
local function effectsField(app, la)
  local isField = function(e)
    return attr(e, "AXIdentifier") == "editor/browserContent/search/textField"
  end
  local split = attr(attr(la, "AXParent"), "AXParent")
  local find = function()
    local f = split and findFirst(split, isField, 6, 250)
    if f then return f end
    for _, win in ipairs(attr(axApp(app), "AXWindows") or {}) do
      f = findFirst(win, isField, 8, 400)
      if f then return f end
    end
  end
  local item = app:findMenuItem({ "Window", "Show in Workspace", "Effects" })
  if item and not item.ticked then
    app:selectMenuItem({ "Window", "Show in Workspace", "Effects" })
    return waitFor(find, 3)   -- the panel animates in; poll instead of sleeping
  end
  return find()
end

local function effectsPaneParts(field)
  local pane = attr(attr(field, "AXParent"), "AXParent")
  local tbl = findFirst(pane, function(e) return attr(e, "AXRole") == "AXTable" end, 4, 120)
  local grid = findFirst(pane, function(e) return attr(e, "AXRole") == "AXGrid" end, 4, 120)
  return tbl, grid
end

-- Scope the search to "All Video & Audio" (sidebar table row 1). The table's
-- AXSelectedRows is NOT writable (verified), so scroll to top and click.
local function ensureAllScope(tbl)
  if not tbl then return false end
  local rows = attr(tbl, "AXRows") or {}
  local row1 = rows[1]
  if not row1 or rowText(row1) ~= "All Video & Audio" then return false end
  if attr(row1, "AXSelected") then return true end
  local scroll = attr(tbl, "AXParent")
  for _, c in ipairs(attr(scroll, "AXChildren") or {}) do
    if attr(c, "AXRole") == "AXScrollBar" then c:setAttributeValue("AXValue", 0.0) end
  end
  local sf = attr(scroll, "AXFrame")
  local fr = waitFor(function()   -- wait for row 1 to scroll into view
    local f = attr(row1, "AXFrame")
    if f and sf and f.y >= sf.y - 2 and f.y < sf.y + sf.h - 10 then return f end
  end, 1)
  if fr then
    hs.eventtap.leftClick({ x = fr.x + fr.w / 2, y = fr.y + fr.h / 2 }, 20000)
    waitFor(function() return attr(row1, "AXSelected") end, 1)
    return true
  end
  -- Scope may already be fine (FCP persists it); search proceeds and the
  -- undo-title verification catches a scope miss.
  return true
end

-- Effects / audio effects / presets: apply to the target clip.
local function applyEffect(app, choice)
  dbg("applyEffect start: " .. choice.name)
  local la = ensureTargetClip(app)
  dbg("target clip: " .. tostring(la ~= nil))
  if not la then return false end
  local field = effectsField(app, la)
  dbg("effects field: " .. tostring(field ~= nil))
  if not field then
    notify("Couldn't find the Effects browser.")
    return false
  end
  local tbl, grid = effectsPaneParts(field)
  dbg("pane parts tbl=" .. tostring(tbl ~= nil) .. " grid=" .. tostring(grid ~= nil))
  ensureAllScope(tbl)
  parkPointer(app)
  local typed = typeIntoField(field, choice.name)
  dbg("typed=" .. tostring(typed))
  if not typed then
    goTo(app, "Timeline")
    return false
  end
  local cell, exact = waitForCell(grid, choice.name)
  dbg("cell=" .. tostring(cell and attr(cell, "AXTitle")) .. " exact=" .. tostring(exact))
  if not cell then
    markMissing(choice)
    clearField(field)
    goTo(app, "Timeline")
    return false
  end
  local before = undoTitle(app)
  dbg("undo before=" .. tostring(before))
  local changed = false
  if clickCell(app, cell, true) then
    changed = waitFor(function() return undoTitle(app) ~= before end, 2) and true or false
  end
  dbg("changed=" .. tostring(changed))
  if changed then
    notify("Applied " .. landedName(choice, exact) .. " (" .. tostring(undoTitle(app)) .. ").")
  elseif before and before:find("Effect") then
    -- The undo title was ALREADY an effect-apply, so it changing is not
    -- available as proof — this apply may well have worked. Say so instead of
    -- claiming failure, which would invite a re-apply and double the effect.
    notify("Couldn’t confirm “" .. choice.name .. "”: FCP's undo already read “"
      .. before .. "”. Check the clip before applying again.")
  else
    notify("“" .. choice.name .. "” didn’t apply — nothing changed.")
  end
  clearField(field)
  goTo(app, "Timeline")
  return changed
end

-- Raw-search fallback: filter the chosen browser to the typed text and leave
-- FCP showing the results for a manual pick.
local function rawSearch(app, which, query)
  if which == "sidebar" then
    local browser = sidebarBrowser(app)
    if not browser then return end
    typeIntoField(browser.field, query)
  else
    local la = goTo(app, "Timeline", nil, "AXLayoutArea")
    local field = la and effectsField(app, la)
    if not field then
      notify("Couldn't find the Effects browser.")
      return
    end
    typeIntoField(field, query)
  end
  notify("FCP filtered to “" .. query .. "” — pick and apply in the browser.")
end

-- ── Frecency + choices ───────────────────────────────────────────────────

local function frecencyScore(entry, now)
  if not entry then return 0 end
  local recency = (now - (entry.last or 0)) < 7 * 86400 and 5 or 0
  return (entry.count or 0) + recency
end

local function recordUse(id)
  local log = readJSON(FRECENCY_PATH) or {}
  local e = log[id] or {}
  e.count, e.last = (e.count or 0) + 1, os.time()
  log[id] = e
  writeJSON(FRECENCY_PATH, log)
end

-- ── Row look ─────────────────────────────────────────────────────────────
-- hs.chooser accepts an hs.styledtext for `text`/`subText` and an hs.image for
-- `image`. It still owns row sizing, accessibility, selection and input; the
-- visible 2x art, text and full-height wash are painted by `rowCanvas` over the
-- live AX row frames because the native image well and row padding are fixed.
-- Two measured facts this section is built on (2026-08-20):
--   * Row height is NOT fixed — dropping `subText` shrinks it (8 rows: 537pt
--     with subText vs 430pt without), which is what buys compactRows.
--   * Row height = band height + ~12pt of padding hs.chooser adds and we
--     can't remove, so a fuller band always costs results per screen.

local UI_FONT    = ".AppleSystemUIFont"
-- The chooser still owns row geometry, selection, scrolling and the native
-- ⌘1–9 badges. Its text is transparent because `rowCanvas` draws the visible
-- 2x type, thumbnails and edge-to-edge colour without replacing that behavior.
local NAME_COLOR = { hex = "#F4F4F2", alpha = 0 }
local META_COLOR = { hex = "#FFFFFF", alpha = 0 }
local NEUTRAL    = "#9AA4B2"

local function tintFor(category)
  return (category and M.config.categoryColor[category]) or NEUTRAL
end
local function bandFor(category)
  return (category and M.config.categoryBand[category]) or "#65656F"
end

-- The second column. The band colour already says the category, so the word
-- is dropped — except for effects, where Video and Audio share one green and
-- the word is the only thing telling them apart.
local EFFECT_WORD = { ["Video Effect"] = "Video", ["Audio Effect"] = "Audio",
                      ["Effect Preset"] = "Preset" }
local function metaFor(category, set)
  if not category then return "raw FCP search" end
  local word = EFFECT_WORD[category]
  if word and set then return word .. " · " .. set end
  return word or set or category
end

-- Names longer than the tab stop would push the second column off its
-- gridline, so they are clipped rather than allowed to break the column.
local NAME_MAX = 30
local function clip(name)
  if #name <= NAME_MAX then return name end
  return name:sub(1, NAME_MAX - 1) .. "…"
end

local function styledRow(name, category, set)
  local band = { white = 0, alpha = 0 }
  local para = { minimumLineHeight = M.config.rowBandHeight,
                 maximumLineHeight = M.config.rowBandHeight,
                 tabStops = { { location = M.config.metaTabStop, tabStopType = "left" } } }
  local function run(str, size, color)
    return hs.styledtext.new(str, { font = { name = UI_FONT, size = size },
                                    color = color, backgroundColor = band,
                                    paragraphStyle = para })
  end
  local nameRun = run(clip(name), M.config.nameFontSize, NAME_COLOR)
  local metaRun = run("\t" .. metaFor(category, set), M.config.metaFontSize, META_COLOR)
  -- The padding is what stretches the wash to the panel edge; overshoot it so
  -- every row's band is clipped at the same x rather than ending on its text.
  local padRun  = run(string.rep(" ", 900), M.config.nameFontSize, NAME_COLOR)
  if M.config.compactRows then
    return nameRun .. metaRun .. padRun, nil
  end
  return nameRun .. padRun, metaRun .. padRun
end

-- Rounded row art. Both caches are keyed by what they draw, so the canvas work
-- happens once per distinct thumbnail/category, not once per keystroke.
-- The art is drawn into a canvas TALLER than the art itself: hs.chooser scales
-- the whole canvas into its well, so the transparent margin is how the visible
-- chip is kept down to band height instead of punching through the band.
local ART_W, ART_H   = 128, 60          -- deliberately 2x the original row art
local CANVAS_H       = 88               -- the well; the rest is transparent
local ART_Y          = 26               -- biased low: the well centres on the
                                        -- ROW, but the band sits below centre
local roundedCache, chipCache = {}, {}

local function radii()
  local r = M.config.cornerRadius * 2   -- art is drawn at 2x for retina
  return { xRadius = r, yRadius = r }
end
local function artFrame(inset)
  inset = inset or 0
  return { x = inset, y = ART_Y + inset, w = ART_W - inset * 2, h = ART_H - inset * 2 }
end

local function newArtCanvas()
  return hs.canvas.new({ x = 0, y = 0, w = ART_W, h = CANVAS_H })
end

-- Every thumbnail sits inside its category chip and is dimmed, so no single
-- flat-white Final Cut preview out-shouts the item name next to it.
local function roundedThumb(path, category)
  local cached = roundedCache[path]
  if cached ~= nil then return cached or nil end
  local src = hs.image.imageFromPath(path)
  if not src then roundedCache[path] = false return nil end
  local cv = newArtCanvas()
  cv[1] = { type = "rectangle", action = "fill", roundedRectRadii = radii(),
            fillColor = { hex = bandFor(category), alpha = 0.9 }, frame = artFrame() }
  cv[2] = { type = "rectangle", action = "clip", roundedRectRadii = radii(),
            frame = artFrame() }
  cv[3] = { type = "image", image = src, imageScaling = "scaleToFit",
            imageAlpha = 0.82, frame = artFrame() }
  cv[4] = { type = "resetClip" }
  cv[5] = { type = "rectangle", action = "stroke", strokeWidth = 2,
            strokeColor = { hex = tintFor(category), alpha = 0.5 },
            roundedRectRadii = radii(), frame = artFrame(1) }
  local out = cv:imageFromCanvas()
  cv:delete()
  roundedCache[path] = out or false
  return out
end

-- Items with no thumbnail (audio units, most presets) get the same chip with
-- the category's glyph, so the left column keeps one shape and one meaning.
local function categoryChip(category)
  local key = category or "_raw"
  if chipCache[key] then return chipCache[key] end
  local accent = tintFor(category)
  local cv = newArtCanvas()
  cv[1] = { type = "rectangle", action = "fill", roundedRectRadii = radii(),
            fillColor = { hex = bandFor(category), alpha = 0.9 }, frame = artFrame() }
  cv[2] = { type = "rectangle", action = "stroke", strokeWidth = 2,
            strokeColor = { hex = accent, alpha = 0.5 },
            roundedRectRadii = radii(), frame = artFrame(1) }
  cv[3] = { type = "text", text = (category and M.config.categoryGlyph[category]) or "?",
            textSize = 15, textAlignment = "center",
            textColor = { hex = accent, alpha = 0.85 },
            frame = { x = 0, y = ART_Y + 5, w = ART_W, h = ART_H } }
  local out = cv:imageFromCanvas()
  cv:delete()
  chipCache[key] = out
  return out
end

local allChoices = {}
local catalogCache, catalogMtime

local function loadCatalog()
  local mt = hs.fs.attributes(CATALOG_PATH, "modification")
  if catalogCache and mt == catalogMtime then return catalogCache end
  local ok, data = pcall(dofile, CATALOG_PATH)
  if ok and type(data) == "table" then
    catalogCache, catalogMtime = data, mt
    return data
  end
  notify("No catalog — run build_catalog.py (or fcpPalette.refreshCatalog()).")
  return {}
end

local function loadChoices()
  local catalog = loadCatalog()
  local log = readJSON(FRECENCY_PATH) or {}
  local missing = readJSON(MISSING_PATH) or {}
  local now = os.time()
  allChoices = {}
  for _, item in ipairs(catalog) do
    if CATEGORIES[item.category] and not missing[item.category .. "/" .. item.name] then
      local id = item.category .. "/" .. item.name
      local text, subText = styledRow(item.name, item.category, item.set)
      allChoices[#allChoices + 1] = {
        text = text,
        subText = subText,
        id = id,
        name = item.name,
        category = item.category,
        thumb = item.thumb,
        displayName = clip(item.name),
        displayMeta = metaFor(item.category, item.set),
        _hay = (item.name .. " " .. item.category):lower(),
        _score = frecencyScore(log[id], now),
      }
    end
  end
  table.sort(allChoices, function(a, b)
    if a._score ~= b._score then return a._score > b._score end
    return a.text < b.text
  end)
end

-- Subsequence filter (queryChangedCallback disables the chooser's built-in
-- filtering, which we need for the live raw-search fallback rows).
local function matchRank(q, hay)
  if hay:find(q, 1, true) then return 3 end
  local pos = 0
  for ci = 1, #q do
    pos = hay:find(q:sub(ci, ci), pos + 1, true)
    if not pos then return nil end
  end
  return 2
end

local function filteredChoices(query)
  local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local out = {}
  if q == "" then
    for i = 1, math.min(#allChoices, M.config.maxResults) do out[i] = allChoices[i] end
  else
    local exact, fuzzy = {}, {}
    for _, c in ipairs(allChoices) do
      local r = matchRank(q, c._hay)
      if r == 3 then exact[#exact + 1] = c
      elseif r == 2 then fuzzy[#fuzzy + 1] = c end
      if #exact >= M.config.maxResults then break end
    end
    for _, c in ipairs(exact) do out[#out + 1] = c end
    for i = 1, math.min(#fuzzy, M.config.maxResults - #exact) do out[#out + 1] = fuzzy[i] end
    for _, fb in ipairs({ { "Search Titles & Generators for “" .. query .. "”", "sidebar" },
                          { "Search Effects for “" .. query .. "”", "effects" } }) do
      local text, subText = styledRow(fb[1], nil, nil)
      out[#out + 1] = { text = text, subText = subText, fallback = fb[2], query = query,
                        displayName = clip(fb[1]), displayMeta = metaFor(nil, nil) }
    end
  end
  return out
end

-- ── Palette ──────────────────────────────────────────────────────────────

local chooser
local clickTap, keysTap, closeCanvas, rowCanvas
local currentChoices = {}
local rowCanvasTimer
local rowCanvasSignature

local function applyChoice(choice)
  local app = fcp()
  if not app then
    notify("Final Cut Pro isn't running.")
    return
  end
  app:activate(true)
  waitFor(function()
    local f = hs.application.frontmostApplication()
    return f and f:bundleID() == M.config.fcpBundle
  end, 2)
  if choice.fallback then
    rawSearch(app, choice.fallback, choice.query)
    return
  end
  local ok
  if CATEGORIES[choice.category].browser == "sidebar" then
    ok = applyConnected(app, choice)
  else
    ok = applyEffect(app, choice)
  end
  if ok then recordUse(choice.id) end
end

-- The chooser panel via AX: Hammerspoon's window titled "Chooser" (verified),
-- with untitled-window-holding-a-text-field as fallback. Read fresh every
-- time — never cached (display topology changes mid-session).
local function chooserAXWindow()
  local appEl = ax.applicationElementForPID(hs.processInfo.processID)
  local fallback
  for _, win in ipairs(attr(appEl, "AXWindows") or {}) do
    local title = attr(win, "AXTitle")
    if title == "Chooser" then return win end
    if (title == nil or title == "") and not fallback then
      if findFirst(win, function(e) return attr(e, "AXRole") == "AXTextField" end, 4, 60) then
        fallback = win
      end
    end
  end
  return fallback
end

local function chooserAXFrame()
  local win = chooserAXWindow()
  return win and attr(win, "AXFrame")
end

-- hs.chooser always opens on the primary screen; move the panel to the screen
-- FCP's focused window is on (mouse screen as fallback), Spotlight-position.
-- The screen the palette belongs on: FCP's focused window's screen, else the
-- mouse's, else the main screen.
local function targetScreen()
  local app = fcp()
  local fwin = app and (app:focusedWindow() or app:mainWindow())
  return (fwin and fwin:screen()) or hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end

local function moveToActiveScreen()
  local win = chooserAXWindow()
  local fr = win and attr(win, "AXFrame")
  if not fr then return false end
  local sf = targetScreen():frame()
  local pt = { x = sf.x + (sf.w - fr.w) / 2, y = sf.y + sf.h * 0.2 }
  if math.abs(pt.x - fr.x) > 2 or math.abs(pt.y - fr.y) > 2 then
    win:setAttributeValue("AXPosition", pt)
  end
  return true
end

-- Browser thumbnails, loaded lazily for displayed rows only (≤52 at a time —
-- never all 20k) and cached across shows. false = known-bad path.
local function withImages(list)
  for _, c in ipairs(list) do
    if not c.rowArt then
      c.rowArt = (M.config.showThumbnails and c.thumb
                  and roundedThumb(c.thumb, c.category)) or categoryChip(c.category)
    end
    -- Keep the chooser's small image as a fail-safe; the row canvas covers it
    -- with the 2x rendering during normal operation.
    c.image = c.rowArt
  end
  return list
end

local function setChoices(list)
  currentChoices = withImages(list)
  chooser:choices(currentChoices)
  rowCanvasSignature = nil
end

-- hs.chooser caps its image well and cannot colour row padding. This visual
-- layer uses the chooser's live AX row frames, so the proven input, selection,
-- scrolling and apply mechanics remain untouched while the visible rows get
-- full-height bands, genuinely larger art and 2x type.
local function refreshRowCanvas()
  if not chooser:isVisible() then return end
  local fr = chooserAXFrame()
  local win = chooserAXWindow()
  local tableEl = win and findFirst(win, function(e)
    return attr(e, "AXRole") == "AXTable"
  end, 5, 120)
  local rows = tableEl and (attr(tableEl, "AXRows") or attr(tableEl, "AXChildren")) or {}
  if not fr or #rows == 0 then return end

  local visible, sig = {}, {}
  for i, row in ipairs(rows) do
    local rf = attr(row, "AXFrame")
    local c = currentChoices[i]
    if rf and c and rf.y + rf.h > fr.y and rf.y < fr.y + fr.h then
      visible[#visible + 1] = { frame = rf, choice = c }
      sig[#sig + 1] = string.format("%d:%d:%d:%s", i, rf.y, rf.h,
        c.id or c.displayName or "")
    end
  end
  local signature = table.concat(sig, "|")
  if signature == rowCanvasSignature then return end
  rowCanvasSignature = signature
  if rowCanvas then rowCanvas:delete() end
  rowCanvas = hs.canvas.new(fr)

  local n = 0
  for _, v in ipairs(visible) do
    local rf, c = v.frame, v.choice
    local y = math.floor(rf.y - fr.y)
    local h = math.ceil(rf.h) + 1 -- 1pt overlap prevents a hairline at row joins
    n = n + 1
    rowCanvas[n] = { type = "rectangle", action = "fill",
      fillColor = { hex = bandFor(c.category), alpha = M.config.rowTintAlpha },
      frame = { x = math.floor(rf.x - fr.x), y = y,
                w = math.ceil(rf.w), h = h } }

    local artW, artH = 88, 60
    if c.rowArt then
      n = n + 1
      rowCanvas[n] = { type = "image", image = c.rowArt, imageScaling = "scaleToFit",
        frame = { x = 12, y = y + (h - artH) / 2, w = artW, h = artH } }
    end

    local textY = y + math.max(0, (h - M.config.rowBandHeight) / 2)
    n = n + 1
    rowCanvas[n] = { type = "text", text = c.displayName or "",
      textFont = UI_FONT, textSize = M.config.nameFontSize,
      textLineBreak = "truncateTail",
      textColor = NAME_COLOR.alpha == 0 and { hex = "#F4F4F2" } or NAME_COLOR,
      frame = { x = 104, y = textY + 7,
                w = M.config.metaTabStop - 112, h = M.config.rowBandHeight } }
    n = n + 1
    rowCanvas[n] = { type = "text", text = c.displayMeta or "",
      textFont = UI_FONT, textSize = M.config.metaFontSize,
      textLineBreak = "truncateTail",
      textColor = { hex = "#FFFFFF", alpha = 0.45 },
      frame = { x = M.config.metaTabStop + 16, y = textY + 9,
                w = math.max(80, fr.w - M.config.metaTabStop - 96),
                h = M.config.rowBandHeight } }
  end
  rowCanvas:level(hs.canvas.windowLevels.popUpMenu)
  rowCanvas:clickActivating(false)
  rowCanvas:canvasMouseEvents(false, false)
  rowCanvas:show()
end

local function showCloseButton()
  local fr = chooserAXFrame()
  if not fr then return end   -- cosmetic only; Esc/⌘W/click-off still close
  local size = 18
  closeCanvas = hs.canvas.new({ x = fr.x + fr.w - size - 8, y = fr.y + 9, w = size, h = size })
  closeCanvas[1] = { type = "circle", action = "fill",
                     fillColor = { white = 0.5, alpha = 0.35 } }
  closeCanvas[2] = { type = "text", text = "✕", textSize = 11,
                     textAlignment = "center",
                     textColor = { white = 1, alpha = 0.9 },
                     frame = { x = "0%", y = "8%", w = "100%", h = "92%" } }
  closeCanvas:level(hs.canvas.windowLevels.popUpMenu)
  closeCanvas:clickActivating(false)
  closeCanvas:canvasMouseEvents(true, false)
  closeCanvas:mouseCallback(function() chooser:hide() end)
  closeCanvas:show()
end

local function chromeDown()
  if clickTap then clickTap:stop() end
  if keysTap then keysTap:stop() end
  if closeCanvas then closeCanvas:delete() closeCanvas = nil end
  if rowCanvasTimer then rowCanvasTimer:stop() rowCanvasTimer = nil end
  if rowCanvas then rowCanvas:delete() rowCanvas = nil end
  rowCanvasSignature = nil
end

local function chromeUp()
  chromeDown()
  clickTap:start()
  keysTap:start()
  moveToActiveScreen()
  refreshRowCanvas()
  rowCanvasTimer = hs.timer.doEvery(0.12, refreshRowCanvas)
  showCloseButton()
end

local function showPalette()
  if not fcp() then
    notify("Final Cut Pro isn't running.")
    return
  end
  loadChoices()
  chooser:query("")
  setChoices(filteredChoices(""))
  -- chooser:width() is a percentage of the PRIMARY screen; convert the
  -- requested point width for whichever screen the panel will land on.
  local wpx = math.min(M.config.paletteWidth, targetScreen():frame().w * 0.85)
  chooser:width(wpx / hs.screen.primaryScreen():frame().w * 100)
  chooser:show()
end

-- Scripted apply (also used by the test harness): fcpPalette.apply("Title", "Basic Title")
function M.apply(category, name)
  applyChoice({ category = category, name = name, id = category .. "/" .. name })
end

-- Forget every tombstoned item (e.g. after installing an update that makes
-- previously-hidden templates appear in FCP's browser).
function M.resetMissing()
  os.remove(MISSING_PATH)
  notify("Cleared the missing-item list.")
end

function M.refreshCatalog(auto)
  -- Single-flight; the task handle is anchored (unreferenced hs.task objects
  -- are GC'd mid-run, like timers).
  if M.refreshTask and M.refreshTask:isRunning() then return end
  M.refreshTask = hs.task.new("/usr/bin/python3", function(code, stdout, stderr)
    if code == 0 then
      local n = stdout:match("^(%d+ items)") or "done"
      notify((auto and "New FCP plugins detected — catalog refreshed: "
                    or "Catalog refreshed: ") .. n .. ".")
    else
      notify("Catalog refresh failed: " .. tostring(stderr))
    end
  end, { M.config.stateDir .. "/build_catalog.py" })
  M.refreshTask:start()
end

-- Auto-refresh: watch the plugin roots and rebuild the catalog when template
-- or preset files change (plugin installs/removals). Debounced hard because
-- installers touch hundreds of files in a burst.
local WATCH_PATHS = {
  os.getenv("HOME") .. "/Movies/Motion Templates.localized/",
  os.getenv("HOME") .. "/Library/Application Support/ProApps/Effects Presets/",
  "/Library/Application Support/Final Cut Pro/Templates.localized/",
}

local function isPluginFile(path)
  return path:match("%.mot[inr]$") or path:match("%.moef$")
      or path:match("%.effectsPreset$")
end

function M.start()
  chooser = hs.chooser.new(function(choice)
    if choice then applyChoice(choice) end
  end)
  chooser:queryChangedCallback(function(q) setChoices(filteredChoices(q)) end)
  chooser:rows(M.config.visibleRows) -- whole rows only; sized for the 2x row type
  chooser:placeholderText("Titles, generators, effects…")
  chooser:showCallback(chromeUp)
  chooser:hideCallback(chromeDown)

  local types = hs.eventtap.event.types

  -- Click anywhere outside the palette dismisses it (the click still lands
  -- where it was aimed, Spotlight-style). Geometry when the panel frame is
  -- readable; pid-under-point as fallback.
  clickTap = hs.eventtap.new({ types.leftMouseDown, types.rightMouseDown }, function(ev)
    local pt = ev:location()
    local fr = chooserAXFrame()
    local inside
    if fr then
      inside = pt.x >= fr.x and pt.x <= fr.x + fr.w and pt.y >= fr.y and pt.y <= fr.y + fr.h
    else
      local el = ax.systemElementAtPosition(pt)
      inside = el ~= nil and el:pid() == hs.processInfo.processID
    end
    if not inside then chooser:hide() end
    return false
  end)

  -- ⌘W closes. (Esc is the chooser's own close; ⌘1–9 row picking is
  -- hs.chooser's own — no need to reimplement it.)
  keysTap = hs.eventtap.new({ types.keyDown }, function(ev)
    local flags = ev:getFlags()
    if not flags.cmd or flags.alt or flags.ctrl then return false end
    if hs.keycodes.map[ev:getKeyCode()] == "w" then
      chooser:hide()
      return true
    end
    return false
  end)

  M.hotkeyObj = hs.hotkey.new(M.config.hotkey[1], M.config.hotkey[2], showPalette)
  M.appWatcher = hs.application.watcher.new(function(_, event, app)
    if app and app:bundleID() == M.config.fcpBundle then
      if event == hs.application.watcher.activated then
        M.hotkeyObj:enable()
      elseif event == hs.application.watcher.deactivated then
        M.hotkeyObj:disable()
      end
    end
  end)
  M.appWatcher:start()
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == M.config.fcpBundle then M.hotkeyObj:enable() end

  M.pathWatchers = {}
  for _, p in ipairs(WATCH_PATHS) do
    local pw = hs.pathwatcher.new(p, function(files)
      for _, f in ipairs(files) do
        if isPluginFile(f) then
          if M.refreshDebounce then M.refreshDebounce:stop() end
          M.refreshDebounce = hs.timer.doAfter(15, function()
            M.refreshCatalog(true)
          end)
          return
        end
      end
    end)
    if pw then
      pw:start()
      table.insert(M.pathWatchers, pw)
    end
  end

  M.chooser = chooser
  M.show = showPalette
  return M
end

return M
