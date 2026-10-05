-- On-demand reference capture bridge. Loaded by the capture runner, not at login.
-- Only short UI transactions happen here; video encoding/validation lives outside
-- Hammerspoon so the editor and the Hammerspoon main thread are released promptly.
local M = {}
local ax = hs.axuielement
local operationDeadline
-- The last step reached, named in deadline errors and failure receipts.
local step
local function mark(s) step=s end
local function overdue() error('Capture UI deadline exceeded'..(step and (' at step '..step) or ''),0) end
local function a(e,k)
 if operationDeadline and hs.timer.secondsSinceEpoch()>operationDeadline then overdue() end
 if not e then return nil end
 e:setTimeout(2)
 return e:attributeValue(k)
end
local function sleep(s) hs.timer.usleep(s*1000000) end
local function wait(fn,seconds,step)
 local untilTime=hs.timer.secondsSinceEpoch()+(seconds or 5)
 repeat local v=fn(); if v then return v end; sleep(.1) until hs.timer.secondsSinceEpoch()>untilTime
 error('Timed out waiting for '..(step or 'Final Cut'),0)
end
local function find(root,pred,depth,heavy)
 if not root or (depth or 16)<0 then return nil end
 if pred(root) then return root end
 local role=a(root,'AXRole')
 if not heavy and (role=='AXLayoutArea' or role=='AXOutline' or role=='AXTable' or role=='AXGrid' or a(root,'AXDescription')=='inspector') then return nil end
 for _,e in ipairs(a(root,'AXChildren') or {}) do
  local hit=find(e,pred,(depth or 16)-1,heavy); if hit then return hit end
 end
end
local function id(root,value) return find(root,function(e) return a(e,'AXIdentifier')==value end) end
local function desc(root,value) return find(root,function(e) return a(e,'AXDescription')==value end) end
local function title(root,value) return find(root,function(e) return a(e,'AXTitle')==value or a(e,'AXValue')==value end) end
local function press(e) assert(e,'Required Final Cut control is missing'); e:performAction('AXPress') end
-- A disabled menu usually means focus went elsewhere mid-sequence; say so
-- rather than reporting a bare timeout.
local function menu(app,path)
 local label=table.concat(path,' > ')
 local ok,err=pcall(wait,function() local item=app:findMenuItem(path);return item and item.enabled end,5,'menu '..label)
 if not ok then
  local lost=fcpPalette.focusLost(app)
  error(lost and (lost..' while waiting for menu '..label) or err,0)
 end
 if not app:selectMenuItem(path) then
  error((fcpPalette.focusLost(app) or 'Final Cut menu unavailable')..': '..label,0)
 end
end
local function context()
 local app=assert(hs.application.find('com.apple.FinalCut',true),'Final Cut Pro is not running')
 return app,ax.applicationElement(app)
end
local function main(root)
 for _,w in ipairs(a(root,'AXWindows') or {}) do if a(w,'AXTitle')=='Final Cut Pro' then return w end end
end
local function projectName(root)
 return a(id(main(root),'editor/timelineContainer/toolbar/projectNamePopUpButton'),'AXTitle')
end
local function selectedName(root)
 local list=desc(main(root),'Organizer filmlist outline view')
 if not list then error('Capture requires the browser in list view',0) end
 local rows=a(list,'AXSelectedRows') or {}
 if #rows~=1 then error('Expected one selected project in the browser',0) end
 local field=find(rows[1],function(e) return a(e,'AXRole')=='AXTextField' end,4,true)
 return field and (a(field,'AXValue') or a(field,'AXTitle')),field
end
local function dialog(root)
 for _,w in ipairs(a(root,'AXWindows') or {}) do
  if a(w,'AXModal')==true then return w end
  local sheet=find(w,function(e) return a(e,'AXRole')=='AXSheet' end,2)
  if sheet then return sheet end
 end
end
local function refuseDialog(root,todo)
 local w=dialog(root)
 if not w then return end
 local t=a(w,'AXTitle')
 if type(t)~='string' or t=='' then t='untitled' end
 error('Final Cut dialog "'..t..'" is open; '..todo,0)
end
-- Our share window, only while unsubmitted: the destination's title and its Next… button.
local function ownedShare(root,opts)
 local w=dialog(root)
 local name=(opts.shareDestination or 'AI Reference…'):gsub('…$','')
 if w and a(w,'AXTitle')==name and title(w,'Next…') then return w end
end
-- nil when no owned share is open; else whether Final Cut then shows no dialog
-- (false on any error). Two presses at most: the first may only close a save
-- sheet over the share.
local function cancelOwnedShare(root,opts)
 local ok,closed=pcall(function()
  if not ownedShare(root,opts) then return nil end
  for _=1,2 do
   local w=ownedShare(root,opts)
   if not w then break end
   press(id(w,'CancelButton') or title(w,'Cancel'))
   pcall(wait,function() return not ownedShare(root,opts) end,3,'share dialog to close')
  end
  return not dialog(root)
 end)
 if ok then return closed end
 return false
end
local function assertProject(root,expected)
 local actual=projectName(root)
 if actual~=expected then error('Expected timeline '..tostring(expected)..', found '..tostring(actual),0) end
end

function M.snapshot(opts)
 local app,root=context()
 refuseDialog(root,'close it, then capture again')
 app:activate(true)
 wait(function() return a(root,'AXFrontmost')==true end,5,'Final Cut focus')
 menu(app,{'Window','Go To','Timeline'})
 wait(function() return a(a(root,'AXFocusedUIElement'),'AXRole')=='AXLayoutArea' end,5,'timeline focus')
 local source=assert(projectName(root),'No timeline open')
 mark('reveal-project')
 menu(app,{'File','Reveal Project in Browser'})
 local viewToggle=desc(main(root),'Show clips in list view')
 local changedView=viewToggle~=nil
 if changedView then press(viewToggle) end
 wait(function() local ok,n=pcall(selectedName,root); return ok and n==source end,8,'source project selection')
 mark('snapshot-project')
 menu(app,{'Edit','Snapshot Project'})
 local snapshot=wait(function()
  local ok,n=pcall(selectedName,root)
  return ok and n and n~=source and n:sub(1,#source)==source and n
 end,30,'new snapshot selection')
 opts._snapshot=snapshot;opts._source=source;opts._restoreFilmstrip=changedView
 -- Open the browser project explicitly. `Open Clip` can otherwise act on
 -- a selected timeline compound even while a browser project is selected.
 mark('open-snapshot')
 local selected,field=selectedName(root)
 if selected~=snapshot then error('Snapshot selection changed',0) end
 local frame=assert(a(field,'AXFrame'),'Snapshot row has no visible frame')
 hs.eventtap.leftClick({x=frame.x+frame.w/2,y=frame.y+frame.h/2})
 field:setAttributeValue('AXFocused',true)
 menu(app,{'Clip','Open Clip'})
 wait(function() return projectName(root)==snapshot end,10,'snapshot timeline')
 return {source_project=source,snapshot_project=snapshot,restore_filmstrip=changedView}
end

function M.beginShare(opts)
 mark('open-share')
 local app,root=context()
 assertProject(root,opts.snapshot_project)
 refuseDialog(root,'close it, then capture again')
 app:activate(true)
 wait(function() return a(root,'AXFrontmost')==true end,5,'Final Cut focus')
 menu(app,{'Window','Go To','Timeline'})
 wait(function() return a(a(root,'AXFocusedUIElement'),'AXRole')=='AXLayoutArea' end,5,'timeline focus')
 -- Export the whole project; a selected range would silently truncate it.
 menu(app,{'Mark','Clear Selected Ranges'})
 menu(app,{'File','Share',opts.shareDestination or 'AI Reference…'})
 -- From here a failure may cancel the share window, if ownedShare matches it.
 opts._ownsDialog=true
 mark('find-dialog')
 local w=wait(function() return dialog(root) end,10,'share dialog')
 return {dialog=a(w,'AXTitle')}
end

-- Read-only: the project open in the timeline and any open dialog's title.
-- Never activates Final Cut, presses anything or uses a menu.
function M.openProject(opts)
 local _,root=context()
 local w=dialog(root)
 local t=w and a(w,'AXTitle')
 if type(t)~='string' or t=='' then t=nil end
 return {project=projectName(root),dialog=t}
end

function M.exportSourceXML(opts)
 local _,root=context()
 refuseDialog(root,'close it, then capture again')
 local source=assert(projectName(root),'No project open')
 local result=fcpPalette.exportXML(opts.destination,{resultFile=opts.resultFile..'.xml',timeout=40})
 if not result.ok then error(result.error,0) end
 result.source_project=source
 return result
end

function M.exportXML(opts)
 local _,root=context();assertProject(root,opts.snapshot_project)
 local result=fcpPalette.exportXML(opts.destination,{resultFile=opts.resultFile..'.xml',timeout=40})
 if not result.ok then error(result.error,0) end
 return result
end

local function popupAfterLabel(w,label)
 local labelEl=find(w,function(e) return a(e,'AXRole')=='AXStaticText' and a(e,'AXValue')==label end)
 if not labelEl then error('Export label missing: '..label,0) end
 local seen=false
 for _,c in ipairs(a(a(labelEl,'AXParent'),'AXChildren') or {}) do
  if c==labelEl then seen=true elseif seen and a(c,'AXRole')=='AXPopUpButton' then return c end
 end
 error('No popup following '..label,0)
end

function M.share(opts)
 local _,root=context()
 if hs.fs.attributes(opts.destination) then error('Reference output already exists',0) end
 M.beginShare(opts)
 local w=dialog(root)
 if a(w,'AXTitle')~='AI Reference' then error('Unexpected export dialog; refusing to continue',0) end
 mark('read-settings')
 press(wait(function() return title(w,'Settings') end,5,'share Settings tab'))
 wait(function() return title(w,'H.264 Single-pass (Faster)') end,5,'share video codec')
 local settings={format=a(popupAfterLabel(w,'Format:'),'AXValue'),
  codec=a(popupAfterLabel(w,'Video Codec:'),'AXValue'),
  resolution=a(popupAfterLabel(w,'Resolution:'),'AXValue'),
  action=a(popupAfterLabel(w,'Action:'),'AXValue')}
 local want=tostring(opts.sequence.width)..' x '..tostring(opts.sequence.height)
 if settings.format~='Computer' or settings.codec~='H.264 Single-pass (Faster)' or settings.action~='Save only' then
  error('AI Reference preset changed; expected Computer / H.264 Single-pass (Faster) / Save only',0)
 end
 -- 12.4 opens the destination at a smaller default for tall canvases (a 9:16
 -- 2160 x 3840 project shows 1080 x 1920). Pick the exact canvas when the
 -- popup offers it, for this share only; the exact-size check below still
 -- refuses anything else, so the reference never scales.
 if settings.resolution~=want then
  mark('set-resolution')
  local pop=popupAfterLabel(w,'Resolution:')
  press(pop)
  local ok=pcall(function()
   press(wait(function()
    return find(pop,function(e) return a(e,'AXRole')=='AXMenuItem' and a(e,'AXTitle')==want end,4,true)
   end,3,'resolution '..want))
   wait(function() return a(pop,'AXValue')==want end,3,'resolution '..want)
  end)
  if not ok then
   if find(pop,function(e) return a(e,'AXRole')=='AXMenu' end,2,true) then hs.eventtap.keyStroke({},'escape') end
   error('AI Reference offers no exact '..want..' resolution (it reads '..tostring(a(pop,'AXValue'))..')',0)
  end
  settings.resolution_default=settings.resolution
  settings.resolution=want
 end
 -- The summary's dimensions field refreshes a beat after a resolution change.
 mark('check-output')
 local dims=function() return a(desc(w,'video dimensions'),'AXValue') end
 pcall(wait,function() return dims()==want end,3,'video dimensions')
 if settings.resolution~=want or dims()~=want then
  error('AI Reference resolution is not the exact timeline canvas '..want..': popup '..tostring(settings.resolution)..', output '..tostring(dims()),0)
 end
 if not title(w,'Standard - Rec. 709 (1-1-1)') then
  error('This preset is verified for SDR Rec.709 only; refusing an unverified color conversion',0)
 end
 local chapters=title(w,'Include chapter markers')
 if a(chapters,'AXValue')==1 then press(chapters) end
 local segmentation=title(w,'Allow export segmentation')
 if segmentation and a(segmentation,'AXEnabled')==true then
  if a(segmentation,'AXValue')~=1 then press(segmentation) end
  settings.segmentation=a(segmentation,'AXValue')==1
 else settings.segmentation='not available' end
 if a(desc(w,'kind'),'AXValue')~='.mp4' then error('Expected MP4 output',0) end
 settings.settings_state=M.inspect(opts).state
 settings.duration=a(desc(w,'duration'),'AXValue')
 settings.fps=a(desc(w,'video frame rate'),'AXValue')
 settings.dimensions=want
 mark('press-next')
 press(title(w,'Next…'))
 local function savePanel()
  for _,win in ipairs(a(root,'AXWindows') or {}) do
   if id(win,'saveAsNameTextField') then return win end
  end
 end
 mark('save-panel')
 local panel=wait(savePanel,5,'share save panel')
 -- Same exact-folder proof as Export XML (full-path suggestion, then the
 -- bidi-stripped Where popup), shared from the palette.
 local dir=opts.destination:match('^(.*)/[^/]+$')
 fcpPalette.goToSaveFolder(savePanel,dir,function(cap)
  local rem=(operationDeadline or math.huge)-hs.timer.secondsSinceEpoch()
  if rem<=0 then overdue() end
  return math.min(rem,cap or rem)
 end)
 panel=savePanel() or panel
 local name=id(panel,'saveAsNameTextField');name:setAttributeValue('AXValue',opts.destination:match('([^/]+)$'))
 wait(function() return a(name,'AXValue')==opts.destination:match('([^/]+)$') end,5,'share file name')
 -- Past Save the share may be queued: never cancel it from here on.
 mark('submit')
 opts._ownsDialog=false
 press(id(panel,'OKButton'))
 wait(function() return not dialog(root) end,10,'share dialog to close after Save')
 settings.queued_at=hs.timer.secondsSinceEpoch()
 return settings
end

function M.background(opts)
 local app,root=context()
 menu(app,{'Window','Background Tasks'})
 local w=wait(function()
  for _,win in ipairs(a(root,'AXWindows') or {}) do if a(win,'AXTitle')=='Background Tasks' then return win end end
 end,5,'Background Tasks window')
 local lines={}
 local function walk(e,d)
  if d>8 then return end
  for _,key in ipairs({'AXTitle','AXDescription','AXValue'}) do local v=a(e,key);if type(v)=='string' and v~='' then lines[#lines+1]=v end end
  for _,ch in ipairs(a(e,'AXChildren') or {}) do walk(ch,d+1) end
 end
 walk(w,0)
 press(a(w,'AXCloseButton'))
 return {background=table.concat(lines,' | ')}
end

function M.restore(opts)
 local app,root=context()
 assertProject(root,opts.snapshot_project)
 local out={restored_project=opts.source_project}
 -- The caller allows this only after a failed share: close that share window.
 if opts.cancel_owned_share then
  mark('cancel-share')
  out.dialog_cancelled=cancelOwnedShare(root,opts)
 end
 mark('restore')
 refuseDialog(root,'close it, then return to the source project by hand')
 app:activate(true)
 wait(function() return a(root,'AXFrontmost')==true end,5,'Final Cut focus')
 menu(app,{'Window','Go To','Timeline'})
 local back=id(main(root),'editor/timelineContainer/toolbar/timelineNavigationBackButton')
 if a(back,'AXEnabled')~=true then error('Timeline history cannot return to the source project',0) end
 press(back)
 wait(function() return projectName(root)==opts.source_project end,5,'source project timeline')
 if opts.restore_filmstrip then press(desc(main(root),'Show clips in filmstrip view')) end
 return out
end

-- Diagnostic dump is deliberately bounded and excludes huge timeline/browser
-- subtrees. It is also used to record the exact export settings in receipts.
function M.inspect(opts)
 local _,root=context();local lines={}
 local function walk(e,d)
  if not e or d>16 then return end
  local role=a(e,'AXRole');local s=string.rep(' ',d)..tostring(role)
  for _,k in ipairs({'AXIdentifier','AXTitle','AXDescription','AXValue','AXEnabled'}) do
   local v=a(e,k); if type(v)=='string' or type(v)=='number' or type(v)=='boolean' then s=s..' '..k..'='..tostring(v) end
  end
  lines[#lines+1]=s
  if role=='AXLayoutArea' or role=='AXOutline' or role=='AXGrid' or role=='AXTable' or a(e,'AXDescription')=='inspector' then return end
  for _,c in ipairs(a(e,'AXChildren') or {}) do walk(c,d+1) end
 end
 local w=dialog(root)
 if w then walk(w,0) else walk(main(root),0) end
 return {state=table.concat(lines,'\n'),project=projectName(root)}
end

function M.run(action,opts)
 opts=opts or {}; local file=assert(opts.resultFile,'resultFile required')
 local function write(v) local f=assert(io.open(file..'.tmp','w'));f:write(hs.json.encode(v));f:close();os.rename(file..'.tmp',file) end
 local start=hs.timer.secondsSinceEpoch()
 operationDeadline=start+(opts.timeout or 50)
 step=nil
 write({state='running',action=action,started=start})
 local ok,result=pcall(function() return assert(M[action],'Unknown capture action')(opts) end)
 operationDeadline=nil
 local cancelled
 if not ok and opts._ownsDialog then
  local cok,_,root=pcall(context)
  cancelled=cok and cancelOwnedShare(root,opts)
 end
 local out=ok and result or {error=tostring(result)}
 if not ok then
  out.snapshot_project=opts._snapshot;out.source_project=opts._source;out.restore_filmstrip=opts._restoreFilmstrip
  out.step=step;out.dialog_cancelled=cancelled
 end
 out.ok=ok;out.operation=action;out.ms=math.floor((hs.timer.secondsSinceEpoch()-start)*1000)
 write(out)
 return out
end
return M
