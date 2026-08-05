-- fcp-palette — Spotlight-style command palette for Final Cut Pro.
-- See SPEC.md. Wire up with:
--   package.path = package.path .. ";/Users/tylerpoelking/content/tools/fcp-palette/?.lua"
--   fcpPalette = require("fcp_palette"); fcpPalette.start()

local ax = require("hs.axuielement")

local M = {}

M.config = {
  hotkey    = { { "alt" }, "space" },
  stateDir  = os.getenv("HOME") .. "/content/tools/fcp-palette",
  fcpBundle = "com.apple.FinalCut",
  -- How long to let FCP's browser filter settle after typing a search (seconds).
  filterWait = 0.35,
}

local CATALOG_PATH  = M.config.stateDir .. "/catalog.json"
local FRECENCY_PATH = M.config.stateDir .. "/frecency.json"

-- Category → which FCP browser applies it, and how.
-- browser "sidebar" = Titles and Generators sidebar (connect with Q semantics);
-- browser "effects" = Effects browser (apply to selected clip).
local CATEGORIES = {
  Title          = { browser = "sidebar" },
  Generator      = { browser = "sidebar" },
  ["Video Effect"] = { browser = "effects" },
  ["Audio Effect"] = { browser = "effects" },
  -- Transitions are Phase 2 (nearest-edit targeting + modal guard) — hidden until then.
}

-- ── Small utils ──────────────────────────────────────────────────────────

local function readJSON(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local ok, data = pcall(hs.json.decode, f:read("*a"))
  f:close()
  return ok and data or nil
end

local function writeJSON(path, data)
  local f = io.open(path, "w")
  if not f then return end
  f:write(hs.json.encode(data))
  f:close()
end

local function notify(msg)
  hs.notify.new({ title = "FCP Palette", informativeText = msg }):send()
end

local function fcp()
  return hs.application.find(M.config.fcpBundle, true)
end

-- BFS for the first AX descendant matching pred, depth-capped.
local function findFirst(root, pred, maxDepth)
  local queue, i = { { root, 0 } }, 1
  while queue[i] do
    local el, d = queue[i][1], queue[i][2]
    i = i + 1
    if pred(el) then return el end
    if d < maxDepth then
      for _, c in ipairs(el:attributeValue("AXChildren") or {}) do
        queue[#queue + 1] = { c, d + 1 }
      end
    end
  end
end

local function role(el) return el and el:attributeValue("AXRole") end
local function subrole(el) return el and el:attributeValue("AXSubrole") end

-- A browser cell's display name: its own AXTitle/AXValue, else first static text child.
local function cellName(el)
  local t = el:attributeValue("AXTitle") or el:attributeValue("AXDescription")
  if t and t ~= "" then return t end
  local st = findFirst(el, function(e)
    return role(e) == "AXStaticText"
  end, 3)
  return st and (st:attributeValue("AXValue") or st:attributeValue("AXTitle"))
end

-- ── Frecency ─────────────────────────────────────────────────────────────

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

-- ── Catalog + choices ────────────────────────────────────────────────────

-- catalog.json: [{ name = "Low Pass", category = "Audio Effect" }, ...]
local function buildChoices()
  local catalog = readJSON(CATALOG_PATH) or {}
  local log = readJSON(FRECENCY_PATH) or {}
  local now = os.time()
  local choices = {}
  for _, item in ipairs(catalog) do
    if CATEGORIES[item.category] then
      choices[#choices + 1] = {
        text = item.name,
        subText = item.category,
        id = item.category .. "/" .. item.name,
        name = item.name,
        category = item.category,
      }
    end
  end
  table.sort(choices, function(a, b)
    local sa, sb = frecencyScore(log[a.id], now), frecencyScore(log[b.id], now)
    if sa ~= sb then return sa > sb end
    return a.text < b.text
  end)
  return choices
end

-- Case-insensitive subsequence match; word-start matches rank above scattered ones.
-- (Needed because queryChangedCallback disables hs.chooser's built-in filter,
-- and we need that callback for the live raw-search fallback rows.)
local function matchRank(query, hay)
  hay = hay:lower()
  if query == "" then return 1 end
  if hay:find(query, 1, true) then return 3 end
  local pos = 0
  for ch in query:gmatch(".") do
    pos = hay:find(ch, pos + 1, true)
    if not pos then return nil end
  end
  return 2
end

local function filteredChoices(all, query)
  local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local out = {}
  for _, c in ipairs(all) do
    local r = matchRank(q, c.text .. " " .. c.subText)
    if r then
      c._rank = r
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    if a._rank ~= b._rank then return a._rank > b._rank end
    return false -- stable: keep frecency presort among equals
  end)
  if q ~= "" then
    out[#out + 1] = { text = "Search Titles & Generators for “" .. query .. "”",
                      subText = "raw FCP search", fallback = "sidebar", query = query }
    out[#out + 1] = { text = "Search Effects for “" .. query .. "”",
                      subText = "raw FCP search", fallback = "effects", query = query }
  end
  return out
end

-- ── FCP driving ──────────────────────────────────────────────────────────

local function keystrokes(str) hs.eventtap.keyStrokes(str) end
local function key(mods, k) hs.eventtap.keyStroke(mods, k, 20000) end

-- Park the pointer over FCP's toolbar so the skimmer (which beats the playhead
-- for edit commands) can't be over the timeline when we connect/apply.
local function parkPointer(app)
  local win = app:mainWindow()
  if not win then return end
  local f = win:frame()
  hs.mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + 10 })
end

local function selectMenu(app, path)
  local ok = app:selectMenuItem(path)
  if not ok then notify("Menu not found: " .. table.concat(path, " → ")) end
  return ok
end

-- Show the right browser and return the AX element of FCP's main window.
local function openBrowser(app, which)
  if which == "sidebar" then
    if not selectMenu(app, { "Window", "Go To", "Titles and Generators" }) then return nil end
  else
    -- "Effects" under Show in Workspace is a toggle; only select it when unticked.
    local item = app:findMenuItem({ "Window", "Show in Workspace", "Effects" })
    if item and not item.ticked then
      selectMenu(app, { "Window", "Show in Workspace", "Effects" })
    end
    -- Focus it either way so the search field is reachable.
    selectMenu(app, { "Window", "Go To", "Effects" })
  end
  hs.timer.usleep(200000)
  local axApp = ax.applicationElement(app)
  return axApp and axApp:attributeValue("AXMainWindow")
end

-- The visible search field of the active browser. SPIKE-VERIFY: disambiguation
-- if multiple search fields are exposed at once.
local function browserSearchField(win)
  return findFirst(win, function(el)
    if subrole(el) ~= "AXSearchField" then return false end
    local f = el:attributeValue("AXFrame")
    return f and f.w > 0 and f.h > 0
  end, 14)
end

local function setSearch(field, text)
  field:setAttributeValue("AXFocused", true)
  hs.timer.usleep(100000)
  key({ "cmd" }, "a")
  key({}, "delete")
  if text and text ~= "" then keystrokes(text) end
  hs.timer.usleep(M.config.filterWait * 1000000)
end

-- First result cell in the browser under `win` after filtering.
local function firstResultCell(win)
  return findFirst(win, function(el)
    local r = role(el)
    return (r == "AXCell" or subrole(el) == "AXCollectionItem" or r == "AXGroup")
      and cellName(el) ~= nil
      and el:attributeValue("AXFrame") ~= nil
      and el:attributeValue("AXFrame").h > 0
      -- SPIKE-VERIFY: tighten this predicate to the browser's actual cell shape.
  end, 16)
end

local function timelineSelectionCount(win)
  local la = findFirst(win, function(el) return role(el) == "AXLayoutArea" end, 12)
  if not la then return nil end
  local sel = la:attributeValue("AXSelectedChildren")
  return sel and #sel or 0
end

local function backToTimeline(app)
  selectMenu(app, { "Window", "Go To", "Timeline" })
end

-- Find + select `name` in the browser; returns the cell or nil (with notify).
local function locateItem(app, which, name, verify)
  local win = openBrowser(app, which)
  if not win then return nil end
  local field = browserSearchField(win)
  if not field then
    notify("Couldn't find the browser search field.")
    return nil
  end
  setSearch(field, name)
  local cell = firstResultCell(win)
  if not cell then
    notify("No FCP result for “" .. name .. "”.")
    setSearch(field, "")
    return nil
  end
  local got = cellName(cell)
  if verify and got and got:lower() ~= name:lower() then
    notify("Top result is “" .. got .. "”, not “" .. name .. "” — aborted.")
    setSearch(field, "")
    return nil
  end
  return cell, field, win
end

local function clickCell(cell, double)
  local f = cell:attributeValue("AXFrame")
  local pt = { x = f.x + f.w / 2, y = f.y + f.h / 2 }
  if double then
    hs.eventtap.leftClick(pt, 20000)
    hs.timer.usleep(80000)
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, pt):setProperty(
      hs.eventtap.event.properties.mouseEventClickState, 2):post()
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pt):setProperty(
      hs.eventtap.event.properties.mouseEventClickState, 2):post()
  else
    hs.eventtap.leftClick(pt, 20000)
  end
end

-- ── Apply strategies ─────────────────────────────────────────────────────

-- Titles/Generators: select in sidebar browser, connect at the playhead (Q).
local function applyConnected(app, name, verify)
  local cell, field = locateItem(app, "sidebar", name, verify)
  if not cell then return false end
  clickCell(cell, false)                  -- select (single click; pointer now over browser, not timeline)
  hs.timer.usleep(150000)
  parkPointer(app)
  if not selectMenu(app, { "Edit", "Connect to Primary Storyline" }) then return false end
  hs.timer.usleep(150000)
  if field then setSearch(field, "") end  -- leave the browser clean
  backToTimeline(app)
  return true
end

-- Effects: ensure a clip is targeted, then double-click the effect cell.
local function applyEffect(app, name, verify)
  -- Target resolution BEFORE we disturb focus: selection, else clip under playhead.
  do
    local axApp = ax.applicationElement(app)
    local win = axApp and axApp:attributeValue("AXMainWindow")
    local count = win and timelineSelectionCount(win)
    if count == 0 or count == nil then
      -- C = Select Clip (clip under the playhead). Needs timeline focus and the
      -- pointer out of the timeline so the pointer-hover rule doesn't pick a
      -- different clip. SPIKE-VERIFY both.
      parkPointer(app)
      backToTimeline(app)
      hs.timer.usleep(100000)
      key({}, "c")
      hs.timer.usleep(150000)
    end
  end
  local cell, field = locateItem(app, "effects", name, verify)
  if not cell then return false end
  clickCell(cell, true)                   -- double-click applies to the selected clip
  hs.timer.usleep(200000)
  if field then setSearch(field, "") end
  backToTimeline(app)
  return true
end

local function applyChoice(choice)
  local app = fcp()
  if not app then
    notify("Final Cut Pro isn't running.")
    return
  end
  app:activate()
  hs.timer.usleep(150000)

  local ok
  if choice.fallback then
    -- Raw search: drive the browser with the typed text, no catalog, no verify —
    -- leave FCP showing the filtered browser for the user to pick from.
    local cell = locateItem(app, choice.fallback, choice.query, false)
    ok = cell ~= nil
    if ok then notify("FCP browser filtered to “" .. choice.query .. "” — pick and apply there.") end
  else
    local cat = CATEGORIES[choice.category]
    if cat.browser == "sidebar" then
      ok = applyConnected(app, choice.name, true)
    else
      ok = applyEffect(app, choice.name, true)
    end
    if ok then recordUse(choice.id) end
  end
end

-- ── Catalog scrape (Phase 1: visible/realized rows; Phase 1.5 adds scrolling) ──

local SCRAPE_SOURCES = {
  { which = "sidebar", sidebarItem = "Titles",     category = "Title" },
  { which = "sidebar", sidebarItem = "Generators", category = "Generator" },
  { which = "effects", sidebarItem = "All Video",  category = "Video Effect" },
  { which = "effects", sidebarItem = "All Audio",  category = "Audio Effect" },
}

function M.refreshCatalog()
  local app = fcp()
  if not app then
    notify("Final Cut Pro isn't running.")
    return
  end
  app:activate()
  local items, seen = {}, {}
  for _, src in ipairs(SCRAPE_SOURCES) do
    local win = openBrowser(app, src.which)
    if win then
      local field = browserSearchField(win)
      if field then setSearch(field, "") end
      -- Select the source's sidebar row (e.g. "All Video") so the list shows
      -- the whole category. SPIKE-VERIFY the row AX shape.
      local rowEl = findFirst(win, function(el)
        return (role(el) == "AXStaticText" or role(el) == "AXRow" or role(el) == "AXCell")
          and (cellName(el) == src.sidebarItem
               or el:attributeValue("AXValue") == src.sidebarItem)
      end, 14)
      if rowEl then
        local f = rowEl:attributeValue("AXFrame")
        if f then hs.eventtap.leftClick({ x = f.x + f.w / 2, y = f.y + f.h / 2 }, 20000) end
        hs.timer.usleep(300000)
      end
      -- Collect every named cell currently exposed by AX.
      local root = win
      local queue, i = { { root, 0 } }, 1
      while queue[i] do
        local el, d = queue[i][1], queue[i][2]
        i = i + 1
        local r = role(el)
        if (r == "AXCell" or subrole(el) == "AXCollectionItem") then
          local n = cellName(el)
          if n and not seen[src.category .. "/" .. n] then
            seen[src.category .. "/" .. n] = true
            items[#items + 1] = { name = n, category = src.category }
          end
        end
        if d < 16 then
          for _, c in ipairs(el:attributeValue("AXChildren") or {}) do
            queue[#queue + 1] = { c, d + 1 }
          end
        end
      end
    end
  end
  writeJSON(CATALOG_PATH, items)
  notify(("Catalog refreshed: %d items."):format(#items))
  backToTimeline(app)
end

-- ── Palette ──────────────────────────────────────────────────────────────

local chooser
local allChoices = {}

local function showPalette()
  if not fcp() then
    notify("Final Cut Pro isn't running.")
    return
  end
  allChoices = buildChoices()
  chooser:query("")
  chooser:choices(filteredChoices(allChoices, ""))
  chooser:show()
end

function M.start()
  chooser = hs.chooser.new(function(choice)
    if choice then applyChoice(choice) end
  end)
  chooser:queryChangedCallback(function(q)
    chooser:choices(filteredChoices(allChoices, q))
  end)
  chooser:placeholderText("Titles, generators, effects…")
  chooser:searchSubText(false) -- we filter ourselves
  M.hotkeyObj = hs.hotkey.bind(M.config.hotkey[1], M.config.hotkey[2], showPalette)
  return M
end

return M
