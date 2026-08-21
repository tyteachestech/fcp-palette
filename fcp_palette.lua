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
local drawing = require("hs.drawing")
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
    ["Title"] = "T", ["Generator"] = "G", ["Video Effect"] = "FX",
    ["Audio Effect"] = "FX", ["Effect Preset"] = "FX", ["Transition"] = "TR",
  },
  uiScale       = 0.85,  -- one reload-time control for all palette dimensions
  compactRows   = true,  -- one line per row (name + tinted category inline)
  -- The dimensions below are the 1.0-scale baselines. Change only uiScale for
  -- a proportional resize; individual values remain available as exceptions.
  cornerRadius  = 5,     -- rounds the thumbnails and the no-thumb colour chips
  nameFontSize  = 26,    -- 22pt at the current 0.85 scale
  metaFontSize  = 22,    -- 19pt at the current 0.85 scale
  rowTintAlpha  = 0.32,  -- category wash opacity; unaffected by geometric scale
  selectionTintAlpha = 0.14, -- extra white lift on the active result
  selectionStrokeWidth = 3,  -- full-width outline makes focus obvious at rest
  metaTabStop   = 380,   -- scales with the 2x type so the columns do not collide
  showThumbnails = true, -- false = the category glyph everywhere, no Final Cut
                         -- previews
  rowBandHeight = 48,    -- scales with the 2x type; hs.chooser pads the
                         -- line box by a fixed amount, so a taller band just makes a
                         -- taller row.
  paletteWidth  = 1180,  -- room for the enlarged name and metadata columns
  visibleRows   = 9,     -- two more whole rows; closest clean fit to 30% taller
}

local function ui(value)
  return math.max(1, math.floor(value * M.config.uiScale + 0.5))
end

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

local UI_FONT = ".AppleSystemUIFont"
local ROW_EDGE_INSET = ui(16)
local THUMB_W, THUMB_H = ui(88), ui(60)
local THUMB_TEXT_GAP = ui(16)
local COLUMN_GAP = ui(24)
local SHORTCUT_INSET = ui(76)
local NAME_FONT_SIZE = ui(M.config.nameFontSize)
local META_FONT_SIZE = ui(M.config.metaFontSize)
local ROW_BAND_HEIGHT = ui(M.config.rowBandHeight)
local META_TAB_STOP = ui(M.config.metaTabStop)
local SELECTION_STROKE_WIDTH = ui(M.config.selectionStrokeWidth)
local SELECTION_INSET = ui(2)
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
  local para = { minimumLineHeight = ROW_BAND_HEIGHT,
                 maximumLineHeight = ROW_BAND_HEIGHT,
                 tabStops = { { location = META_TAB_STOP, tabStopType = "left" } } }
  local function run(str, size, color)
    return hs.styledtext.new(str, { font = { name = UI_FONT, size = size },
                                    color = color, backgroundColor = band,
                                    paragraphStyle = para })
  end
  local nameRun = run(clip(name), NAME_FONT_SIZE, NAME_COLOR)
  local metaRun = run("\t" .. metaFor(category, set), META_FONT_SIZE, META_COLOR)
  -- Keep the native line wide enough to preserve the chooser's measured row
  -- geometry; the visible wash itself is painted by rowCanvas.
  local padRun  = run(string.rep(" ", 900), NAME_FONT_SIZE, NAME_COLOR)
  if M.config.compactRows then
    return nameRun .. metaRun .. padRun, nil
  end
  return nameRun .. padRun, metaRun .. padRun
end

local function centeredTextFrame(x, width, rowY, rowH, fontSize)
  local measured = drawing.getTextDrawingSize("Ag", {
    font = UI_FONT, size = fontSize, lineBreak = "clip",
  })
  local textH = math.ceil((measured and measured.h) or fontSize * 1.25)
  return {
    x = x,
    y = rowY + math.max(0, math.floor((rowH - textH) / 2)),
    w = math.max(1, width),
    h = textH,
  }
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
-- rowCanvas displays that padded image directly. Offset its frame by the
-- visible art's center delta so the pixels, not the transparent canvas, are
-- vertically centered in the row.
local THUMB_Y_CORRECTION = -math.floor(
  ((ART_Y + ART_H / 2) - CANVAS_H / 2) * THUMB_H / CANVAS_H + 0.5
)
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

local CHIP_GLYPH_SIZE = 30
local function centeredArtTextFrame(text)
  local measured = drawing.getTextDrawingSize(text, {
    font = UI_FONT, size = CHIP_GLYPH_SIZE, lineBreak = "clip",
  })
  local textH = math.ceil((measured and measured.h) or CHIP_GLYPH_SIZE * 1.25)
  return {
    x = 0,
    y = ART_Y + math.max(0, math.floor((ART_H - textH) / 2)),
    w = ART_W,
    h = textH,
  }
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
  local glyph = (category and M.config.categoryGlyph[category]) or "?"
  local cv = newArtCanvas()
  cv[1] = { type = "rectangle", action = "fill", roundedRectRadii = radii(),
            fillColor = { hex = bandFor(category), alpha = 0.9 }, frame = artFrame() }
  cv[2] = { type = "rectangle", action = "stroke", strokeWidth = 2,
            strokeColor = { hex = accent, alpha = 0.5 },
            roundedRectRadii = radii(), frame = artFrame(1) }
  cv[3] = { type = "text", text = glyph, textFont = UI_FONT,
            textSize = CHIP_GLYPH_SIZE, textAlignment = "center",
            textColor = { hex = accent, alpha = 1 },
            frame = centeredArtTextFrame(glyph) }
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
  local scrollEl = win and findFirst(win, function(e)
    return attr(e, "AXRole") == "AXScrollArea"
  end, 5, 120)
  local rows = tableEl and (attr(tableEl, "AXRows") or attr(tableEl, "AXChildren")) or {}
  local viewport = scrollEl and attr(scrollEl, "AXFrame")
  if not fr or not viewport or #rows == 0 then return end

  local viewportTop = math.max(fr.y, viewport.y)
  local viewportBottom = math.min(fr.y + fr.h, viewport.y + viewport.h)

  local visible = {}
  local sig = { string.format("viewport:%d:%d", viewportTop, viewportBottom) }
  for i, row in ipairs(rows) do
    local rf = attr(row, "AXFrame")
    local c = currentChoices[i]
    if rf and c and rf.y + rf.h > viewportTop and rf.y < viewportBottom then
      local selected = attr(row, "AXSelected") == true
      visible[#visible + 1] = { frame = rf, choice = c, selected = selected }
      sig[#sig + 1] = string.format("%d:%d:%d:%s:%s", i, rf.y, rf.h,
        c.id or c.displayName or "", tostring(selected))
    end
  end
  local signature = table.concat(sig, "|")
  if signature == rowCanvasSignature then return end
  rowCanvasSignature = signature
  if rowCanvas then rowCanvas:delete() end
  rowCanvas = hs.canvas.new(fr)

  local n = 1
  rowCanvas[n] = { type = "rectangle", action = "clip",
    frame = { x = 0, y = viewportTop - fr.y,
              w = fr.w, h = math.max(viewportBottom - viewportTop, 1) } }
  for _, v in ipairs(visible) do
    local rf, c = v.frame, v.choice
    local rowX = math.floor(rf.x - fr.x)
    local rowW = math.ceil(rf.w)
    local y = math.floor(rf.y - fr.y)
    local h = math.ceil(rf.h) + 1 -- 1pt overlap prevents a hairline at row joins
    n = n + 1
    rowCanvas[n] = { type = "rectangle", action = "fill",
      fillColor = { hex = bandFor(c.category), alpha = M.config.rowTintAlpha },
      frame = { x = 0, y = y, w = fr.w, h = h } }

    if v.selected then
      n = n + 1
      rowCanvas[n] = { type = "rectangle", action = "fill",
        fillColor = { white = 1, alpha = M.config.selectionTintAlpha },
        frame = { x = 0, y = y, w = fr.w, h = h } }
      n = n + 1
      rowCanvas[n] = { type = "rectangle", action = "stroke",
        strokeColor = { white = 1, alpha = 0.92 },
        strokeWidth = SELECTION_STROKE_WIDTH,
        frame = { x = SELECTION_INSET, y = y + SELECTION_INSET,
                  w = fr.w - SELECTION_INSET * 2,
                  h = math.max(h - SELECTION_INSET * 2, 1) } }
    end

    local thumbX = rowX + ROW_EDGE_INSET
    if c.rowArt then
      n = n + 1
      rowCanvas[n] = { type = "image", image = c.rowArt, imageScaling = "scaleToFit",
        frame = { x = thumbX,
                  y = y + (h - THUMB_H) / 2 + THUMB_Y_CORRECTION,
                  w = THUMB_W, h = THUMB_H } }
    end

    local nameX = thumbX + THUMB_W + THUMB_TEXT_GAP
    local metaX = rowX + META_TAB_STOP
    local textRight = rowX + rowW - SHORTCUT_INSET
    n = n + 1
    rowCanvas[n] = { type = "text", text = c.displayName or "",
      textFont = UI_FONT, textSize = NAME_FONT_SIZE,
      textLineBreak = "truncateTail",
      textColor = NAME_COLOR.alpha == 0 and { hex = "#F4F4F2" } or NAME_COLOR,
      frame = centeredTextFrame(nameX, metaX - nameX - COLUMN_GAP,
                                y, h, NAME_FONT_SIZE) }
    n = n + 1
    rowCanvas[n] = { type = "text", text = c.displayMeta or "",
      textFont = UI_FONT, textSize = META_FONT_SIZE,
      textLineBreak = "truncateTail",
      textColor = { hex = "#FFFFFF", alpha = 0.45 },
      frame = centeredTextFrame(metaX, textRight - metaX,
                                y, h, META_FONT_SIZE) }
  end
  n = n + 1
  rowCanvas[n] = { type = "resetClip" }
  rowCanvas:level(hs.canvas.windowLevels.popUpMenu)
  rowCanvas:clickActivating(false)
  rowCanvas:canvasMouseEvents(false, false)
  rowCanvas:show()
end

local function showCloseButton()
  local fr = chooserAXFrame()
  if not fr then return end   -- cosmetic only; Esc/⌘W/click-off still close
  local size = ui(18)
  closeCanvas = hs.canvas.new({ x = fr.x + fr.w - size - ui(8),
                               y = fr.y + ui(9), w = size, h = size })
  closeCanvas[1] = { type = "circle", action = "fill",
                     fillColor = { white = 0.5, alpha = 0.35 } }
  closeCanvas[2] = { type = "text", text = "✕", textSize = ui(11),
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
  local wpx = math.min(ui(M.config.paletteWidth), targetScreen():frame().w * 0.85)
  chooser:width(wpx / hs.screen.primaryScreen():frame().w * 100)
  chooser:show()
end

-- Scripted apply (also used by the test harness): fcpPalette.apply("Title", "Basic Title")
function M.apply(category, name)
  applyChoice({ category = category, name = name, id = category .. "/" .. name })
end

-- ── Scripted FCPXML export ───────────────────────────────────────────────
-- Final Cut has no export API, so "get the project that is open in the
-- timeline out of FCP" is an AX sequence: Window → Go To → Timeline (so the
-- export targets the TIMELINE's project, not whatever a browser has selected),
-- then File → Export XML…, then drive the NSSavePanel it opens.
--
-- Verified on Final Cut Pro 12.3, 2026-08-21 — full detail in SPEC.md,
-- "Scripted XML export":
--   * The panel is an APP-LEVEL AXWindow: AXIdentifier "save-panel",
--     AXSubrole AXDialog, AXModal true. It is NOT an AXSheet on the main
--     window, so a sheet-only search never finds it.
--   * Name field = AXIdentifier "saveAsNameTextField". It pre-fills with
--     "<project name>.fcpxmld", the cheapest readout of the project name.
--   * FALSIFIED: writing a FULL PATH into that field does not navigate.
--     NSSavePanel takes the text literally and writes
--     ":Users:…:name.fcpxmld" into the panel's current folder. The folder must
--     be set with ⌘⇧G → AXSheet "GoToWindow" → AXTextField "PathTextField"
--     → Return, which is verified here by re-reading the "where popup".
--   * Save = AXButton "OKButton"; Cancel = AXButton "CancelButton". The
--     Version popup already reads "Current Version (1.14)" — left untouched.
--   * FCP writes FCPXML 1.14 as a .fcpxmld PACKAGE (a folder holding
--     Info.fcpxml), so the result resolves to the .fcpxml FILE inside it.
--   * hs.application.frontmostApplication() goes STALE through this sequence:
--     the blocking waits never yield the main thread, so Hammerspoon cannot
--     process the workspace notification and keeps reporting the old app. The
--     frontmost gate therefore reads AXFrontmost off the app element, a live
--     AX query.

local function axById(root, id, depth, visits)
  return findFirst(root, function(e) return attr(e, "AXIdentifier") == id end,
                   depth or 3, visits or 500)
end

-- Whoever currently owns the keyboard, read live off the system-wide element
-- (see the staleness note above).
local function focusedApp()
  local sys = ax.systemWideElement()
  local fa  = sys and attr(sys, "AXFocusedApplication")
  local pid = fa and fa:pid()
  return (pid and hs.application.applicationForPID(pid))
      or hs.application.frontmostApplication()
end

-- FCP's Export XML save panel, wherever this build hangs it (app-level dialog
-- on 12.3; the main-window sheet lookup is the defensive fallback).
local function exportPanel(axapp)
  for _, c in ipairs(attr(axapp, "AXChildren") or {}) do
    if attr(c, "AXIdentifier") == "save-panel" then return c end
  end
  for _, c in ipairs(attr(attr(axapp, "AXMainWindow"), "AXChildren") or {}) do
    if attr(c, "AXRole") == "AXSheet" then return c end
  end
end

-- Resolve what FCP actually wrote to the .fcpxml FILE: a 12.x .fcpxmld package
-- (folder + Info.fcpxml) or, on older builds, a plain .fcpxml.
local function exportArtifact(dest)
  local bundle = dest .. ".fcpxmld"
  local inner  = bundle .. "/Info.fcpxml"
  if hs.fs.attributes(inner, "size") then return inner, bundle end
  local plain = dest .. ".fcpxml"
  if hs.fs.attributes(plain, "size") then return plain, nil end
end

-- The driven sequence. Errors (level 0, so the message stays clean) at every
-- step it cannot verify; M.exportXML owns the cleanup and the result file.
local function exportXMLRun(dest, t0, budget)
  -- Remaining budget, so one wedged step can never outlive the whole op.
  local function left(cap)
    local rem = (t0 + budget) - hs.timer.secondsSinceEpoch()
    if rem <= 0 then error("timed out after " .. budget .. "s", 0) end
    return cap and math.min(rem, cap) or rem
  end

  local app = fcp()
  if not app then error("Final Cut Pro isn't running", 0) end
  local axapp = axApp(app)

  -- A leftover modal would swallow every keystroke below.
  if exportPanel(axapp) then
    error("a Final Cut save panel is already open — close it first", 0)
  end

  -- ⌘⇧G and Return go to the frontmost app. AXFrontmost is a LIVE read but it
  -- still lags the real activation (measured: FCP had already revalidated its
  -- menus while this read false), so a miss here is logged, not fatal — the
  -- menu gate below, and every AX wait after it, are the real proofs.
  local front = waitFor(function()
    if attr(axapp, "AXFrontmost") == true then return true end
    app:activate(true)
  end, left(4), 0.2)
  dbg("exportXML: activated FCP, AXFrontmost=" .. tostring(front))

  -- Target the timeline's project rather than a browser selection.
  if not goTo(app, "Timeline", nil, "AXLayoutArea") then
    error("Window → Go To → Timeline didn't focus the timeline", 0)
  end
  dbg("exportXML: timeline focused")

  -- The menu title ends in a U+2026 ellipsis — read it off the menu bar rather
  -- than hardcoding the character.
  local function exportItem()
    for _, m in ipairs(attr(attr(axapp, "AXMenuBar"), "AXChildren") or {}) do
      if attr(m, "AXTitle") == "File" then
        for _, it in ipairs(attr((attr(m, "AXChildren") or {})[1], "AXChildren") or {}) do
          local t = attr(it, "AXTitle")
          if t and t:sub(1, 10) == "Export XML" then return it, t end
        end
      end
    end
  end
  local item, menuTitle = exportItem()
  if not item then
    error("File → Export XML… is missing from Final Cut's menu", 0)
  end
  -- Two things have to be true before this command works, and neither is
  -- instant: the timeline has to be the active target (the Go To above) and
  -- Final Cut has to revalidate its menus, which it does a BEAT after coming
  -- forward (measured ~1.4 s on 12.3). Selecting an item it still considers
  -- disabled does nothing at all — silently — so wait for the rising edge.
  -- SPEC's staleness warning is about trusting AXEnabled=true as proof that a
  -- *previous* action landed; as a readiness gate it is the honest signal, and
  -- the save panel appearing is what actually proves the command ran.
  if not waitFor(function()
        local it = exportItem()
        return it and attr(it, "AXEnabled") == true
      end, left(8), 0.1) then
    error("Final Cut reports “" .. menuTitle ..
          "” disabled — is a project open in the timeline?", 0)
  end
  dbg("exportXML: " .. menuTitle .. " enabled")

  if not app:selectMenuItem({ "File", menuTitle }) then
    error("File → " .. menuTitle ..
          " wouldn't select — is a project open in the timeline?", 0)
  end

  local panel = waitFor(function() return exportPanel(axapp) end, left(10), 0.05)
  if not panel then
    error("File → " .. menuTitle ..
          " opened no save panel — is a project open in the timeline?", 0)
  end
  dbg("exportXML: save panel up")

  local nameField = waitFor(function()
    return axById(panel, "saveAsNameTextField", 3)
  end, left(5), 0.05)
  if not nameField then
    error("the save panel has no name field (AXIdentifier saveAsNameTextField)", 0)
  end
  -- The pre-filled name IS the project name — read it before overwriting.
  local project = attr(nameField, "AXValue")
  if project then project = project:gsub("%.fcpxmld?$", "") end
  dbg("exportXML: project=" .. tostring(project))

  -- Folder: ⌘⇧G, because a path typed into the name field is taken literally.
  local dir = dest:match("^(.*)/[^/]+$")
  hs.eventtap.keyStroke({ "cmd", "shift" }, "g")
  local pathField = waitFor(function()
    return axById(panel, "PathTextField", 3)
  end, left(6), 0.05)
  if not pathField then
    error("⌘⇧G didn't open the save panel's Go To Folder sheet", 0)
  end
  pathField:setAttributeValue("AXFocused", true)
  sleep(0.15)
  pathField:setAttributeValue("AXValue", dir .. "/")
  if not waitFor(function() return attr(pathField, "AXValue") == dir .. "/" end,
                 left(2), 0.05) then
    error("couldn't set the Go To Folder path (it reads “" ..
          tostring(attr(pathField, "AXValue")) .. "”)", 0)
  end
  hs.eventtap.keyStroke({}, "return")
  if not waitFor(function() return axById(panel, "GoToWindow", 2, 60) == nil end,
                 left(5), 0.05) then
    error("the Go To Folder sheet wouldn't accept " .. dir, 0)
  end

  -- Prove the panel really moved before pressing Save: a Save into the wrong
  -- folder is exactly the silent-junk failure this whole detour exists to stop.
  local wantFolder = dir:match("([^/]+)$")
  local wherePop = axById(panel, "where popup", 3)
  if not waitFor(function() return attr(wherePop, "AXValue") == wantFolder end,
                 left(3), 0.05) then
    error(string.format("the save panel is in “%s”, not “%s” — refusing to Save",
                        tostring(attr(wherePop, "AXValue")),
                        tostring(wantFolder)), 0)
  end
  dbg("exportXML: navigated to " .. dir)

  -- Filename: no extension — FCP appends the one it is writing.
  local base = dest:match("([^/]+)$")
  nameField:setAttributeValue("AXFocused", true)
  sleep(0.15)
  nameField:setAttributeValue("AXValue", base)
  if not waitFor(function() return attr(nameField, "AXValue") == base end,
                 left(3), 0.05) then
    error("couldn't set the export filename (it reads “" ..
          tostring(attr(nameField, "AXValue")) .. "”)", 0)
  end

  local saveBtn = axById(panel, "OKButton", 3)
  if not saveBtn then
    error("the save panel has no Save button (AXIdentifier OKButton)", 0)
  end
  saveBtn:performAction("AXPress")
  if not waitFor(function()
        -- A sheet on the panel is Final Cut asking something (almost always
        -- "…already exists. Replace?"). Never answer it — the caller owns
        -- uniqueness, so an ask means the contract was broken.
        for _, c in ipairs(attr(panel, "AXChildren") or {}) do
          if attr(c, "AXRole") == "AXSheet" then
            error("the save panel asked a question (“" ..
                  tostring(rowText(c)) .. "”) — aborting rather than answering", 0)
          end
        end
        return exportPanel(axapp) == nil
      end, left(8), 0.1) then
    error("the save panel didn't close after Save", 0)
  end
  dbg("exportXML: saved, waiting for " .. dest)

  -- FCP writes the package after the panel closes.
  local file, bundle
  if not waitFor(function()
        file, bundle = exportArtifact(dest)
        return file ~= nil
      end, left(15), 0.1) then
    error("Final Cut wrote nothing to " .. dest .. ".fcpxmld (or .fcpxml)", 0)
  end
  -- …and writes it progressively: a half-written Info.fcpxml is truncated XML.
  local bytes
  if not waitFor(function()
        local a = hs.fs.attributes(file, "size")
        sleep(0.3)
        local b = hs.fs.attributes(file, "size")
        if a and b and a == b and b > 0 then bytes = b return true end
      end, left(12), 0.05) then
    error("the exported XML never stopped growing: " .. file, 0)
  end
  dbg(string.format("exportXML: wrote %s (%d bytes)", file, bytes))

  return { path = file, bundle = bundle, project = project, bytes = bytes }
end

-- Export the project open in FCP's timeline to <path>.fcpxmld / .fcpxml and
-- record the outcome in opts.resultFile.
--
-- `path` is an ABSOLUTE destination with NO extension (Final Cut appends what
-- it writes) and must not already exist — the caller owns uniqueness, because
-- the "Replace?" sheet is treated as an error rather than answered.
--
-- The result file is the contract, not stdout: the `hs` CLI reply channel
-- wedges routinely while the Lua side finishes fine, so callers background
-- `hs -c '…' >/dev/null 2>&1` and poll this file instead.
--   { ok = true,  path = "<…/Info.fcpxml>", bundle = "<….fcpxmld>",
--     project = "<name>", bytes = N, restored = true, ms = N }
--   { ok = false, error = "…", restored = true, ms = N }
function M.exportXML(path, opts)
  opts = opts or {}
  local resultFile = opts.resultFile or "/tmp/fcp-palette-export.json"
  local budget = tonumber(opts.timeout) or 30
  local t0 = hs.timer.secondsSinceEpoch()

  -- Breadcrumb, written before anything else can block. It is the only way a
  -- caller can tell "hs.ipc refused this request outright" (file still empty,
  -- CLI client gone) from "the export is running" (file says running) — the
  -- refusal is silent on this side and the client exits in both cases.
  writeJSON(resultFile, { running = true, started = t0 })

  -- Captured before anything blocks: this runs unattended, so the session must
  -- be handed back to whoever had the screen.
  local prev = focusedApp()

  local dest, err = tostring(path or ""), nil
  if dest:sub(1, 1) ~= "/" then
    err = "exportXML needs an absolute destination path, got “" .. dest .. "”"
  else
    dest = dest:gsub("/+$", ""):gsub("%.fcpxmld?$", "")
    local dir = dest:match("^(.*)/[^/]+$")
    if not dir or dir == "" then
      err = "exportXML needs a destination inside a folder, got “" .. dest .. "”"
    elseif hs.fs.attributes(dir, "mode") ~= "directory" then
      err = "destination folder doesn't exist: " .. dir
    elseif hs.fs.attributes(dest .. ".fcpxmld")
        or hs.fs.attributes(dest .. ".fcpxml") then
      err = "destination already exists: " .. dest .. " — pass a unique name"
    end
  end

  local res
  if not err then
    local ok, out = pcall(exportXMLRun, dest, t0, budget)
    if ok then res = out else err = tostring(out) end
  end

  -- A half-driven modal would wedge every later AX sequence, so always leave
  -- the panel closed.
  local app = fcp()
  local axapp = app and axApp(app)
  if err and axapp then
    local panel = exportPanel(axapp)
    if panel then
      local cancel = axById(panel, "CancelButton", 3)
      if cancel then cancel:performAction("AXPress")
      else hs.eventtap.keyStroke({}, "escape") end
      waitFor(function() return exportPanel(axapp) == nil end, 3, 0.1)
    end
  end

  local restored = true
  if prev and prev:bundleID() ~= M.config.fcpBundle then
    prev:activate(true)
    restored = waitFor(function()
      local f = focusedApp()
      return f and f:pid() == prev:pid()
    end, 3, 0.1) == true
  end

  local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000 + 0.5)
  local result
  if err then
    dbg("exportXML FAILED: " .. err)
    notify("FCPXML export failed: " .. err)
    result = { ok = false, error = err, restored = restored, ms = ms }
  else
    result = { ok = true, path = res.path, bundle = res.bundle,
               project = res.project, bytes = res.bytes,
               restored = restored, ms = ms }
  end
  writeJSON(resultFile, result)
  return result
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
