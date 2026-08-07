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
require("hs.json")
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
  local ok, data = pcall(hs.json.decode, f:read("*a"))
  f:close()
  return ok and data or nil
end

local function writeJSON(path, data)
  local f = io.open(path, "w")
  if f then f:write(hs.json.encode(data)) f:close() end
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
    notify("Connected “" .. choice.name .. "” at the playhead.")
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
    notify("Applied “" .. choice.name .. "” (" .. tostring(undoTitle(app)) .. ").")
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
      allChoices[#allChoices + 1] = {
        text = item.name,
        subText = item.category .. (item.set and (" · " .. item.set) or ""),
        id = id,
        name = item.name,
        category = item.category,
        thumb = item.thumb,
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
    out[#out + 1] = { text = "Search Titles & Generators for “" .. query .. "”",
                      subText = "raw FCP search", fallback = "sidebar", query = query }
    out[#out + 1] = { text = "Search Effects for “" .. query .. "”",
                      subText = "raw FCP search", fallback = "effects", query = query }
  end
  return out
end

-- ── Palette ──────────────────────────────────────────────────────────────

local chooser
local clickTap, keysTap, closeCanvas
local chromeTimer   -- anchored: unreferenced hs.timer objects get GC'd before firing

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
local imageCache = {}
local function withImages(list)
  for _, c in ipairs(list) do
    if c.thumb and not c.image then
      local img = imageCache[c.thumb]
      if img == nil then
        img = hs.image.imageFromPath(c.thumb) or false
        imageCache[c.thumb] = img
      end
      if img then c.image = img end
    end
  end
  return list
end

local function setChoices(list)
  chooser:choices(withImages(list))
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
end

local function chromeUp()
  chromeDown()
  clickTap:start()
  keysTap:start()
  moveToActiveScreen()   -- best-effort synchronous; retried below if the panel wasn't up yet
  chromeTimer = hs.timer.doAfter(0.1, function()
    if chooser:isVisible() then
      moveToActiveScreen()
      showCloseButton()   -- positions off the frame read AFTER the move
    end
  end)
end

local function showPalette()
  if not fcp() then
    notify("Final Cut Pro isn't running.")
    return
  end
  loadChoices()
  chooser:query("")
  setChoices(filteredChoices(""))
  -- chooser:width() is a percentage of the PRIMARY screen; convert so the
  -- panel is ~680px (Spotlight-ish) on whichever screen it will land on.
  local wpx = math.min(680, targetScreen():frame().w * 0.85)
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
