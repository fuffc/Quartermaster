-- Quartermaster -- Notify
-- A central floating-message area. Any module raises a transient on-screen line
-- with QM.notify(text, opts); lines stack, age out after options.notify.duration,
-- and fade over their last moment of life. This file is the *sink* + presentation
-- only -- the triggers (low repair, low/expiring/lost consumables, ...) live in the
-- feature modules and call in here, so the look + placement are uniform and there
-- is one notify frame to position instead of one per feature.

local QM = Quartermaster
QM.Notify = {}
local N = QM.Notify

local NOTIFY_MAX  = 6     -- max simultaneous lines (a burst can't run away)
local NOTIFY_FADE = 1.0   -- seconds of fade-out at the end of a line's life
local NOTIFY_PAD  = 6     -- text inset from whichever edge(s) the frame is anchored to

local NOTIFY_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Severity -> colour for a whole line. Callers that build multi-colour text (a name
-- spliced with label text) pass no severity and colour the pieces themselves.
local SEVERITY = {
	info  = "ffffffff",
	good  = "ff40ff40",
	warn  = "ffff8000",
	alert = "ffff2020",
}

local lines     = {}   -- pooled font strings, by display row
local active    = {}   -- live lines, newest first: { born = GetTime(), text = }
local lastKeyAt = {}   -- dedupe key -> GetTime() of last show (anti-spam, see QM.notify)

local function notifyDB() return QM.db and QM.db.options.notify end
local function layoutDB() return QM.db and QM.db.frames.notify end

-- Wrap non-name label text in the default yellow (matches FearWardHelper's look);
-- item/character names are coloured by the caller, everything else reads as this.
function N.label(text)
	return "|cffffd200" .. (text or "") .. "|r"
end

-- Whether notifications (optionally of a given category toggle) should show.
function N.enabled(category)
	local o = notifyDB()
	if not o or o.enabled == false then return false end
	if category == nil then return true end
	return o[category] ~= false
end

local function getLine(i)
	if not lines[i] then
		lines[i] = Quartermaster_Notify:CreateFontString(nil, "OVERLAY")
	end
	return lines[i]
end

-- The anchor corner doubles as the line alignment + growth direction:
--   horizontal -- LEFT -> left-aligned, RIGHT -> right-aligned, else centred;
--   vertical   -- TOP -> grow down, BOTTOM or vertical-centre -> grow up.
-- Returns the line anchor point, JustifyH, and the vertical stack sign (newest line
-- sits at the anchor edge, older ones stack away).
function N.alignment()
	local point = (layoutDB() and layoutDB().point) or "CENTER"
	local hEdge, justify
	if string.find(point, "LEFT") then hEdge, justify = "LEFT", "LEFT"
	elseif string.find(point, "RIGHT") then hEdge, justify = "RIGHT", "RIGHT"
	else hEdge, justify = "", "CENTER" end
	local vEdge, grow
	if string.find(point, "TOP") then vEdge, grow = "TOP", -1   -- grow down
	else vEdge, grow = "BOTTOM", 1 end                          -- grow up (BOTTOM/centre)
	return vEdge .. hEdge, justify, grow
end

-- Inset (px, py) nudging text in from whichever edges `anchor` touches, so a
-- corner-anchored line/handle clears the frame border instead of escaping it.
function N.padOffset(anchor)
	local px, py = 0, 0
	if string.find(anchor, "LEFT") then px = NOTIFY_PAD
	elseif string.find(anchor, "RIGHT") then px = -NOTIFY_PAD end
	if string.find(anchor, "TOP") then py = -NOTIFY_PAD
	elseif string.find(anchor, "BOTTOM") then py = NOTIFY_PAD end
	return px, py
end

-- (Re)position + paint the active lines. Newest sits at the anchor edge; older lines
-- stack away from it. Line height (and the font) tracks the configurable font size.
local function layout()
	if not Quartermaster_Notify then return end
	local size = (notifyDB() and notifyDB().fontSize) or 14
	local lineH = size + 4
	local anchor, justify, grow = N.alignment()
	local px, py = N.padOffset(anchor)
	local n = table.getn(active)
	for i = 1, n do
		local fs = getLine(i)
		fs:SetFont("Fonts\\FRIZQT__.TTF", size, "OUTLINE")
		fs:SetJustifyH(justify)
		fs:ClearAllPoints()
		fs:SetPoint(anchor, Quartermaster_Notify, anchor, px, py + grow * (i - 1) * lineH)
		fs:SetText(active[i].text)
		fs:Show()
	end
	for i = n + 1, table.getn(lines) do lines[i]:Hide() end
end
N.layout = layout

-- Prepend a (already colour-coded) line; past NOTIFY_MAX the oldest is dropped so a
-- spam burst stays bounded. The public entry point is QM.notify below.
local function push(text)
	if not Quartermaster_Notify then return end
	table.insert(active, 1, { born = GetTime(), text = text })
	while table.getn(active) > NOTIFY_MAX do table.remove(active) end
	layout()
end

-- Raise a notification. opts (all optional):
--   severity  "info" | "good" | "warn" | "alert" -- colours the whole line
--   category  a notify toggle key (e.g. "lowRepair") -- suppressed when that
--             category (or the master enable) is off
--   key       a dedupe key; re-raising the same key within `cooldown` is skipped,
--             so a module may safely call this every TICK without spamming
--   cooldown  the dedupe window in seconds (default = the notification duration)
function QM.notify(text, opts)
	if not text then return end
	opts = opts or {}
	if not N.enabled(opts.category) then return end
	if opts.key then
		local now = GetTime()
		local cd = opts.cooldown or (notifyDB() and notifyDB().duration) or 5
		if lastKeyAt[opts.key] and now - lastKeyAt[opts.key] < cd then return end
		lastKeyAt[opts.key] = now
	end
	local c = opts.severity and SEVERITY[opts.severity]
	if c then text = "|c" .. c .. text .. "|r" end
	push(text)
end

-- Clear an anti-spam key early, so the next QM.notify with it fires immediately.
-- A trigger calls this on the *falling* edge (e.g. durability back above threshold)
-- to re-arm its warning, the way FearWardHelper re-arms its low-duration notice.
function N.rearm(key)
	if key then lastKeyAt[key] = nil end
end

-- Per-frame ageing + fade, bound to the notify frame's own OnUpdate so the fade is
-- smooth and independent of Core's 0.5s TICK. Cheap when idle (active is empty).
local function update()
	local n = table.getn(active)
	if n == 0 then return end
	local now = GetTime()
	local dur = (notifyDB() and notifyDB().duration) or 5
	local removed = false
	local i = 1
	while i <= table.getn(active) do
		if now - active[i].born >= dur then
			table.remove(active, i); removed = true
		else
			i = i + 1
		end
	end
	if removed then layout() end
	for j = 1, table.getn(active) do
		local fs = lines[j]
		if fs then
			local age = now - active[j].born
			local a = 1
			if age > dur - NOTIFY_FADE then
				a = (dur - age) / NOTIFY_FADE
				if a < 0 then a = 0 end
			end
			fs:SetAlpha(a)
		end
	end
end

-- Drop every transient line + dedupe key (exposed for a clean slate, e.g. reload).
function N.clear()
	active = {}
	lastKeyAt = {}
	layout()
end

-- ---------------------------------------------------------------------------
-- Config-facing setters (used by the Notifications tab)
-- ---------------------------------------------------------------------------

function N.setDuration(n)
	if not n then return end
	if n < 1 then n = 1 elseif n > 60 then n = 60 end
	if notifyDB() then notifyDB().duration = n end
end

function N.setFontSize(n)
	if not n then return end
	if n < 8 then n = 8 elseif n > 32 then n = 32 end
	if notifyDB() then notifyDB().fontSize = n end
	layout()   -- re-font the live lines
end

function N.setPoint(point)
	if Quartermaster_Notify then
		QM.setFrameAnchor(Quartermaster_Notify, point)   -- keeps it visually in place
	elseif layoutDB() then
		layoutDB().point = point
	end
	layout()   -- re-place lines for the new alignment/growth direction
end

-- Push sample lines so the area can be positioned while configuring (bypasses the
-- category/enable gates on purpose, so it previews even with notifications off).
function N.test()
	push(N.label("Durability low -- worst item at ") .. "|cffff800028%|r")
	push(N.label("Low stock: ") .. "|cffffffffGreater Healing Potion|r" .. N.label(" (4/20)"))
	push(N.label("Running low: ") .. "|cffffffffMongoose|r" .. N.label(" -- 2:00 left"))
	push("|cffff2020Flask of the Titans dropped|r")
	push("|cff40ff40Repaired for 1g 20s 0c|r")
end

-- ---------------------------------------------------------------------------
-- Frame hooks (Quartermaster_Notify in the XML) + config tab
-- ---------------------------------------------------------------------------

-- Lock cue: a faint grab box + handle while unlocked (so it can be positioned),
-- fully transparent once locked so only the notification lines show. The handle is
-- aligned to the notification anchor edge to preview where lines will appear.
local function onLock(frame, locked)
	frame:SetBackdropColor(0, 0, 0, locked and 0 or 0.6)
	frame:SetBackdropBorderColor(1, 1, 1, locked and 0 or 0.5)
	local handle = getglobal(frame:GetName() .. "Handle")
	if handle then
		local anchor, justify = N.alignment()
		local px, py = N.padOffset(anchor)
		handle:ClearAllPoints()
		handle:SetPoint(anchor, frame, anchor, px, py)
		handle:SetJustifyH(justify)
		if locked then handle:Hide() else handle:Show() end
	end
end

function Quartermaster_Notify_OnLoad()
	this:SetBackdrop(NOTIFY_BACKDROP)
	this:SetBackdropColor(0, 0, 0, 0)         -- invisible until DB_READY paints the
	this:SetBackdropBorderColor(1, 1, 1, 0)   -- lock cue (avoids a load-time flash)
	-- Follows the global lock + persists position via Core's moveable system; the
	-- DB isn't ready yet, so registerMoveable defers the actual layout to DB_READY.
	QM.registerMoveable(this, "notify", onLock)
	this:Show()
end

function Quartermaster_Notify_OnUpdate()
	if not QM.db then return end   -- ticks before VARIABLES_LOADED
	update()
end

-- No Notifications config tab: the strip's look + master switch live on the Display tab, its
-- per-category triggers on the feature tabs that raise them (Tracker, Repair). This module is
-- just the sink + the N.* API those tabs call (setDuration / setFontSize / setPoint / test).
