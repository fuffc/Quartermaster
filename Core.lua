-- Quartermaster -- Core
-- Shared namespace, SavedVariables model, per-character registry, bag/bank
-- scanning, the event hub + OnUpdate driver every module hooks, money/item
-- helpers, the desired-list setters, and the slash command. See CLAUDE.md.
--
-- Multi-file addon: files share state through the global `Quartermaster` table
-- (aliased `local QM = Quartermaster` at the top of each file), because 1.12 has
-- no per-file addon-table vararg. Load order (see the .toc): Core first (it
-- creates the engine frame, so QM.on works the instant a module loads), then the
-- feature modules, then Config, then the XML. Modules register their WoW events
-- (QM.on), internal signals (QM.subscribe) and config tabs (QM.registerConfigTab)
-- at load time; Core dispatches them.

Quartermaster = Quartermaster or {}
local QM = Quartermaster

QM.name    = "Quartermaster"
QM.version = "0.1.0"

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

function QM.print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffQuartermaster|r: " .. tostring(msg))
end

-- copper -> "Ng Ns Nc" (coloured)
function QM.money(copper)
	copper = copper or 0
	local g = math.floor(copper / 10000)
	local s = math.floor(math.mod(copper, 10000) / 100)
	local c = math.mod(copper, 100)
	return g .. "|cffffd700g|r " .. s .. "|cffc7c7cfs|r " .. c .. "|cffeda55fc|r"
end

function QM.trim(s)
	if not s then return "" end
	return string.gsub(s, "^%s*(.-)%s*$", "%1")
end

-- Seconds -> a compact timer: "Ns" under a minute, "M:SS" under an hour, "H:MM:SS" above.
function QM.fmtTime(sec)
	if not sec then return "" end
	sec = math.floor(sec + 0.5)
	if sec < 0 then sec = 0 end
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then
		local m = math.floor(sec / 60)
		return string.format("%d:%02d", m, sec - m * 60)
	end
	local h = math.floor(sec / 3600)
	local m = math.floor(math.mod(sec, 3600) / 60)
	return string.format("%d:%02d:%02d", h, m, math.mod(sec, 60))
end

-- itemID out of an item link / item string ("...item:6948:0:0:0...").
function QM.itemID(link)
	if not link then return nil end
	local _, _, id = string.find(link, "item:(%d+)")
	if id then return tonumber(id) end
end

-- ---------------------------------------------------------------------------
-- SavedVariables model (account-wide; QuartermasterDB)
-- ---------------------------------------------------------------------------
-- Account-wide so a bank/mule alt can see what the raid character WANTS and what
-- it already HAS. Per-character desired sets + inventory snapshots live under
-- .chars[key]; global options/layout sit at the top level.

local defaults = {
	options = {
		locked          = false,
		showWhenSolo    = true,
		autoRepair      = true,
		repairThreshold = 35,    -- warn when worst item durability % is below this
		reagentRestock  = true,
		fillStacksFirst = true,  -- top up partial stacks before making new ones
		rowOrder        = "config", -- tracker row order: "config" | "active" | "duration"
		guardReuse      = false, -- block a HUD consume while the buff is up above the low threshold (shift forces)
		transfer = {
			dumpTrackedOverage = true, -- /qm banksync also banks tracked-list qty above target
			mailTrackedOverage = true, -- Dump Excess also mails tracked-list qty above target
			                           -- to the default mail recipient, when one is set
		},
		-- In-raid tracker HUD (Quartermaster_Main) display options (General tab).
		hudHidden       = false, -- master hide of the tracker HUD
		showTargetCount = true,  -- HUD count column shows "have/target" vs just "have"
		showItemName    = true,  -- HUD shows the item-name column
		abbreviateNames = false, -- shorten overlong names (words to initials) to fit the column
		hudOutline      = false, -- HUD row text drawn with a black outline
		barTexture      = 2,     -- index into the HUD progress-bar texture list (see Consumables)
		buffLowDuration = 180,   -- seconds: a buff under this is "running low" (orange + notify)
		showBuffIds     = true,  -- inject the spell id into player-buff tooltips (SuperWoW only)
		hudHeader       = true,  -- show the "Quartermaster" title at the top of the tracker HUD
		hudProfileSwitch    = false, -- show a profile-switch drop row on the tracker HUD (only
		                             -- ever drawn when the character has 2+ profiles)
		hudProfileSwitchPos = "top", -- "top" | "bottom" -- which end of the HUD it sits at
		hudRepairRow    = false, -- show a worst-equipped-durability status row on the tracker HUD
		hudRepairRowPos = "top", -- "top" | "bottom" -- which end it sits at; shares an edge with
		                         -- the profile-switch row rather than displacing it (see renderHUD)
		-- Central notification settings (see Notify.lua). The per-category toggles
		-- gate what the feature modules raise; the feature triggers themselves are
		-- elsewhere (low repair in Repair, low/expiring/lost consumes in Consumables).
		notify = {
			enabled            = true,
			duration           = 5,    -- seconds a line stays before it fades out
			fontSize           = 14,
			lowRepair          = true, -- worst item durability under the threshold
			lowConsumable      = true, -- a tracked consumable below its target
			consumableExpiring = true, -- an active consumable buff running low
			consumableLost     = true, -- an active consumable buff dropped
		},
	},
	frames = {
		main   = { point = "CENTER", x = 0, y = 0,   scale = 1.0, width = 220 },
		notify = { point = "CENTER", x = 0, y = 150, scale = 1.0, width = 240 },
		config = { width = 720, height = 420 },  -- the /qm panel size (user-resizable)
		-- No entry for the mail panel (Quartermaster_Mail): it isn't part of this
		-- UIParent-relative moveable system -- it anchors live to Blizzard's MailFrame
		-- instead (see Transfer.lua's anchorMailFrame).
	},
	-- Account-wide, item-INTRINSIC tracking metadata (Track / match / maxDuration);
	-- see ItemMeta.lua. Sparse: holds only fields a user or detect-on-consume has
	-- changed away from the curated seed -- so seed updates still reach everyone.
	items = {},  -- [itemID] = { track=, match={by=,value=}, maxDuration=, icon= }
	chars = {},  -- [charKey] = char record (see newCharRecord)
	mailRecipients = {}, -- custom recipient names for Transfer (see QM.addMailRecipient)
}

-- A fresh per-character record. Desired sets are PER CHARACTER (the raid char
-- defines what it wants); the inventory snapshot lets other chars read it.
local function newCharRecord()
	-- consumables is an ALIAS of profiles[activeProfile] (the same table); the alias is
	-- re-established on every load/switch, so profiles is the authority across sessions.
	local list = {}
	return {
		class       = nil,
		faction     = nil,
		realm       = nil,
		lastSeen    = 0,
		consumables = list, -- ordered: { {id=, name=, icon=, quality=, target=, low=, state=, apply=}, ... }
		profiles    = { ["Default"] = list },  -- [name] = list (same row shape)
		activeProfile = "Default",
		reagents    = {},   -- same shape; an apply="restock" entry buys up to `target` at a vendor
		-- Items to proactively shed (Transfer.lua): { {id=, name=, icon=, quality=,
		-- target=, state=, bankable=, mailRecipient=}, ... }. `target` here means "Keep" --
		-- the floor to leave behind; no `low` (no warn-threshold concept for this list).
		transferable = {},
		defaultMailRecipient = nil, -- used when a transferable row's mailRecipient is nil
		mailTarget = nil,   -- { char=, profile= }: this character's last-picked "supply
		                    -- another character" target (Transfer tab dropdowns / /qm mailsync)
		inventory   = {},   -- [itemID] = { name=, icon=, quality=, bags=, bank=, total= }
		inventoryAt = 0,
		durability  = nil,  -- { worst = pct, scannedAt = time() }
		-- [itemID] = amount another character has already mailed THIS character to cover
		-- a tracked-list shortfall, sent but not yet picked up from the mailbox -- a
		-- virtual stock count so a second mule doesn't also ship the same shortfall (see
		-- QM.addInFlight/QM.clearInFlight, T.supplyPlan). Never written for dumped excess.
		inFlight    = {},
	}
end

local function applyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			applyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

function QM.charKey()
	return UnitName("player")
end

-- Register / refresh this character's record. QM.me points at it for the session.
function QM.registerChar()
	local db = QuartermasterDB
	if not db then return end
	local key = QM.charKey()
	if not key then return end
	if not db.chars[key] then db.chars[key] = newCharRecord() end
	local c = db.chars[key]
	local _, class = UnitClass("player")
	c.class   = class
	c.realm   = GetRealmName()
	c.faction = UnitFactionGroup("player")
	c.lastSeen = time()
	c.consumables  = c.consumables or {}
	c.reagents     = c.reagents or {}
	c.transferable = c.transferable or {}
	c.inventory    = c.inventory or {}
	c.inFlight     = c.inFlight or {}
	if not c.profiles then
		c.profiles = { ["Default"] = c.consumables }
		c.activeProfile = "Default"
	end
	QM.me = c
	return c
end

-- Iterate every known character record: cb(key, record).
function QM.eachChar(cb)
	if not QM.db then return end
	for key, rec in pairs(QM.db.chars) do cb(key, rec) end
end

-- ---------------------------------------------------------------------------
-- Bag / bank scanning -> per-character inventory snapshot
-- ---------------------------------------------------------------------------

local BANK_CONTAINER = -1

-- bag, slot of the first stack of itemID found in the carried bags (0..4), or nil.
function QM.findBagSlot(itemID)
	for bag = 0, 4 do
		local slots = GetContainerNumSlots(bag)
		for slot = 1, (slots or 0) do
			local link = GetContainerItemLink(bag, slot)
			if link and QM.itemID(link) == itemID then return bag, slot end
		end
	end
end

local function scanContainer(bag, inv, where)
	local slots = GetContainerNumSlots(bag)
	if not slots then return end
	for slot = 1, slots do
		local link = GetContainerItemLink(bag, slot)
		if link then
			local id = QM.itemID(link)
			if id then
				local texture, count = GetContainerItemInfo(bag, slot)
				count = count or 1
				-- Charged items (oils, wands) report their stack count as a NEGATIVE charge
				-- count on 1.12; normalise to a positive "applications available" count.
				if count < 0 then count = -count end
				local e = inv[id]
				if not e then
					e = { bags = 0, bank = 0, total = 0, icon = texture }
					inv[id] = e
				end
				e[where] = (e[where] or 0) + count
				e.total  = e.total + count
				if not e.icon then e.icon = texture end
			end
		end
	end
end

-- Rebuild QM.me.inventory. Bags are always rescanned; the bank is only read when
-- it is actually open (BANKFRAME), otherwise we carry forward the last-known bank
-- counts so the prep view still shows where stock is sitting.
function QM.scanInventory()
	local c = QM.me
	if not c then return end
	local old = c.inventory or {}
	local inv = {}
	for bag = 0, 4 do scanContainer(bag, inv, "bags") end

	if QM.bankOpen then
		scanContainer(BANK_CONTAINER, inv, "bank")
		local n  = NUM_BAG_SLOTS or 4
		local nb = NUM_BANKBAGSLOTS or 6
		for bag = n + 1, n + nb do scanContainer(bag, inv, "bank") end
	else
		-- carry forward last-known bank counts (we can't read the bank when closed)
		for id, e in pairs(inv) do
			local oe = old[id]
			if oe and oe.bank and oe.bank > 0 then
				e.bank  = oe.bank
				e.total = e.total + oe.bank
			end
		end
		for id, oe in pairs(old) do
			if not inv[id] and oe.bank and oe.bank > 0 then
				inv[id] = { bags = 0, bank = oe.bank, total = oe.bank, icon = oe.icon }
			end
		end
	end

	c.inventory   = inv
	c.inventoryAt = time()
	QM.fire("INVENTORY_UPDATED")
end

-- have-counts for an itemID on THIS character. Returns bags, bank, total.
function QM.itemCount(itemID)
	local c = QM.me
	local e = c and c.inventory and c.inventory[itemID]
	if not e then return 0, 0, 0 end
	return (e.bags or 0), (e.bank or 0), (e.total or 0)
end

-- ---------------------------------------------------------------------------
-- In-flight mail stock: a SENDING character marks amount as heading toward
-- charKey (QM.addInFlight) when it queues a supply mail; the RECEIVING
-- character's own session clears it (QM.clearInFlight) once the item is
-- actually taken from its mailbox (see Transfer.lua's TakeInboxItem hook).
-- Lets T.supplyPlan treat it as virtual stock so a second mule doesn't also
-- ship the same shortfall before the first mail is picked up.
-- ---------------------------------------------------------------------------

function QM.addInFlight(charKey, itemID, amount)
	if not (QM.db and charKey and itemID and amount and amount > 0) then return end
	local c = QM.db.chars[charKey]
	if not c then return end
	c.inFlight = c.inFlight or {}
	c.inFlight[itemID] = (c.inFlight[itemID] or 0) + amount
end

function QM.inFlightCount(charKey, itemID)
	local c = QM.db and QM.db.chars[charKey]
	local n = c and c.inFlight and c.inFlight[itemID]
	return n or 0
end

function QM.clearInFlight(charKey, itemID, amount)
	local c = QM.db and QM.db.chars[charKey]
	local n = c and c.inFlight and c.inFlight[itemID]
	if not n then return end
	n = n - (amount or n)
	if n > 0 then c.inFlight[itemID] = n else c.inFlight[itemID] = nil end
end

-- ---------------------------------------------------------------------------
-- Desired-list setters (used by both the slash add and the config list editor)
-- ---------------------------------------------------------------------------
-- kind is "consumables" or "reagents". `target` is the prep amount and,
-- for a restock=true entry, the buy-up-to cap.

-- Resolve user text (an item link, a bare itemID, or a name). On 1.12 GetItemInfo
-- accepts a name and returns its link IF the client has the item cached (i.e. has
-- seen it this session or in a prior one) -- so names DO work for the consumables a
-- raider has actually handled; only never-seen items fall through and need a link/ID.
local function resolveItem(text)
	text = QM.trim(text)
	if text == "" then return nil end
	-- item link / item string ("...item:6948:0:0:0...")
	local id = QM.itemID(text)
	-- a bare numeric item ID
	if not id then id = tonumber(text) end
	-- a bare name: look it up in the ItemDB name->id index (built by scanning the
	-- client item cache, the way aux does), then fall back to a direct GetItemInfo
	-- in case the index hasn't reached that id yet but the client has it cached.
	if not id and QM.resolveName then id = QM.resolveName(text) end
	if not id then
		local _, link = GetItemInfo(text)
		if link then id = QM.itemID(link) end
	end
	if not id then return nil end
	-- On this 1.12 client GetItemInfo's texture is the 9th return (name, link, quality,
	-- level, type, subtype, stack, equipLoc, TEXTURE) -- not the 10th. Querying by the
	-- "item:ID" string is the form aux uses and resolves reliably. type/subType are the
	-- LOCALIZED item class/subclass (slots 5/6), used by the per-kind add validators.
	local name, _, quality, _, itype, isub, _, _, icon = GetItemInfo("item:" .. id)
	return id, name, icon, quality, itype, isub
end

-- Per-kind add validators: a module may register QM.itemValidators[kind] =
-- function(id, name, itype, isub) -> ok[, reason[, meta[, omit]]]. addDesired rejects the
-- add on a false return (Consumables uses this to keep non-consumables out unless the user
-- opts in). Kinds with no validator -- e.g. reagents -- accept anything that resolves.
QM.itemValidators = QM.itemValidators or {}

function QM.addDesired(kind, text)
	local c = QM.me
	if not c then return end
	local list = c[kind]; if not list then list = {}; c[kind] = list end
	local id, name, icon, quality, itype, isub = resolveItem(text)
	if not id then
		QM.print("could not resolve item -- shift-click an item link into the box, or enter an item ID")
		return
	end
	-- A validator may also hand back a meta table of extra fields (e.g. the consumable
	-- "apply" mode) to store on the new record, and an `omit` list of the default fields
	-- below (target/low/state) it doesn't want at all -- Lua can't carry an explicit nil
	-- through the meta table itself (pairs() never yields a nil value), so this is the
	-- one field-removal path.
	local meta, omit
	local validate = QM.itemValidators[kind]
	if validate then
		local ok, reason, m, o = validate(id, name, itype, isub)
		if not ok then QM.print(reason or "that item can't be tracked here"); return end
		meta, omit = m, o
	end
	for i = 1, table.getn(list) do
		if list[i].id == id then QM.print((name or ("item " .. id)) .. " is already tracked"); return end
	end
	-- target = prep amount / restock cap; low = warn threshold (notify when at/under it)
	local rec = { id = id, name = name, icon = icon, quality = quality, target = 10, low = 5, state = "enabled" }
	if meta then for k, v in pairs(meta) do rec[k] = v end end
	if omit then for i = 1, table.getn(omit) do rec[omit[i]] = nil end end
	table.insert(list, rec)
	QM.fire("DESIRED_CHANGED")
end

function QM.removeDesired(kind, index)
	local list = QM.me and QM.me[kind]
	if list and list[index] then table.remove(list, index); QM.fire("DESIRED_CHANGED") end
end

function QM.moveDesired(kind, index, dir)
	local list = QM.me and QM.me[kind]
	if not list then return end
	local j = index + dir
	if j < 1 or j > table.getn(list) then return end
	local tmp = list[index]; list[index] = list[j]; list[j] = tmp
	QM.fire("DESIRED_CHANGED")
end

-- Move the entry at `from` to an arbitrary position, expressed as the boundary `before`
-- in the ORIGINAL list (1..n+1): the item ends up just before whatever currently sits at
-- original index `before` (before == n+1 appends to the end). This is the drag-to-reorder
-- counterpart of moveDesired's single-step swap; the boundary form is what the drag tracker
-- computes from the cursor, and it stays unambiguous regardless of drag direction. Removing
-- `from` shifts everything after it down one, so the post-removal insert index is adjusted.
function QM.reorderDesired(kind, from, before)
	local list = QM.me and QM.me[kind]
	if not list then return end
	local n = table.getn(list)
	if from < 1 or from > n then return end
	if before < 1 then before = 1 elseif before > n + 1 then before = n + 1 end
	-- Dropping on either boundary touching the dragged row is a no-op.
	if before == from or before == from + 1 then return end
	local item = table.remove(list, from)
	local insertAt = before
	if before > from then insertAt = before - 1 end
	table.insert(list, insertAt, item)
	QM.fire("DESIRED_CHANGED")
end

function QM.setTarget(kind, index, value)
	local list = QM.me and QM.me[kind]
	if list and list[index] then
		list[index].target = tonumber(value) or list[index].target
		QM.fire("DESIRED_CHANGED")
	end
end

-- The warn threshold (notify when the carried count drops to/below it).
function QM.setLow(kind, index, value)
	local list = QM.me and QM.me[kind]
	if list and list[index] then
		list[index].low = tonumber(value) or list[index].low
		QM.fire("DESIRED_CHANGED")
	end
end

-- How the item is applied: "self" / "weapon" / "target" / "none" (see Consumables.classify).
-- Drives the in-raid one-click consume; editable per row in the consumables list.
function QM.setApply(kind, index, mode)
	local list = QM.me and QM.me[kind]
	if list and list[index] then
		list[index].apply = mode
		QM.fire("DESIRED_CHANGED")
	end
end

-- Vendor auto-restock opt-in: independent of `apply` -- an item can be both used
-- (self/weapon/target) AND bought up to `target` at a vendor (C.restockAtMerchant).
function QM.setRestock(kind, index)
	local list = QM.me and QM.me[kind]
	local e = list and list[index]
	if not e or QM.isDivider(e) then return end
	e.restock = not e.restock
	QM.fire("DESIRED_CHANGED")
end

-- Transferable-list opt-in: OK to bank this item's excess (Transfer.lua's /qm banksync).
function QM.setBankable(kind, index)
	local list = QM.me and QM.me[kind]
	local e = list and list[index]
	if not e or QM.isDivider(e) then return end
	e.bankable = not e.bankable
	QM.fire("DESIRED_CHANGED")
end

-- Per-row mail recipient override for a transferable entry; nil = use the
-- character's defaultMailRecipient (Transfer.lua's "Dump Excess").
function QM.setMailRecipient(kind, index, value)
	local list = QM.me and QM.me[kind]
	local e = list and list[index]
	if not e or QM.isDivider(e) then return end
	e.mailRecipient = (value and value ~= "") and value or nil
	QM.fire("DESIRED_CHANGED")
end

-- Tracking state of a desired entry, a linear level of involvement:
--   "enabled" -- shown in the track UI and counted for restock.
--   "hidden"  -- NOT shown in the track UI, but still counted for restock.
--   "off"     -- ignored for both, kept in the list so it can be re-enabled easily.
function QM.itemState(entry)
	if not entry then return "enabled" end
	if entry.state then return entry.state end
	if entry.enabled == false then return "off" end
	return "enabled"
end

-- Considered by the restock/prep math (enabled OR hidden, i.e. anything but off).
function QM.itemActive(entry) return QM.itemState(entry) ~= "off" end
-- Rendered in the track UI (enabled only).
function QM.itemShown(entry)  return QM.itemState(entry) == "enabled" end

local STATE_CYCLE = { enabled = "hidden", hidden = "off", off = "enabled" }
function QM.cycleState(kind, index)
	local list = QM.me and QM.me[kind]
	local e = list and list[index]
	if not e then return end
	e.state = STATE_CYCLE[QM.itemState(e)] or "enabled"
	e.enabled = nil   -- clear the legacy field
	QM.fire("DESIRED_CHANGED")
end

function QM.desiredList(kind)
	return QM.me and QM.me[kind]
end

-- ---------------------------------------------------------------------------
-- Dividers: itemless list entries that group rows in the tracker
-- ---------------------------------------------------------------------------
-- A divider carries no item id -- it is a hard boundary for HUD row ordering (a
-- "firegap" sorting never crosses) and optionally paints a category header at its
-- position. The state chip applies: enabled = boundary + header, hidden = boundary
-- only, off = inert. Callers that walk a list must skip these (no e.id).

function QM.isDivider(e) return (e and e.divider) and true or false end

-- Append a new, unlabeled separator to a desired list.
function QM.addDivider(kind, label)
	local list = QM.me and QM.me[kind]
	if not list then return end
	table.insert(list, { divider = true, label = QM.trim(label or ""), state = "enabled" })
	QM.fire("DESIRED_CHANGED")
end

-- Set a divider's category label ("" = an unlabeled rule). No-op on a non-divider row.
function QM.setDividerLabel(kind, index, text)
	local list = QM.me and QM.me[kind]
	local e = list and list[index]
	if not QM.isDivider(e) then return end
	e.label = QM.trim(text or "")
	QM.fire("DESIRED_CHANGED")
end

-- ---------------------------------------------------------------------------
-- Event hub + internal signals + OnUpdate driver
-- ---------------------------------------------------------------------------

local engine = CreateFrame("Frame")
QM.engine = engine

QM._handlers = {}   -- WoW event -> { fn, ... }; handlers read global event/arg1..
QM._signals  = {}   -- internal signal -> { fn, ... }

function QM.on(event, fn)
	if not QM._handlers[event] then
		QM._handlers[event] = {}
		engine:RegisterEvent(event)
	end
	table.insert(QM._handlers[event], fn)
end

function QM.subscribe(signal, fn)
	if not QM._signals[signal] then QM._signals[signal] = {} end
	table.insert(QM._signals[signal], fn)
end

function QM.fire(signal)
	local list = QM._signals[signal]
	if not list then return end
	for i = 1, table.getn(list) do list[i]() end
end

-- config tab registry (consumed lazily by Config.lua)
QM.configTabs = {}
function QM.registerConfigTab(spec)
	table.insert(QM.configTabs, spec)
end

engine:SetScript("OnEvent", function()
	local list = QM._handlers[event]
	if not list then return end
	for i = 1, table.getn(list) do list[i]() end
end)

local invDirty = false
local acc = 0
engine:SetScript("OnUpdate", function()
	acc = acc + arg1
	if acc < 0.5 then return end
	acc = 0
	if invDirty then invDirty = false; QM.scanInventory() end
	QM.fire("TICK")  -- modules hook this for periodic work (timers, status)
end)

-- ---------------------------------------------------------------------------
-- Moveable / anchorable frames (shared by the main HUD and the notify area)
-- ---------------------------------------------------------------------------
-- 1.12's SetPoint mis-positions non-TOPLEFT anchors, so we always pin TOPLEFT and
-- derive the offset from the user-facing anchor stored in QM.db.frames[layoutKey].
-- A frame's anchor corner is also where it "fills" from. Lock state is global
-- (QM.db.options.locked), re-applied to every registered frame on LOCK_CHANGED.
-- Each moveable frame is registered via QM.registerMoveable(frame, layoutKey[, onLock]).

QM.moveables = {}

local function layoutOf(frame)
	return QM.db and frame.qmLayoutKey and QM.db.frames[frame.qmLayoutKey]
end

local function anchorFractions(point)
	local fx, fy
	if string.find(point, "LEFT") then fx = 0
	elseif string.find(point, "RIGHT") then fx = 1
	else fx = 0.5 end
	if string.find(point, "TOP") then fy = 1
	elseif string.find(point, "BOTTOM") then fy = 0
	else fy = 0.5 end
	return fx, fy
end

function QM.applyFramePos(frame)
	local d = layoutOf(frame)
	if not d then return end
	local fx, fy = anchorFractions(d.point or "CENTER")
	local s = d.scale or 1
	local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
	local fw = frame:GetWidth() or d.width or 150
	local fh = frame:GetHeight() or 80
	local tlx = fx * pw / s + (d.x or 0) - fx * fw
	local tly = -(1 - fy) * ph / s + (d.y or 0) + (1 - fy) * fh
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", tlx, tly)
end

-- Inverse of applyFramePos: read the live TOPLEFT and store it back as the
-- user-facing anchor coords, so the (sign-sensitive) conversion lives in one place.
function QM.storeFramePos(frame)
	local d = layoutOf(frame)
	if not d then return end
	local _, _, _, tlx, tly = frame:GetPoint()
	if not tlx then return end
	local fx, fy = anchorFractions(d.point or "CENTER")
	local s = d.scale or 1
	local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
	local fw = frame:GetWidth() or d.width or 150
	local fh = frame:GetHeight() or 80
	d.x = tlx - fx * pw / s + fx * fw
	d.y = tly + (1 - fy) * ph / s - (1 - fy) * fh
end

-- Change a frame's user-facing anchor corner while keeping it visually in place:
-- the stored x/y are offsets from the anchor reference point, so re-derive them
-- against the new corner before repainting.
function QM.setFrameAnchor(frame, newPoint)
	local d = layoutOf(frame)
	if not d or newPoint == d.point then return end
	local s = d.scale or 1
	local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
	local ofx, ofy = anchorFractions(d.point or "CENTER")
	local nfx, nfy = anchorFractions(newPoint)
	local w = frame:GetWidth() or d.width or 150
	local h = frame:GetHeight() or 80
	d.x = (d.x or 0) + (ofx - nfx) * (pw / s - w)
	d.y = (d.y or 0) + (ofy - nfy) * (ph / s - h)
	d.point = newPoint
	QM.applyFrameLayout(frame)
end

function QM.applyFrameLock(frame)
	local locked = QM.db and QM.db.options.locked and true or false
	frame:EnableMouse(not locked)
	if frame.qmOnLock then frame.qmOnLock(frame, locked) end
end

function QM.applyFrameLayout(frame)
	local d = layoutOf(frame)
	QM.applyFramePos(frame)
	frame:SetScale((d and d.scale) or 1)
	QM.applyFrameLock(frame)
end

-- Register a frame to follow the global lock + persist its position under
-- QM.db.frames[layoutKey]. onLock(frame, locked) optionally repaints lock cues.
-- Called from the frame's XML OnLoad (before the DB is ready), so the actual
-- layout is (re)applied on DB_READY below.
function QM.registerMoveable(frame, layoutKey, onLock)
	frame.qmLayoutKey = layoutKey
	frame.qmOnLock = onLock
	frame:RegisterForDrag("LeftButton")
	table.insert(QM.moveables, frame)
	if QM.db then QM.applyFrameLayout(frame) end
end

-- Lock-aware XML drag hooks shared by every moveable frame (this = the frame). The
-- qmMoving flag lets a frame's own painter skip re-layout while a native move is in
-- progress: resizing/SetHeight'ing a frame mid-StartMoving corrupts the move and hard-
-- crashes the 1.12 client on mouse-up (the tracker HUD re-sizes every tick).
function Quartermaster_FrameDragStart()
	if QM.db and QM.db.options.locked then return end
	this.qmMoving = true
	this:StartMoving()
end
function Quartermaster_FrameDragStop()
	this:StopMovingOrSizing()
	this.qmMoving = false
	QM.storeFramePos(this)
	QM.fire("FRAME_MOVED")
end

QM.subscribe("DB_READY", function()
	for i = 1, table.getn(QM.moveables) do QM.applyFrameLayout(QM.moveables[i]) end
end)
QM.subscribe("LOCK_CHANGED", function()
	for i = 1, table.getn(QM.moveables) do QM.applyFrameLock(QM.moveables[i]) end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Per-row `want` was renamed `target`; carry forward any saved value once. Also splits the
-- old apply="restock" Use-mode into its own `restock` boolean (apply is a real usable mode
-- again), and backfills every entry's apply to the explicit "none" so nil never again means
-- "no action" anywhere downstream.
local function migrateChar(c)
	local function fix(list)
		if not list then return end
		for i = 1, table.getn(list) do
			local e = list[i]
			if e.target == nil then e.target = e.want end
			e.want = nil
			if not QM.isDivider(e) then
				if e.apply == "restock" then e.apply = nil; e.restock = true end
				if not e.apply then e.apply = "none" end
			end
		end
	end
	fix(c.reagents)

	-- Fold the retired per-character reagents list into the unified consumables list. A
	-- "Reagents" divider marks the join when both sides have rows, preserving the old
	-- visual split. Idempotent: reagents is emptied after, so a later load moves nothing.
	local r = c.reagents
	if r and table.getn(r) > 0 then
		c.consumables = c.consumables or {}
		if table.getn(c.consumables) > 0 then
			table.insert(c.consumables, { divider = true, label = "Reagents", state = "enabled" })
		end
		for i = 1, table.getn(r) do table.insert(c.consumables, r[i]) end
		c.reagents = {}
	end

	-- Profiles: adopt on first run, then re-alias consumables to the active profile's
	-- table. SavedVariables writes the shared table under both keys as two copies, so
	-- this re-link on every load is what makes `profiles` the authority.
	if not c.profiles then
		c.profiles = { ["Default"] = c.consumables or {} }
		c.activeProfile = "Default"
	end
	if not c.activeProfile or not c.profiles[c.activeProfile] then
		local first
		for n in pairs(c.profiles) do
			if not first or n < first then first = n end
		end
		if not first then first = "Default"; c.profiles[first] = {} end
		c.activeProfile = first
	end
	c.consumables = c.profiles[c.activeProfile]
	for _, list in pairs(c.profiles) do fix(list) end

	c.transferable = c.transferable or {}
end

QM.on("VARIABLES_LOADED", function()
	QuartermasterDB = QuartermasterDB or {}
	applyDefaults(QuartermasterDB, defaults)
	for _, c in pairs(QuartermasterDB.chars) do migrateChar(c) end
	QM.db = QuartermasterDB
	QM.fire("DB_READY")
end)

QM.on("PLAYER_LOGIN", function()
	QM.registerChar()
	QM.scanInventory()
	QM.fire("READY")
end)

QM.on("PLAYER_ENTERING_WORLD", function() if QM.db then QM.scanInventory() end end)
QM.on("BAG_UPDATE", function() invDirty = true end)
QM.on("BANKFRAME_OPENED", function() QM.bankOpen = true; if QM.db then QM.scanInventory() end end)
QM.on("BANKFRAME_CLOSED", function() QM.bankOpen = false end)

-- ---------------------------------------------------------------------------
-- Frame lock + slash command
-- ---------------------------------------------------------------------------

function QM.setLocked(locked)
	if QM.db then QM.db.options.locked = locked and true or false end
	QM.fire("LOCK_CHANGED")
	QM.print(locked and "frames locked" or "frames unlocked")
end

SLASH_QUARTERMASTER1 = "/qm"
SLASH_QUARTERMASTER2 = "/quartermaster"
SlashCmdList["QUARTERMASTER"] = function(rawmsg)
	-- Character/profile names are case-sensitive, so keep the original-case text around for
	-- `mailsync`'s arguments -- only the command keywords themselves are matched lowercase.
	local raw = QM.trim(rawmsg)
	local msg = string.lower(raw)
	if msg == "lock" then
		QM.setLocked(true)
	elseif msg == "unlock" then
		QM.setLocked(false)
	elseif msg == "show" then
		if QM.setHudHidden then QM.setHudHidden(false) end
	elseif msg == "hide" then
		if QM.setHudHidden then QM.setHudHidden(true) end
	elseif msg == "banksync" then
		if QM.Transfer and QM.Transfer.bankSync then QM.Transfer.bankSync() end
	elseif msg == "prep" then
		if QM.Consumables and QM.Consumables.prepPlanPrint then QM.Consumables.prepPlanPrint() end
	elseif string.find(msg, "^mailsync") then
		-- "mailsync" is 8 chars; raw/msg share byte offsets, so slice raw at the same point
		-- to recover the case-preserved arguments.
		local rest = QM.trim(string.sub(raw, 9))
		if string.lower(rest) == "dump" then
			if QM.Transfer and QM.Transfer.mailDumpExcess then QM.Transfer.mailDumpExcess() end
		elseif rest ~= "" then
			local _, _, charArg, listArg = string.find(rest, "^(%S+)%s*(.-)$")
			listArg = QM.trim(listArg or "")
			if charArg and QM.Transfer and QM.Transfer.mailSyncTo then
				QM.Transfer.mailSyncTo(charArg, listArg ~= "" and listArg or nil)
			end
		else
			QM.print("usage: /qm mailsync dump  |  /qm mailsync <character> [list]")
		end
	elseif string.find(msg, "^mailtest") then
		-- Debug probe for the SendMail-gets-no-reply failure (see Transfer.lua's T.mailTest).
		-- "mailtest" is also 8 chars; same case-preserving slice as mailsync above.
		local rest = QM.trim(string.sub(raw, 9))
		local _, _, nameArg, delayArg = string.find(rest, "^(%S*)%s*(%S*)")
		if QM.Transfer and QM.Transfer.mailTest then
			QM.Transfer.mailTest(nameArg ~= "" and nameArg or nil, delayArg)
		end
	elseif msg == "" or msg == "config" then
		if QM.toggleConfig then QM.toggleConfig() else QM.print("config panel not loaded") end
	else
		QM.print("commands: /qm (config)  |  /qm lock  |  /qm unlock  |  /qm show  |  /qm hide  |  /qm banksync  |  /qm prep  |  /qm mailsync")
	end
end

-- ---------------------------------------------------------------------------
-- Main HUD frame hooks (frame defined in Quartermaster.xml; contents in Consumables.lua)
-- ---------------------------------------------------------------------------

function Quartermaster_Main_OnLoad()
	QM.mainFrame = this
	-- Follows the global lock + persists its position via the shared moveable
	-- system; drag is routed through Quartermaster_FrameDragStart/Stop in the XML.
	QM.registerMoveable(this, "main")
end
