-- Quartermaster -- Consumables
-- Per-character desired consumable list (QM.me.consumables), the prep view
-- (have vs target, including where the rest sits across alts), in-raid buff timers,
-- and consume-from-UI (UseContainerItem by itemID -- no bag window needed).

local QM = Quartermaster
QM.Consumables = {}
local C = QM.Consumables

-- How a tracked item is APPLIED -- drives the in-raid one-click consume (C.use).
-- The modes the user cares about:
--   "self"   -- used straight onto the player (potions, elixirs, flasks, food)
--   "weapon" -- applied to BOTH weapons (sharpening/weightstones, oils, poisons)
--   "mh"     -- applied to the main hand only
--   "oh"     -- applied to the off hand only
--   "target" -- needs a target (scrolls, jujus)
--   "none"   -- not applied directly; a stocked/reagent row (count only)
-- Auto-classification only ever yields "self"/"weapon"/"target"/"none"; "weapon" can be
-- narrowed to "mh"/"oh" per row (a weapon enhancement on just one hand). GetItemInfo can't
-- tell self/weapon/target apart on its own: poisons/jujus/some self-buffs all sit in the
-- Consumable/Consumable bucket, so class+subclass only gets us a best guess -- "weapon"
-- is reliable (Item Enhancement is its own subclass); "self" vs "target" inside the
-- Consumable class is not, and is meant to be corrected per item. "restock" (vendor
-- auto-buy) is a SEPARATE per-entry boolean (`e.restock`), independent of apply -- an item
-- can be both self-used and vendor-restocked (e.g. a vendor-sold food you also eat).
C.APPLY_SELF, C.APPLY_WEAPON, C.APPLY_TARGET = "self", "weapon", "target"
C.APPLY_MH, C.APPLY_OH = "mh", "oh"   -- main-hand / off-hand only (narrowed from "weapon")
C.APPLY_NONE = "none"

-- Locale/server-safe classification. GetItemInfo returns LOCALIZED class/subclass
-- strings, so we never compare against literals. Instead:
--   * the Consumable CLASS comes from GetAuctionItemClasses() -- a fixed, locale-
--     independent order (the trick aux and Bagshui use); Consumable is index 4 on 1.12
--     (Weapon, Armor, Container, Consumable, ...).
--   * the weapon-enhancement SUBCLASS we LEARN from reference items at login (their live
--     subclass on THIS realm), so sharpening/weightstones and oils match whatever this
--     server/locale calls them. IDs are confirmed from ConsumesManager's list.
local consumableClass
local enhanceSubs = {}                       -- learned localized "Item Enhancement"-type subclasses
local ENHANCE_REFS = { 12404, 12643, 20749 } -- Dense Sharpening Stone, Dense Weightstone, Brilliant Wizard Oil

QM.subscribe("READY", function()
	local classes = { GetAuctionItemClasses() }
	consumableClass = classes[4]
	for i = 1, table.getn(ENHANCE_REFS) do
		local _, _, _, _, _, isub = GetItemInfo("item:" .. ENHANCE_REFS[i])
		if isub then enhanceSubs[isub] = true end
	end
end)

-- Curated starting defaults for items whose apply mode can't be read from the item
-- class -- poisons (weapon), scrolls and jujus (target) all live in the Consumable
-- class and would otherwise default to "self". These only SEED the mode on add; the
-- per-row control still overrides. IDs are from ConsumesManager's list. (Jujus are
-- grouped as "target" by request; in vanilla they're self-use -- flip per row if so.)
local APPLY_OVERRIDES = {
	-- Rogue weapon poisons -> applied to a weapon
	[8928]  = C.APPLY_WEAPON,  -- Instant Poison VI
	[3776]  = C.APPLY_WEAPON,  -- Crippling Poison II
	[20844] = C.APPLY_WEAPON,  -- Deadly Poison V
	[9186]  = C.APPLY_WEAPON,  -- Mind-numbing Poison III
	[10922] = C.APPLY_WEAPON,  -- Wound Poison IV
	[47409] = C.APPLY_WEAPON,  -- Corrosive Poison II
	[54010] = C.APPLY_WEAPON,  -- Dissolvent Poison II
	[65032] = C.APPLY_WEAPON,  -- Agitating Poison
	-- Scrolls -> need a target
	[10305] = C.APPLY_TARGET,  -- Scroll of Protection IV
	-- Jujus -> grouped as needing a target
	[12451] = C.APPLY_TARGET,  -- Juju Power
	[12460] = C.APPLY_TARGET,  -- Juju Might
	[12455] = C.APPLY_TARGET,  -- Juju Ember
	[12457] = C.APPLY_TARGET,  -- Juju Chill
	[12450] = C.APPLY_TARGET,  -- Juju Flurry
}

-- Best-guess application mode for an item. A curated override wins; then the
-- Item-Enhancement subclass (weapon); then the generic Consumable class (self);
-- anything else gets the explicit APPLY_NONE (never nil -- see the apply-mode note above).
function C.classify(id, itype, isub)
	if id and APPLY_OVERRIDES[id] then return APPLY_OVERRIDES[id] end
	if isub and enhanceSubs[isub] then return C.APPLY_WEAPON end
	if consumableClass and itype == consumableClass then return C.APPLY_SELF end
	return C.APPLY_NONE
end

-- Classify an item on add (never rejects -- the single list holds consumables AND stocked
-- reagents). A recognised consumable returns its derived apply mode as meta; anything else
-- (cloth, herbs, ore, an item the client hasn't cached yet) is a stocked item: count-only
-- via track=stock (the itemMeta default, so no override is written), apply=none, restock
-- opt-in via the separate per-row toggle.
QM.itemValidators = QM.itemValidators or {}
QM.itemValidators["consumables"] = function(id, name, itype, isub)
	local mode = C.classify(id, itype, isub)
	-- Weapon enchants are buff-tracked by nature; default a freshly added one to Buff (only
	-- when it has no track yet) so it shows a live timer without a manual Track change.
	if (mode == C.APPLY_WEAPON or mode == C.APPLY_MH or mode == C.APPLY_OH)
	   and QM.itemTrack(id) == QM.TRACK_STOCK then
		QM.setItemTrack(id, QM.TRACK_BUFF)
	end
	return true, nil, { apply = mode }
end

-- ---------------------------------------------------------------------------
-- Food eat session: the sit-and-eat progress phase before the Well Fed buff
-- ---------------------------------------------------------------------------
-- A food item (track="food") shows an EATING progress bar from the moment its HUD row is used
-- until the Well Fed buff lands, then transitions to that buff's duration. Both the eat aura
-- (the regen buff that appears while eating -- the "still eating" signal, items[id].eatMatch)
-- and the eat time (secs to Well Fed, items[id].eatTime) are LEARNED PER food on the first
-- full cycle and managed/reset in the gear popup. Until the aura is learned, combat and a
-- timeout are the only stop signals; DEFAULT_EAT_TIME scales the bar until the time is learned.
local DEFAULT_EAT_TIME = 10
local EAT_AURA_GRACE   = 1.5   -- secs before a missing eat aura counts as "stopped" (it needs a beat to appear)
local EAT_TIMEOUT      = 8     -- secs past the expected eat time with no buff -> give up
local EAT_FLASH        = 0.9   -- with no learned eat aura, how long the click-feedback blue flash shows

local eatSession   -- { id, start, pre = {iconSet}, candidate = icon } or nil

-- Lowercased icon paths of the player's current HELPFUL buffs, as a set. One implementation
-- in ItemMeta -- the gap-skipping sweep there is the only correct way to read the buff slots.
local helpfulBuffIcons = QM.playerBuffIconSet

-- Is this food's learned eating aura (items[id].eatMatch) currently on the player? The
-- per-item "still eating" signal; false when nothing learned yet (then we lean on the backstops).
local function eatAuraActive(id)
	return QM.selfBuffPresent(QM.itemEatMatch(id)) and true or false
end

local function startEatSession(id)
	eatSession = { id = id, start = GetTime(), pre = helpfulBuffIcons() }
end

-- Drive the active eat session each TICK. Learn on the first Well Fed landing (the eat time,
-- and the eat aura for THIS food if not yet known), but keep the session ALIVE past that so the
-- blue "eating" bar persists over the Well Fed duration until the regen aura actually ends --
-- while still sitting and eating, the eating state outranks the buff's remaining time. Ends on
-- combat / eat aura gone after the grace / timeout. The eat-aura candidate is the first
-- new-since-click helpful buff -- captured early, before Well Fed appears, so the two don't get
-- confused.
local function updateEatSession()
	local sess = eatSession
	if not sess then return end
	local id = sess.id
	local elapsed = GetTime() - sess.start

	if not sess.learned and QM.itemEffect(id, "self") then   -- Well Fed landed: learn once
		if not QM.itemEatTime(id) then
			local t = elapsed
			if t < 2 then t = 2 elseif t > 60 then t = 60 end
			QM.setItemEatTime(id, t)
		end
		if not QM.itemEatMatch(id) and sess.candidate then
			QM.setItemEatMatch(id, "icon", sess.candidate)
		end
		sess.learned = true
	end

	if not sess.candidate then
		local set = helpfulBuffIcons()
		for icon in pairs(set) do
			if not sess.pre[icon] then sess.candidate = icon; break end
		end
	end

	if UnitAffectingCombat("player") then eatSession = nil; return end
	if QM.itemEatMatch(id) and elapsed > EAT_AURA_GRACE and not eatAuraActive(id) then eatSession = nil; return end
	local et = QM.itemEatTime(id) or DEFAULT_EAT_TIME
	if elapsed > et + EAT_TIMEOUT then eatSession = nil end
end

-- Which equipped weapon slot a weapon-apply click targets (16 main hand, 17 off hand).
-- "mh"/"oh" are explicit; "weapon" (both) fills the slot that LACKS the tracked enchant so
-- successive clicks top up main hand then off hand -- main hand first, off hand only when a
-- weapon is actually equipped there, otherwise refresh main hand.
local function weaponApplySlot(itemID, apply)
	if apply == C.APPLY_OH then return 17 end
	if apply == C.APPLY_MH then return 16 end
	if not QM.itemEffect(itemID, C.APPLY_MH) then return 16 end
	if GetInventoryItemLink("player", 17) and not QM.itemEffect(itemID, C.APPLY_OH) then return 17 end
	return 16
end

-- Consume one of itemID straight from the carried bags, no bag UI. Apply modes:
--   target -- cast on a unit, so to land it on the player we briefly target self, use, then
--             restore the prior target (reliable regardless of whether the use opens a
--             targeting cursor -- SpellIsTargeting isn't set synchronously after a use).
--   weapon/mh/oh -- the use opens an item-targeting cursor; finish it on the weapon slot with
--             PickupInventoryItem(16/17), then ReplaceEnchant() to confirm the overwrite popup
--             and ClearCursor() to tidy up. This client's cursor is set synchronously after the
--             use (the working sequence in SuperCleveRoidMacros' /applymain), so no defer needed.
--   self   -- used directly on the player.
function C.use(itemID, apply)
	local bag, slot = QM.findBagSlotLowest(itemID)
	if not bag then
		QM.print("none of that consumable in your bags")
		return false
	end
	-- Snapshot what is already up BEFORE using, so the capture-on-use below can tell which buff
	-- this item added (the self/target counterpart of the weapon path's enchant diff).
	local beforeBuffs = QM.playerBuffIconSet()
	if apply == C.APPLY_TARGET then
		local hadTarget = UnitExists("target")
		local wasSelf   = hadTarget and UnitIsUnit("target", "player")
		TargetUnit("player")
		UseContainerItem(bag, slot)
		if SpellIsTargeting() then
			if SpellCanTargetUnit("player") then SpellTargetUnit("player") else SpellStopTargeting() end
		end
		if not wasSelf then
			if hadTarget then TargetLastTarget() else ClearTarget() end
		end
	elseif apply == C.APPLY_WEAPON or apply == C.APPLY_MH or apply == C.APPLY_OH then
		local wslot = weaponApplySlot(itemID, apply)
		-- Snapshot the slot's current enchant BEFORE replacing it, so capture-on-apply can wait
		-- for the NEW enchant to land instead of reading the one we're about to overwrite.
		local bId, bName = QM.weaponEnchantIdentity(wslot)
		UseContainerItem(bag, slot)
		PickupInventoryItem(wslot)
		ReplaceEnchant()   -- auto-confirm the "replace existing temp enchant" popup
		ClearCursor()
		C.pendingLearn = { id = itemID, slot = wslot, beforeId = bId, beforeName = bName, deadline = GetTime() + 10 }
	else
		UseContainerItem(bag, slot)
	end
	-- Capture-on-use. Almost every seed entry carries no explicit match rule and leans on the
	-- derived "the buff icon equals the item icon" default, which is simply false for scrolls,
	-- food, jujus and anything whose buff art differs from its item art -- those rows would
	-- never light up, with nothing in the addon to correct them. Watch for the new buff
	-- instead. Food only lands Well Fed after the eat session, hence the longer window.
	local track = QM.itemTrack(itemID)
	if apply ~= C.APPLY_WEAPON and apply ~= C.APPLY_MH and apply ~= C.APPLY_OH
	   and (track == QM.TRACK_BUFF or track == QM.TRACK_FOOD)
	   and not QM.itemValidated(itemID) then
		C.pendingBuffLearn = { id = itemID, before = beforeBuffs,
			deadline = GetTime() + (track == QM.TRACK_FOOD and 45 or 12) }
	end
	if track == QM.TRACK_FOOD then startEatSession(itemID) end
	C.kickFast(1)   -- animate the resulting (short) cooldown smoothly from the click
	return true
end

-- Prep shortfall for the current character's active tracked list: what's missing from
-- bags vs target, and where the rest sits (bank / named other characters). Delegates to
-- Transfer.lua's T.plan (loaded after this file, so only referenced at call time), which
-- already answers exactly this for any character/list. Returns ordered rows
-- { id, name, short, fromBank, fromAlt, alts = { { char, amount }, ... } }.
function C.prepPlan()
	if not (QM.Transfer and QM.Transfer.plan) then return {} end
	return QM.Transfer.plan(QM.charKey(), "consumables")
end

local function prepRowText(r)
	local where = {}
	if r.fromBank > 0 then table.insert(where, r.fromBank .. " in bank") end
	if r.alts then
		for i = 1, table.getn(r.alts) do
			local a = r.alts[i]
			table.insert(where, a.amount .. " on " .. a.char)
		end
	end
	local suffix = table.getn(where) > 0 and (" (" .. table.concat(where, ", ") .. ")") or " (none found elsewhere)"
	return r.name .. ": need " .. r.short .. suffix
end

-- Multi-line report for the Tracker tab's read-only Prep dialog.
function C.prepPlanText()
	local rows = C.prepPlan()
	if table.getn(rows) == 0 then
		return "Nothing short on '" .. QM.activeProfile() .. "' -- you're fully prepped."
	end
	local lines = {}
	for i = 1, table.getn(rows) do table.insert(lines, prepRowText(rows[i])) end
	return table.concat(lines, "\n")
end

-- /qm prep: the same report, one chat line per item.
function C.prepPlanPrint()
	local rows = C.prepPlan()
	if table.getn(rows) == 0 then
		QM.print("nothing short on '" .. QM.activeProfile() .. "' -- you're fully prepped")
		return
	end
	QM.print("prep: '" .. QM.activeProfile() .. "' -- " .. table.getn(rows) .. " item(s) short")
	for i = 1, table.getn(rows) do QM.print("  " .. prepRowText(rows[i])) end
end

-- "Interface\\Icons\\INV_Potion_32" -> "INV_Potion_32", so a report line stays readable.
local function shortIcon(path)
	if not path then return "?" end
	local _, _, tail = string.find(path, "([^\\]+)$")
	return tail or path
end

-- /qm buffs -- the answer to "this buff is up, so why is the row not green?". Lists every buff
-- on the player (name / icon / spell id), then each tracked buff+food row with the match rule
-- actually in force and whether it resolves right now. A row reading NO RULE or "not up" while
-- its buff is plainly listed above means the rule points at the wrong art: use the item once to
-- let capture-on-use adopt it, or set it by hand in the row's gear popup.
function C.buffReport()
	local buffs = QM.playerBuffList()
	QM.print(table.getn(buffs) .. " buff(s) up:")
	for i = 1, table.getn(buffs) do
		local b = buffs[i]
		QM.print("  " .. (b.name or "(unnamed)") .. "  icon=" .. shortIcon(b.icon) ..
			(b.id and ("  id=" .. b.id) or ""))
	end
	local list = (QM.me and QM.me.consumables) or {}
	QM.print("tracked buff rows on '" .. QM.activeProfile() .. "':")
	local shown = 0
	for i = 1, table.getn(list) do
		local e = list[i]
		if not QM.isDivider(e) and e.id and QM.itemActive(e) then
			local tr = QM.itemTrack(e.id)
			if tr == QM.TRACK_BUFF or tr == QM.TRACK_FOOD then
				shown = shown + 1
				local apply = e.apply or "self"
				local m = QM.itemMatchEffective(e.id, apply)
				local rule = "NO RULE"
				if m then
					rule = m.by .. "=" .. ((m.by == "icon") and shortIcon(m.value) or tostring(m.value))
				end
				QM.print("  " .. (e.name or ("item " .. e.id)) .. ": " .. rule ..
					"  [" .. QM.itemMatchStatus(e.id, apply) ..
					", " .. (QM.itemEffect(e.id, apply) and "ACTIVE" or "not up") .. "]")
			end
		end
	end
	if shown == 0 then QM.print("  (none -- these rows are all Stock/CD tracked)") end
end

-- Throttled vendor buying, one purchase per tick like QuickStash's Seller -- bulk vendor
-- actions in a single frame leave some stuck/locked on this client.
local Restocker = CreateFrame("Frame")
local BUY_INTERVAL = 0.1
Restocker.queue = {}

local function finishRestock()
	Restocker:SetScript("OnUpdate", nil)
	local bought, skipped = Restocker.bought, Restocker.skipped
	Restocker.queue = {}

	for i = 1, table.getn(bought) do
		local b = bought[i]
		QM.print("bought " .. b.qty .. "x " .. b.name .. " for " .. QM.money(b.spent))
	end
	if table.getn(skipped) > 0 then
		QM.print("couldn't afford: " .. table.concat(skipped, ", "))
	end
	if table.getn(bought) > 0 then QM.scanInventory() end
end

local function buyNext()
	Restocker.elapsed = Restocker.elapsed + arg1
	if Restocker.elapsed < BUY_INTERVAL then return end
	Restocker.elapsed = 0

	if not MerchantFrame or not MerchantFrame:IsVisible() or not Restocker.queue[Restocker.index] then
		finishRestock()
		return
	end

	local item = Restocker.queue[Restocker.index]
	Restocker.index = Restocker.index + 1

	local units = item.units
	local money = GetMoney()
	if item.price * units > money then
		units = math.floor(money / item.price)
	end
	if units <= 0 then
		table.insert(Restocker.skipped, item.name)
		return
	end

	BuyMerchantItem(item.index, units)
	table.insert(Restocker.bought, { name = item.name, qty = units * item.count, spent = item.price * units })
end

-- Vendor restock: buy each restock=true entry up to its `target` cap from the open
-- merchant (only QM.itemActive entries; skip dividers and unaffordable buys). A vendor
-- batch (GetMerchantItemInfo's count, e.g. "5x") that doesn't divide the shortfall evenly
-- is rounded UP -- overshooting target rather than leaving a perpetual shortfall. When
-- money is short, buys as many full batches as affordable instead of skipping the item
-- outright. Gated by options.reagentRestock on MERCHANT_SHOW.
function C.restockAtMerchant()
	if not MerchantFrame or not MerchantFrame:IsVisible() then return end
	if Restocker.queue[1] then return end   -- already draining a queue from this MERCHANT_SHOW

	local forSale = {}
	for i = 1, (GetMerchantNumItems() or 0) do
		local id = QM.itemID(GetMerchantItemLink(i))
		if id then
			local _, _, price, count, stock, isUsable = GetMerchantItemInfo(i)
			forSale[id] = { index = i, price = price or 0,
				count = (count and count > 0) and count or 1, stock = stock, isUsable = isUsable }
		end
	end

	local list = QM.desiredList("consumables") or {}
	local queue = {}
	for i = 1, table.getn(list) do
		local e = list[i]
		if not QM.isDivider(e) and e.restock and QM.itemActive(e) then
			local sale = forSale[e.id]
			if sale and sale.isUsable ~= false then
				local bags = QM.itemCount(e.id)
				local shortfall = (e.target or 0) - bags
				if shortfall > 0 then
					local units = math.ceil(shortfall / sale.count)
					if sale.stock and sale.stock >= 0 then
						units = math.min(units, math.floor(sale.stock / sale.count))
					end
					if units > 0 then
						table.insert(queue, { index = sale.index, name = e.name, price = sale.price,
							count = sale.count, units = units })
					end
				end
			end
		end
	end
	if table.getn(queue) == 0 then return end

	Restocker.queue, Restocker.index, Restocker.elapsed = queue, 1, 0
	Restocker.bought, Restocker.skipped = {}, {}
	Restocker:SetScript("OnUpdate", buyNext)
end

QM.on("MERCHANT_SHOW", function()
	if QM.db and QM.db.options.reagentRestock then C.restockAtMerchant() end
end)

-- ---------------------------------------------------------------------------
-- In-raid live tracking: buff/enchant timers, cooldown fallback, status
-- ---------------------------------------------------------------------------

local EXPIRE_NOTIFY = 30   -- dedupe window for the recurring "running low" notice
local GCD_FLOOR     = 2    -- ignore cooldowns this short (the ~1.5s global use cooldown), but
                           -- still show the 3s shared-elixir category cooldown

-- Seconds under which a tracked buff counts as "running low" (orange tint on the HUD +
-- the expiring notification). Configurable on the Buffs tab; defaults to 3 min.
local function lowDuration() return (QM.db and QM.db.options.buffLowDuration) or 180 end

-- Remaining usability cooldown of an item: timeLeft(s), duration(s), or nil when off
-- cooldown. Short cooldowns (<= GCD_FLOOR) are ignored.
-- Prefer Nampower's GetItemIdCooldown -- it reports by itemID (no bag slot needed) and,
-- crucially, surfaces shared CATEGORY cooldowns (one elixir putting the rest on cooldown),
-- which the bag-slot GetContainerItemCooldown read doesn't. The duration of the active
-- cooldown sits in EITHER individualDurationMs or categoryDurationMs -- the inactive one is
-- 0 (truthy in Lua, so an `or` chain would wrongly pick it), so we branch on the active
-- flag. The global use cooldown lives in separate gcdCategory* fields and doesn't set
-- isOnCooldown, so isOnCooldown already excludes it. Falls back to the slot read where
-- Nampower isn't present (needs the item in bags -- a slot read, so no item = no signal).
function C.itemCooldown(id)
	if QM.caps.itemIdCooldown then
		local cd = GetItemIdCooldown(id)
		if type(cd) == "table" then
			if cd.isOnCooldown == 1 then
				local left = (cd.cooldownRemainingMs or 0) / 1000
				local durMs = 0
				if cd.isOnIndividualCooldown == 1 then durMs = cd.individualDurationMs or 0
				elseif cd.isOnCategoryCooldown == 1 then durMs = cd.categoryDurationMs or 0 end
				if durMs <= 0 then durMs = cd.cooldownRemainingMs or 0 end
				local dur = durMs / 1000
				if left > 0 and dur > GCD_FLOOR then return left, dur end
			end
			return nil   -- API answered: trust it (don't double-read the slot)
		end
	end
	local bag, slot = QM.findBagSlot(id)
	if not bag then return nil end
	local start, duration = GetContainerItemCooldown(bag, slot)
	if start and duration and start > 0 and duration > GCD_FLOOR then
		local left = start + duration - GetTime()
		if left < 0 then left = 0 end
		return left, duration
	end
	return nil
end

-- Live tracking status for a desired entry, merging the buff/enchant effect, the item
-- cooldown fallback, and the carried count. `phase`:
--   "buff"  -- a tracked buff/enchant is up (timeLeft/duration/stacks set)
--   "cd"    -- no buff, but the item is on its usability cooldown (timeLeft/duration)
--   "ready" -- nothing up and off cooldown (can apply now)
--   "stock" -- track="stock" (count-only row: no bar, no timer, just the carried count)
-- The bag count is always filled in (the prep view + low-stock tint read it).
-- applyOverride lets a split MH/OH HUD row read just its own weapon slot (the entry itself
-- still carries the "weapon" = both mode).
-- `out`, when given, is a table to fill in place (fields reset here) instead of allocating a
-- fresh one -- the per-paint HUD build pools these (see activeBuffs). Callers that want a
-- one-shot table (a click/hover probe) just omit it.
function C.liveStatus(entry, applyOverride, out)
	local id, apply = entry.id, applyOverride or entry.apply or "self"
	local track = QM.itemTrack(id)
	local bags = QM.itemCount(id)
	local s = out or {}
	s.track, s.phase, s.bags = track, "none", bags
	s.up, s.timeLeft, s.stacks, s.duration = nil, nil, nil, nil
	s.buffUp, s.buffLeft, s.eatFull = nil, nil, nil
	if track == "stock" then s.phase = "stock"; return s end

	if track == "buff" then
		local up, tl, stacks = QM.itemEffect(id, apply)
		if up then
			s.phase = "buff"; s.up = true; s.timeLeft = tl; s.stacks = stacks
			s.duration = QM.itemMaxDuration(id) or tl
			return s
		end
	end

	-- Food: an active eat session outranks the buff -- while still sitting and eating, show the
	-- blue "eating" bar over any remaining Well Fed time. A learned eat time fills the bar toward
	-- it (then holds full); with no known time the bar is just full blue until the aura ends; with
	-- no known eat aura we can't tell when eating stops, so it's only a brief blue click-flash.
	-- Otherwise: Well Fed up -> its duration, else "ready" (no cooldown).
	if track == "food" then
		if eatSession and eatSession.id == id then
			-- The eating bar can mask a Well Fed buff that is already up; stash its live state so
			-- the expiring/lost notifications still read the real buff (they can't key off the
			-- overridden phase). buffUp/buffLeft are NOT s.up (render must keep the eating branch).
			local bu, btl = QM.itemEffect(id, apply)
			s.buffUp = bu and true or false; s.buffLeft = btl
			local et = QM.itemEatTime(id)
			if et then
				local left = et - (GetTime() - eatSession.start)
				if left < 0 then left = 0 end
				s.phase = "eating"; s.timeLeft = left; s.duration = et
				return s
			elseif QM.itemEatMatch(id) then
				s.phase = "eating"; s.eatFull = true
				return s
			elseif (GetTime() - eatSession.start) < EAT_FLASH then
				s.phase = "eating"; s.eatFull = true
				return s
			end
		end
		local up, tl, stacks = QM.itemEffect(id, apply)
		if up then
			s.phase = "buff"; s.up = true; s.timeLeft = tl; s.stacks = stacks
			s.duration = QM.itemMaxDuration(id) or tl
			return s
		end
		s.phase = "ready"
		return s
	end

	-- CD axis, or the Buff fall-back when the buff is down: show the usability cooldown.
	local left, dur = C.itemCooldown(id)
	if left and left > 0 then
		s.phase = "cd"; s.timeLeft = left; s.duration = dur
		return s
	end

	s.phase = "ready"
	return s
end

-- True when a weapon (not a shield/held off-hand) is in the off-hand, so a "both weapons"
-- enchant should track each hand separately. equipLoc is GetItemInfo's 8th return on 1.12;
-- resolve by itemID (GetItemInfo on a full link is flaky here) and match any weapon equipLoc
-- by substring -- INVTYPE_WEAPON / _WEAPONOFFHAND / _WEAPONMAINHAND all contain "WEAPON",
-- while shields (INVTYPE_SHIELD) and held items (INVTYPE_HOLDABLE) don't.
local function offHandIsWeapon()
	local link = GetInventoryItemLink("player", 17)
	if not link then return false end
	local _, _, id = string.find(link, "item:(%d+)")
	local _, _, _, _, _, _, _, loc = GetItemInfo(id and ("item:" .. id) or link)
	return loc ~= nil and string.find(loc, "WEAPON") ~= nil
end

-- Row-descriptor + status tables are pooled across paints: the HUD rebuilds this stream
-- twice a second (and faster while a short cooldown animates), and a from-scratch 2*N tables
-- each time was the bulk of the addon's steady-state GC churn. reclaimDescs (called at the
-- top of each build) returns the previous paint's tables to the free lists; the descriptors
-- and their statuses are only ever read within the same synchronous paint, so reuse is safe.
-- Lengths are tracked explicitly rather than via table.getn: these arrays are cleared by
-- direct `x[i] = nil` (never table.remove), which leaves the stored `n` stale on 1.12, so a
-- later table.insert/table.getn would read/append past nil holes and crash (see MEMORY).
local descFree, descUsed, statusFree = {}, {}, {}
local nDescFree, nDescUsed, nStatusFree = 0, 0, 0

local function reclaimDescs()
	for i = nDescUsed, 1, -1 do
		local d = descUsed[i]
		descUsed[i] = nil
		if d.status then
			nStatusFree = nStatusFree + 1; statusFree[nStatusFree] = d.status; d.status = nil
		end
		d.entry, d.apply, d.tag = nil, nil, nil
		d.divider, d.wall, d.header, d.label = nil, nil, nil, nil
		nDescFree = nDescFree + 1; descFree[nDescFree] = d
	end
	nDescUsed = 0
end

local function acquireDesc()
	local d
	if nDescFree > 0 then d = descFree[nDescFree]; descFree[nDescFree] = nil; nDescFree = nDescFree - 1
	else d = {} end
	nDescUsed = nDescUsed + 1; descUsed[nDescUsed] = d
	return d
end

local function pushItem(out, e, apply, tag)
	local d = acquireDesc()
	local s
	if nStatusFree > 0 then s = statusFree[nStatusFree]; statusFree[nStatusFree] = nil; nStatusFree = nStatusFree - 1
	else s = {} end
	d.entry, d.apply, d.tag, d.status = e, apply, tag, s
	C.liveStatus(e, apply, s)
	table.insert(out, d)
end

-- The HUD row stream, in list order: item elements { entry=, status=, apply=, tag= } for
-- every SHOWN entry (buff/cd/food timer rows AND stock count rows), interleaved with divider
-- elements { divider=true, wall=true, header=, label=, entry= } for every ACTIVE divider (a
-- wall for segment-local ordering; header=true when enabled so it paints a category label,
-- header=false when hidden -- still a wall, no label). Off dividers are dropped entirely.
-- Weapon hands while dual-wielding split a buff/food weapon-enchant entry into MH + OH rows
-- with a tag; single-weapon or non-enchant items stay one row. Unordered within segments;
-- C.orderTracked applies the row order and empty headers are pruned at render.
function C.activeBuffs()
	reclaimDescs()
	local out = {}
	local list = QM.me and QM.me.consumables
	if not list then return out end
	local dw = offHandIsWeapon()
	local function push(e, apply, tag) pushItem(out, e, apply, tag) end
	for i = 1, table.getn(list) do
		local e = list[i]
		if QM.isDivider(e) then
			local st = QM.itemState(e)
			if st ~= "off" then
				local d = acquireDesc()
				d.divider, d.wall, d.header, d.label, d.entry = true, true, (st == "enabled"), e.label, e
				table.insert(out, d)
			end
		elseif e and e.id and QM.itemShown(e) then
			local tr = QM.itemTrack(e.id)
			local apply = e.apply
			-- Only a buff/food weapon-enchant splits per hand; a cd/stock weapon item is one row.
			local enchant = (tr == QM.TRACK_BUFF or tr == QM.TRACK_FOOD)
				and (apply == C.APPLY_WEAPON or apply == C.APPLY_MH or apply == C.APPLY_OH)
			if enchant and apply == C.APPLY_WEAPON then
				if dw then push(e, C.APPLY_MH, "MH"); push(e, C.APPLY_OH, "OH")
				else push(e, C.APPLY_WEAPON, nil) end
			elseif enchant and apply == C.APPLY_MH then push(e, C.APPLY_MH, dw and "MH" or nil)
			elseif enchant and apply == C.APPLY_OH then push(e, C.APPLY_OH, dw and "OH" or nil)
			else push(e, apply, nil) end
		end
	end
	return out
end

-- Apply the configured row order (QM.db.options.rowOrder), independently WITHIN each
-- divider-bounded segment (a divider is a wall the ordering never crosses):
--   config   -- list order (as added).
--   active   -- buff-up rows first (list order within the segment), then the rest.
--   duration -- buff-up rows by time left (most first, least at the bottom), then the rest.
local function isUp(d) return d.status.phase == "buff" end
local function byTimeLeftDesc(a, b)
	return (a.status.timeLeft or 1e9) > (b.status.timeLeft or 1e9)
end
function C.orderTracked(data)
	local mode = (QM.db and QM.db.options.rowOrder) or "config"
	local out, seg = {}, {}
	local function flush()
		if table.getn(seg) == 0 then return end
		if mode ~= "config" then
			local up, rest = {}, {}
			for i = 1, table.getn(seg) do
				if isUp(seg[i]) then table.insert(up, seg[i]) else table.insert(rest, seg[i]) end
			end
			if mode == "duration" then
				table.sort(up, byTimeLeftDesc)
			end
			local merged = {}
			for i = 1, table.getn(up)   do table.insert(merged, up[i])   end
			for i = 1, table.getn(rest) do table.insert(merged, rest[i]) end
			seg = merged
		end
		for i = 1, table.getn(seg) do table.insert(out, seg[i]) end
		seg = {}
	end
	for i = 1, table.getn(data) do
		local d = data[i]
		if d.divider then flush(); table.insert(out, d)
		else table.insert(seg, d) end
	end
	flush()
	return out
end

-- Drop what shouldn't be drawn once the order is fixed: hidden-wall dividers (header=false,
-- they only served as ordering boundaries) and any enabled header whose segment has no item
-- rows (items are contiguous within a segment, so the header's segment is empty exactly when
-- the next element is another divider or the end).
local function visibleRows(data)
	local out = {}
	local n = table.getn(data)
	for i = 1, n do
		local d = data[i]
		if d.divider then
			if d.header then
				local nxt = data[i + 1]
				if nxt and not nxt.divider then table.insert(out, d) end
			end
		else
			table.insert(out, d)
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Notification triggers (consumableExpiring / consumableLost)
-- ---------------------------------------------------------------------------
-- Edge memory of whether each buff-tracked item's effect was up last tick, so a buff
-- DROPPING (up -> down) fires "lost" once, and a fresh application re-arms the "running
-- low" notice. The sink + category gates live in Notify.lua; these are just the triggers.

local prevUp   = {}
local lowFloor = {}   -- id -> the bags count last warned at (nil while not low); a
                       -- fresh warning needs a strictly LOWER count, not just a timer,
                       -- so it re-arms only on an actual further drop (see Repair's
                       -- durability band trigger for the same idea on a percentage axis)

local function whiteName(e)
	return "|cffffffff" .. (e.name or ("item " .. (e.id or "?"))) .. "|r"
end

local function runNotifications(data)
	if not QM.Notify then return end
	for i = 1, table.getn(data) do
	  if not data[i].divider then
		local e, st = data[i].entry, data[i].status
		local id = e.id
		local tr = QM.itemTrack(id)
		if tr == QM.TRACK_BUFF or tr == QM.TRACK_FOOD then
			-- A split MH/OH row tracks its own slot, so key the edge memory + dedupe per
			-- (item, slot) and tag the message with the hand.
			local rid = id .. ":" .. (data[i].apply or "")
			local suffix = data[i].tag and (" (" .. data[i].tag .. ")") or ""
			-- A food buff still counts as up while the eating bar is masking it (st.buffUp),
			-- so re-eating over an active buff doesn't false-fire "dropped".
			local up = st.phase == "buff" or st.buffUp
			local left = (st.phase == "buff") and st.timeLeft or st.buffLeft
			if up and not prevUp[rid] then QM.Notify.rearm("qm-exp-" .. rid) end   -- re-arm on (re)application
			if up and left and left <= lowDuration() then
				QM.notify(QM.Notify.label("Running low: ") .. whiteName(e) .. suffix
					.. QM.Notify.label(" (" .. QM.fmtTime(left) .. " left)"),
					{ category = "consumableExpiring", severity = "warn",
					  key = "qm-exp-" .. rid, cooldown = EXPIRE_NOTIFY })
			end
			if prevUp[rid] and not up then
				QM.notify(whiteName(e) .. suffix .. QM.Notify.label(" dropped"),
					{ category = "consumableLost", severity = "alert", key = "qm-lost-" .. rid })
			end
			prevUp[rid] = up
		elseif tr == QM.TRACK_STOCK then
			-- Same red/orange/green band the HUD's count column already paints (see
			-- countColor): "low" here means at/under the row's own Low threshold, not
			-- merely under Target -- otherwise this would fire for nearly every stock row.
			if st.bags <= (e.low or 0) then
				if not lowFloor[id] or st.bags < lowFloor[id] then
					lowFloor[id] = st.bags
					QM.notify(QM.Notify.label("Low stock: ") .. whiteName(e)
						.. QM.Notify.label(" (" .. st.bags .. "/" .. (e.target or 0) .. ")"),
						{ category = "lowConsumable", severity = "warn" })
				end
			else
				lowFloor[id] = nil
			end
		end
	  end
	end
end

-- ---------------------------------------------------------------------------
-- In-raid HUD (Quartermaster_Main): one status row per shown tracked item, each
-- carrying a progress bar (buff/enchant time left, or the cooldown fall-back). Clicking
-- a row consumes the item (C.use). The frame auto-sizes to the row count.
-- ---------------------------------------------------------------------------

local HUD_PAD     = 6
local HUD_TOP     = 18    -- top inset when the "Quartermaster" header is shown
local HUD_TOP_BARE = 4    -- top inset with the header hidden (options.hudHeader)
local HUD_ROW_H   = 18
local HUD_SEP_H   = 6     -- shrunk row for an UNLABELED divider (just the border-band rule)
local HUD_GAP     = 2
local QUESTION    = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Short cooldowns (the 3s shared elixir cooldown) animate too jerkily at the 0.5s TICK, so
-- the HUD repaints on a fast OnUpdate while one is live. hudCdActive tracks whether a shown
-- row is currently on a ticking cooldown; hudFastUntil forces fast repaints for a moment
-- after a use / buff gain (so the bar moves immediately, before the next TICK confirms a cd).
local FAST_INTERVAL = 0.05   -- ~20fps while animating a short cooldown
local hudCdActive   = false
local hudEatActive  = false  -- a shown row is mid-eat (its progress bar animates the same way)
local hudFastUntil  = 0
local hudFastAccum  = 0

-- Request smooth HUD repaints for at least `secs` (default 1). Called the moment a consumable
-- is used or a buff is gained; hudCdActive then keeps fast repaints alive until the cd ends.
function C.kickFast(secs)
	local t = GetTime() + (secs or 1)
	if t > hudFastUntil then hudFastUntil = t end
end

-- The y where the first row begins, tracking whether the header is shown.
local function hudTop()
	return (QM.db and QM.db.options.hudHeader == false) and HUD_TOP_BARE or HUD_TOP
end

local HUD_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Selectable progress-bar textures (General tab); options.barTexture indexes this.
-- 1-2 are stock client textures; the rest are the common SharedMedia bars shipped under
-- our own textures/bars/ (so we don't depend on another addon's files being present).
local BARS = "Interface\\AddOns\\Quartermaster\\textures\\bars\\"
local BAR_TEXTURES = {
	"Interface\\BUTTONS\\WHITE8X8",            -- 1
	"Interface\\TargetingFrame\\UI-StatusBar", -- 2 (default)
	BARS .. "Smooth",      -- 3
	BARS .. "Gloss",       -- 4
	BARS .. "Minimalist",  -- 5
	BARS .. "Graphite",    -- 6
	BARS .. "BantoBar",    -- 7
	BARS .. "Aluminium",   -- 8
	BARS .. "Healbot",     -- 9
	BARS .. "Perl",        -- 10
	BARS .. "Round",       -- 11
	BARS .. "Otravi",      -- 12
}
local BAR_TEXTURE_LABEL = {
	"Flat", "Blizzard", "Smooth", "Gloss", "Minimalist", "Graphite",
	"BantoBar", "Aluminium", "Healbot", "Perl", "Round", "Otravi",
}
C.BAR_TEXTURES = BAR_TEXTURES            -- read by the General tab's preview
C.BAR_TEXTURE_LABEL = BAR_TEXTURE_LABEL

local function hudBarTexture()
	local i = (QM.db and QM.db.options.barTexture) or 2
	return BAR_TEXTURES[i] or BAR_TEXTURES[2]
end

-- Count/name colour by carried bag count vs the per-row low / target thresholds:
-- red (none) -> orange (<= low) -> yellow (< target) -> green (>= target).
local function countColor(bags, low, target)
	if bags <= 0 then return 0.95, 0.25, 0.25 end
	if bags <= (low or 0) then return 1.00, 0.50, 0.10 end
	if bags < (target or 0) then return 1.00, 0.85, 0.20 end
	return 0.35, 0.90, 0.35
end

-- Buff progress-bar colour: green above the low-duration threshold; at/below it a gradient
-- from orange (at the threshold) down to red (at expiry).
local function buffBarColor(timeLeft, low)
	if not timeLeft or timeLeft > low then return 0.20, 0.80, 0.20 end
	local f = (low > 0) and (timeLeft / low) or 0
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	return 0.80 + 0.20 * f, 0.10 + 0.40 * f, 0.0   -- orange @ threshold -> red @ expiry
end

local CD_BAR_COLOR  = { 0.80, 0.20, 0.20 }   -- usability cooldown (buff down, or cd-tracked)
local EAT_BAR_COLOR = { 0.30, 0.70, 0.95 }   -- food eating progress (fills toward Well Fed)
local HUD_CUR_W    = 18   -- "have" count, right-justified so the slash lines up across rows
local HUD_TOTAL_W  = 28   -- "/target", left-justified
local HUD_TIME_W   = 50

local TAG_COLOR = { 0.6, 0.85, 1.0 }   -- MH/OH discriminator tint (distinct from the name)

-- Shorten a label to fit maxWidth px by abbreviating whole words to their initial, left to
-- right, until it fits (the option-gated alternative to the FontString's trailing ellipsis).
-- Measured with the target FontString itself, so it honours the current font/size/outline.
-- Only words that start with a letter are abbreviated (leaves a trailing "(x2)" stack count
-- intact). General-purpose -- intended for non-buff lists later too.
local function abbreviateToFit(fs, text, maxWidth)
	fs:SetText(text)
	if not maxWidth or maxWidth <= 0 or fs:GetStringWidth() <= maxWidth then return text end
	local words = {}
	for w in string.gfind(text, "%S+") do table.insert(words, w) end
	for i = 1, table.getn(words) do
		if string.len(words[i]) > 1 and string.find(words[i], "^%a") then
			words[i] = string.sub(words[i], 1, 1) .. "."
			local cand = table.concat(words, " ")
			fs:SetText(cand)
			if fs:GetStringWidth() <= maxWidth then return cand end
		end
	end
	return table.concat(words, " ")
end

local hudRows = {}
local hudEmpty   -- placeholder line shown while unlocked + empty (so the frame can be placed)
local hudProfileRow  -- lazily-built profile-switch drop button (see makeHudProfileRow)

-- The optional profile-switch row: a drop button styled/sized like an item row, pinned
-- to either end of the HUD (options.hudProfileSwitchPos). Built lazily on first need,
-- since QM.Config isn't loaded yet when this file runs (Config.lua loads after the
-- feature modules -- see the .toc load order). menuParent overrides dropButton's
-- Quartermaster_Config default: that panel is hidden whenever /qm isn't open, and a
-- child of a hidden frame can't show, so the popup would never appear.
local function makeHudProfileRow()
	local f = QM.mainFrame
	local b = QM.Config.dropButton(f, {
		height = HUD_ROW_H, menuWidth = 170, menuParent = UIParent,
		prefix   = "Profile",
		values   = function() return QM.profileNames() end,
		onSelect = function(v) QM.setActiveProfile(v) end,
		get      = function() return QM.activeProfile() end,
	})
	hudProfileRow = b
	return b
end

local hudRepairRow  -- lazily-built durability status row (see makeHudRepairRow)

-- Worst-equipped-durability band: same red/orange/green read as the count columns, just
-- keyed off the Repair tab's own warning threshold instead of a per-item low/target.
local function repairRowColor(pct, threshold)
	if pct < threshold then return 0.95, 0.25, 0.25 end
	if pct < threshold + 20 then return 1.00, 0.85, 0.20 end
	return 0.35, 0.90, 0.35
end

-- The optional repair-status row: a plain (non-interactive, no consume action) bar
-- styled like an item row, reading QM.Repair's last durability scan. Built lazily for
-- the same load-order reason as the profile row above.
local function makeHudRepairRow()
	local f = QM.mainFrame
	local row = CreateFrame("Frame", nil, f)
	row:SetHeight(HUD_ROW_H)

	local bar = CreateFrame("StatusBar", nil, row)
	bar:SetAllPoints(row)
	bar:SetStatusBarTexture(hudBarTexture())
	bar:SetMinMaxValues(0, 100)
	row.bar = bar

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetTexture(0, 0, 0, 0.5)

	local icon = bar:CreateTexture(nil, "OVERLAY")
	icon:SetWidth(HUD_ROW_H - 4); icon:SetHeight(HUD_ROW_H - 4)
	icon:SetPoint("LEFT", 2, 0)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:SetTexture("Interface\\Icons\\Trade_BlacksmithRepair")

	local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
	label:SetText("Repair")
	row.label = label

	local pctText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	pctText:SetPoint("RIGHT", -4, 0)
	pctText:SetWidth(HUD_TIME_W); pctText:SetJustifyH("RIGHT")
	row.pctText = pctText

	row:EnableMouse(true)
	row:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:SetText("Worst equipped durability")
		GameTooltip:AddLine("Repairs automatically at a vendor" ..
			(QM.db.options.autoRepair and "" or " (auto-repair is off)"), 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	hudRepairRow = row
	return row
end

local function paintHudRepairRow(row)
	local worst = (QM.me and QM.me.durability and QM.me.durability.worst) or 100
	local threshold = QM.db.options.repairThreshold or 35
	local r, g, b = repairRowColor(worst, threshold)
	local outline = QM.db.options.hudOutline and true or false
	if row._outline ~= outline then
		row._outline = outline
		local flag = outline and "OUTLINE" or ""
		local font, size = row.label:GetFont()
		row.label:SetFont(font, size, flag)
		row.pctText:SetFont(font, size, flag)
	end
	row.bar:SetValue(worst)
	row.bar:SetStatusBarColor(r, g, b)
	row.pctText:SetText(math.floor(worst + 0.5) .. "%")
	row.pctText:SetTextColor(r, g, b)
end

local function makeHudRow(i)
	local f = QM.mainFrame
	local row = CreateFrame("Button", nil, f)
	row:SetHeight(HUD_ROW_H)   -- placeholder; renderHUD sets the real height + position per row

	local bar = CreateFrame("StatusBar", nil, row)
	bar:SetAllPoints(row)
	bar:SetStatusBarTexture(hudBarTexture())
	bar:SetMinMaxValues(0, 1)
	row.bar = bar

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetTexture(0, 0, 0, 0.5)
	row.bg = bg

	local icon = bar:CreateTexture(nil, "OVERLAY")
	icon:SetWidth(HUD_ROW_H - 4); icon:SetHeight(HUD_ROW_H - 4)
	icon:SetPoint("LEFT", 2, 0)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.icon = icon

	-- Count column ("3" right-justified, then "/10" left-justified) so the slash and the
	-- "have" digits line up vertically across rows; then the name fills the middle, then
	-- the duration on the right.
	local count = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	count:SetPoint("LEFT", icon, "RIGHT", 4, 0)
	count:SetWidth(HUD_CUR_W); count:SetJustifyH("RIGHT")
	row.count = count

	local total = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	total:SetPoint("LEFT", count, "RIGHT", 0, 0)
	total:SetWidth(HUD_TOTAL_W); total:SetJustifyH("LEFT")
	row.total = total

	local time = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	time:SetPoint("RIGHT", -4, 0)
	time:SetWidth(HUD_TIME_W); time:SetJustifyH("RIGHT")
	row.time = time

	-- MH/OH discriminator, sized to its text, sitting just before the name (anchored in paint).
	local tag = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	tag:SetJustifyH("LEFT")
	row.tag = tag

	local name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	name:SetPoint("LEFT", total, "RIGHT", 4, 0)
	name:SetPoint("RIGHT", time, "LEFT", -4, 0)
	name:SetJustifyH("LEFT")
	row.name = name

	-- Block a wasteful re-use: when the item carries the "don't re-use while active" guard
	-- and its buff is up with more than the low-duration threshold left, a plain click is
	-- ignored; shift-click forces it through. apply=="none" (a pure stocked reagent, no
	-- usable mode) is inert regardless of restock -- restock and apply are independent, so
	-- a restock item with a real apply mode (a vendor food you also eat) stays clickable.
	row:SetScript("OnClick", function()
		local e = this.entry
		if not (e and e.id) then return end
		local apply = this.useApply or e.apply
		if not apply or apply == C.APPLY_NONE then return end
		if not IsShiftKeyDown() and QM.db.options.guardReuse then
			local s = C.liveStatus(e, apply)
			if s.phase == "buff" and s.timeLeft and s.timeLeft > lowDuration() then
				QM.print((e.name or ("item " .. e.id)) .. " still active ("
					.. QM.fmtTime(s.timeLeft) .. " left) -- shift-click to use anyway")
				return
			end
		end
		C.use(e.id, apply)
	end)
	row:SetScript("OnEnter", function()
		if not this.id then return end
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink("item:" .. this.id .. ":0:0:0")
		if this.handLabel then
			GameTooltip:AddLine(this.handLabel == "MH" and "Main hand" or "Off hand",
				TAG_COLOR[1], TAG_COLOR[2], TAG_COLOR[3])
		end
		local e = this.entry
		local apply = this.useApply or (e and e.apply)
		if e and e.restock then
			GameTooltip:AddLine("Vendor-restocked -- buys up to Target", 0.5, 0.8, 0.5)
		end
		if not apply or apply == C.APPLY_NONE then
			-- no usable action; the restock line above (if any) is all there is to say
		elseif e and QM.db.options.guardReuse then
			local s = C.liveStatus(e, apply)
			if s.phase == "buff" and s.timeLeft and s.timeLeft > lowDuration() then
				GameTooltip:AddLine("Active -- shift-click to use anyway", 0.5, 0.8, 0.5)
			else
				GameTooltip:AddLine("Click to use", 0.5, 0.8, 0.5)
			end
		else
			GameTooltip:AddLine("Click to use", 0.5, 0.8, 0.5)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	hudRows[i] = row
	return row
end

-- Toggle the outline flag on a row's text (only when it actually changes, since SetFont
-- re-lays the string out). Reads each string's current font/size so it stays in step with
-- whatever template was used.
local function applyRowOutline(row, outline)
	if row._outline == outline then return end
	row._outline = outline
	local flag = outline and "OUTLINE" or ""
	local strings = { row.count, row.total, row.tag, row.name, row.time }
	for i = 1, table.getn(strings) do
		local font, size = strings[i]:GetFont()
		strings[i]:SetFont(font, size, flag)
	end
end

-- Paint a divider element as a header band: a gold category label (or a thin rule when
-- unlabeled), no bar/icon/count/timer, non-interactive (nil id/entry so the click + tooltip
-- scripts no-op). Clears the layout key so a recycled row re-anchors its name as an item.
local function paintHeaderRow(row, d)
	row.id = nil; row.entry = nil; row.useApply = nil; row.handLabel = nil
	row.icon:Hide(); row.count:Hide(); row.total:Hide(); row.time:Hide(); row.tag:Hide()
	row.bar:SetValue(0); row.bar:SetStatusBarColor(0, 0, 0, 0)
	row._layoutKey = nil
	local label = d.label
	if label and label ~= "" then
		row.bg:Hide()
		applyRowOutline(row, QM.db.options.hudOutline and true or false)
		row.name:ClearAllPoints()
		row.name:SetPoint("LEFT", row.bar, "LEFT", 6, 0)
		row.name:SetPoint("RIGHT", row.bar, "RIGHT", -6, 0)
		row.name:SetText(label); row.name:SetTextColor(1, 0.82, 0); row.name:Show()
	else
		row.bg:Hide(); row.name:Hide()   -- unlabeled divider: just an empty gap
	end
	row:Show()
end

-- Available name-column width in LOCAL units (matching GetStringWidth, so it's scale-
-- independent), from the fixed column offsets + the main frame's explicit width: the name
-- FontString has two horizontal anchors, and such a string reports GetWidth()==0 on 1.12.
-- Reads the LIVE frame width, so it tracks a width resize. `wantTotal` = the /target column
-- is shown; a row's MH/OH tag (row.handLabel) eats into the name column too.
local function nameAvail(row, wantTotal)
	local barW = ((QM.mainFrame and QM.mainFrame:GetWidth()) or 0) - 2 * HUD_PAD
	local countRight = (HUD_ROW_H - 2) + 4 + HUD_CUR_W
	local numRight = wantTotal and (countRight + HUD_TOTAL_W) or countRight
	local leftX = numRight + 4 + (row.handLabel and (row.tag:GetStringWidth() + 4) or 0)
	return barW - 8 - HUD_TIME_W - leftX
end

local function paintHudRow(row, d)
	if d.divider then paintHeaderRow(row, d); return end
	local e, s = d.entry, d.status
	local o = QM.db.options
	row.id = e.id
	row.entry = e
	row.useApply = d.apply or e.apply
	row.icon:SetTexture(e.icon or QUESTION)
	row.bg:Show(); row.icon:Show(); row.count:Show(); row.time:Show()
	applyRowOutline(row, o.hudOutline and true or false)

	-- Keep the bar texture in step with the live option (without re-setting it each tick).
	local texIdx = o.barTexture or 2
	if row._tex ~= texIdx then row.bar:SetStatusBarTexture(hudBarTexture()); row._tex = texIdx end

	-- Bar: a live buff shows its remaining fraction (green -> orange -> red gradient); a
	-- buff that is DOWN, or a cd-tracked item, shows its usability cooldown (red); else
	-- empty -- a ready cd item and a down buff off cooldown both carry no fill.
	local low = lowDuration()
	local frac, br, bg, bb
	if s.up then
		frac = (s.duration and s.duration > 0 and s.timeLeft) and (s.timeLeft / s.duration) or 1
		br, bg, bb = buffBarColor(s.timeLeft, low)
	elseif s.phase == "eating" then
		-- Fills as you eat (elapsed / eat time), the inverse of the draining buff/cd bars; a
		-- full bar when the eat time is unknown (or the brief no-aura click-flash).
		frac = s.eatFull and 1 or ((s.duration and s.duration > 0) and ((s.duration - s.timeLeft) / s.duration) or 0)
		br, bg, bb = EAT_BAR_COLOR[1], EAT_BAR_COLOR[2], EAT_BAR_COLOR[3]
	elseif s.phase == "cd" then
		frac = (s.duration and s.duration > 0) and (s.timeLeft / s.duration) or 1
		br, bg, bb = CD_BAR_COLOR[1], CD_BAR_COLOR[2], CD_BAR_COLOR[3]
	elseif s.phase == "stock" then
		-- A stock level gauge: fill toward target, tinted by the same count thresholds.
		local tgt = e.target or 0
		frac = (tgt > 0) and (s.bags / tgt) or (s.bags > 0 and 1 or 0)
		br, bg, bb = countColor(s.bags, e.low, e.target)
	else
		frac = 0; br, bg, bb = 0.25, 0.60, 0.30
	end
	if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
	row.bar:SetValue(frac)
	row.bar:SetStatusBarColor(br, bg, bb)

	-- Count column ("have" right-justified, "/target" left-justified); count/total/name take
	-- the carried-stock colour.
	local cr, cg, cb = countColor(s.bags, e.low, e.target)
	row.count:SetText(tostring(s.bags)); row.count:SetTextColor(cr, cg, cb)
	local wantTotal = o.showTargetCount and true or false
	if wantTotal then
		row.total:SetText("/" .. tostring(e.target or 0)); row.total:SetTextColor(cr, cg, cb); row.total:Show()
	else
		row.total:Hide()
	end

	-- MH/OH tag (own tint) sits before the name; the name fills the gap to the time column.
	-- Both hang off the rightmost numeric column (total when shown, else count). Re-anchor only
	-- when the layout key flips -- total-vs-count and tag-present (recycled rows persist their
	-- last anchor); an MH<->OH text swap keeps the same key (the name follows the tag's edge).
	local tag = d.tag
	row.handLabel = tag
	if tag then
		row.tag:SetText(tag); row.tag:SetTextColor(TAG_COLOR[1], TAG_COLOR[2], TAG_COLOR[3]); row.tag:Show()
	else
		row.tag:Hide()
	end
	local numAnchor = wantTotal and row.total or row.count
	local key = (wantTotal and "T" or "C") .. (tag and "G" or "-")
	if row._layoutKey ~= key then
		row._layoutKey = key
		row.tag:ClearAllPoints()
		row.tag:SetPoint("LEFT", numAnchor, "RIGHT", 4, 0)
		row.name:ClearAllPoints()
		row.name:SetPoint("LEFT", tag and row.tag or numAnchor, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", row.time, "LEFT", -4, 0)
	end

	if o.showItemName then
		local label = e.name or ("item " .. e.id)
		if s.stacks and s.stacks > 1 then label = label .. " (x" .. s.stacks .. ")" end
		row.fullName = label   -- unabbreviated, for the live re-abbreviate pass during a resize
		row.wantTotal = wantTotal
		if o.abbreviateNames then label = abbreviateToFit(row.name, label, nameAvail(row, wantTotal)) end
		row.name:SetText(label); row.name:SetTextColor(cr, cg, cb); row.name:Show()
	else
		row.name:Hide()
	end

	-- Duration column. Buff up: remaining time (green, orange when low). On cooldown (a
	-- cd item, or a buff that's down but still on its usability cooldown): the cd time.
	-- Buff down off cooldown: "--" red. Off cooldown but none carried: "--" red (nothing
	-- to use). Otherwise ready: "Ready".
	if s.up then
		row.time:SetText(QM.fmtTime(s.timeLeft))
		if s.timeLeft and s.timeLeft <= low then row.time:SetTextColor(1, 0.55, 0.1)
		else row.time:SetTextColor(0.4, 0.9, 0.4) end
	elseif s.phase == "eating" then
		row.time:SetText(s.eatFull and "Eating" or QM.fmtTime(s.timeLeft)); row.time:SetTextColor(EAT_BAR_COLOR[1], EAT_BAR_COLOR[2], EAT_BAR_COLOR[3])
	elseif s.phase == "cd" then
		row.time:SetText(QM.fmtTime(s.timeLeft)); row.time:SetTextColor(0.85, 0.45, 0.45)
	elseif s.phase == "stock" then
		row.time:SetText("")   -- count-only: the bar + count columns carry the level
	elseif s.track == "buff" or s.track == "food" or s.bags <= 0 then
		row.time:SetText("--"); row.time:SetTextColor(0.95, 0.3, 0.3)
	else
		row.time:SetText("Ready"); row.time:SetTextColor(0.4, 0.9, 0.4)
	end
	row:Show()
end

local function inRaid()
	return (GetNumRaidMembers() and GetNumRaidMembers() > 0) and true or false
end

local function inGroup()
	return inRaid() or ((GetNumPartyMembers() and GetNumPartyMembers() > 0) and true or false)
end

-- IsInInstance's second return ("party"/"raid"/"pvp"/"arena"/"none"), or nil where the API is
-- absent. Guarded because an absent one would otherwise strand the HUD hidden permanently --
-- without it the instance modes fall back to their nearest group equivalent below.
local function instanceKind()
	if type(IsInInstance) ~= "function" then return nil end
	local inside, kind = IsInInstance()
	if not inside then return "none" end
	return kind or "none"
end

-- Is the HUD suppressed by options.hudShowIn? Separate from the master hudHidden switch.
-- The group tests answer "who am I with", which is true the moment you join a raid and stays
-- true in a city, and false when you solo into an instance -- a different question from "am I
-- actually in there", hence both axes.
local function outOfContext()
	local mode = QM.db.options.hudShowIn or "always"
	if mode == "raid"  then return not inRaid() end
	if mode == "group" then return not inGroup() end
	if mode == "instance" or mode == "raidInstance" then
		local kind = instanceKind()
		if not kind then
			-- No IsInInstance: fall back to the nearest group test rather than suppress forever.
			if mode == "raidInstance" then return not inRaid() end
			return not inGroup()
		end
		if mode == "raidInstance" then return kind ~= "raid" end
		return kind == "none"
	end
	return false
end

-- Live re-abbreviate the shown item rows during a WIDTH resize: a text-only pass (no SetPoint /
-- SetHeight, so it can't trip the 1.12 native-sizing CTD, unlike a full renderHUD). Reads the
-- live frame width via nameAvail, so names shorten/expand as the grip drags.
local function reabbreviateRows()
	if not (QM.db and QM.db.options.abbreviateNames and QM.db.options.showItemName) then return end
	for i = 1, table.getn(hudRows) do
		local row = hudRows[i]
		if row and row.id and row.fullName and row:IsShown() and row.name:IsShown() then
			row.name:SetText(abbreviateToFit(row.name, row.fullName, nameAvail(row, row.wantTotal)))
		end
	end
end

-- An unlabeled divider draws only the ornamental rule, so it gets a short row; everything
-- else (item rows, labeled headers) is a full row. Mirrors paintHeaderRow's labeled test.
local function rowHeight(d)
	if d.divider and not (d.label and d.label ~= "") then return HUD_SEP_H end
	return HUD_ROW_H
end

local function renderHUD(data)
	local f = QM.mainFrame
	if not f or not QM.db then return end
	if f.qmMoving then return end   -- don't re-layout mid drag/resize (1.12 CTD guard)
	if QM.db.options.hudHidden then f:Hide(); return end
	local ctxHidden = outOfContext()

	local title = getglobal("Quartermaster_MainTitle")
	if title then if QM.db.options.hudHeader == false then title:Hide() else title:Show() end end
	local top = hudTop()

	data = visibleRows(C.orderTracked(data or C.activeBuffs()))
	local n = table.getn(data)

	-- The profile-switch row is opt-in and only ever meaningful with 2+ profiles to
	-- pick between; "top"/"bottom" (default top) picks which end of the HUD it pins to.
	local wantProfileRow = QM.db.options.hudProfileSwitch and table.getn(QM.profileNames()) >= 2
	local profileAtTop    = wantProfileRow and (QM.db.options.hudProfileSwitchPos ~= "bottom")
	local profileAtBottom = wantProfileRow and not profileAtTop

	-- The repair-status row shares an edge with the profile row rather than displacing
	-- it: whichever end both land on, the profile row draws first (stays at the true
	-- edge) and the repair row sits just inside it (see the top/bottom blocks below).
	local wantRepairRow = QM.db.options.hudRepairRow
	local repairAtTop    = wantRepairRow and (QM.db.options.hudRepairRowPos ~= "bottom")
	local repairAtBottom = wantRepairRow and not repairAtTop

	-- Placement mode (QM.placingFrames: panel open AND unlocked) keeps the HUD up, empty if
	-- need be, so it can be dragged into place. Outside it the Show HUD gate wins outright --
	-- header, placeholder and all -- and an empty list hides too, unless the profile-switch or
	-- repair row is active, since that shouldn't hide the only control(s) still showing.
	local placing = QM.placingFrames()
	if not placing then
		if ctxHidden then f:Hide(); return end
		if n == 0 and not wantProfileRow and not wantRepairRow then f:Hide(); return end
	end
	if ctxHidden and placing then n = 0 end   -- show the empty placeholder for placement only

	-- Rows have variable height (short separators vs full rows), so they're stacked with a
	-- running y offset rather than a fixed per-index pitch.
	local cdActive, eatActive = false, false
	local y = top

	if profileAtTop then
		local pr = hudProfileRow or makeHudProfileRow()
		pr:ClearAllPoints()
		pr:SetPoint("TOPLEFT", f, "TOPLEFT", HUD_PAD, -y)
		pr:SetPoint("RIGHT", f, "RIGHT", -HUD_PAD, 0)
		pr.setValue(QM.activeProfile())
		pr:Show()
		y = y + HUD_ROW_H + HUD_GAP
	elseif not profileAtBottom and hudProfileRow then
		hudProfileRow:Hide()
	end

	if repairAtTop then
		local rr = hudRepairRow or makeHudRepairRow()
		rr:ClearAllPoints()
		rr:SetPoint("TOPLEFT", f, "TOPLEFT", HUD_PAD, -y)
		rr:SetPoint("RIGHT", f, "RIGHT", -HUD_PAD, 0)
		paintHudRepairRow(rr)
		rr:Show()
		y = y + HUD_ROW_H + HUD_GAP
	elseif not repairAtBottom and hudRepairRow then
		hudRepairRow:Hide()
	end

	for i = 1, n do
		local d = data[i]
		local row = hudRows[i] or makeHudRow(i)
		local h = rowHeight(d)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", f, "TOPLEFT", HUD_PAD, -y)
		row:SetPoint("RIGHT", f, "RIGHT", -HUD_PAD, 0)
		if row._h ~= h then row._h = h; row:SetHeight(h) end
		paintHudRow(row, d)
		local st = d.status
		local ph = st and st.phase
		if ph == "cd" then cdActive = true elseif ph == "eating" then eatActive = true end
		y = y + h + HUD_GAP
	end
	for i = n + 1, table.getn(hudRows) do hudRows[i]:Hide() end
	hudCdActive  = cdActive    -- both drive the fast-repaint OnUpdate (see DB_READY)
	hudEatActive = eatActive

	if n == 0 then
		if not hudEmpty then
			hudEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			hudEmpty:SetText("No tracked items")
		end
		hudEmpty:ClearAllPoints()
		hudEmpty:SetPoint("TOPLEFT", f, "TOPLEFT", HUD_PAD, -y)
		hudEmpty:Show()
		y = y + 18 + HUD_GAP
	else
		if hudEmpty then hudEmpty:Hide() end
	end

	if repairAtBottom then
		local rr = hudRepairRow or makeHudRepairRow()
		rr:ClearAllPoints()
		rr:SetPoint("TOPLEFT", f, "TOPLEFT", HUD_PAD, -y)
		rr:SetPoint("RIGHT", f, "RIGHT", -HUD_PAD, 0)
		paintHudRepairRow(rr)
		rr:Show()
		y = y + HUD_ROW_H + HUD_GAP
	end

	if profileAtBottom then
		local pr = hudProfileRow or makeHudProfileRow()
		pr:ClearAllPoints()
		pr:SetPoint("TOPLEFT", f, "TOPLEFT", HUD_PAD, -y)
		pr:SetPoint("RIGHT", f, "RIGHT", -HUD_PAD, 0)
		pr.setValue(QM.activeProfile())
		pr:Show()
		y = y + HUD_ROW_H + HUD_GAP
	end

	local newH = y - HUD_GAP + HUD_PAD
	-- Only resize when the height actually changes -- never re-SetHeight a frame every tick
	-- (and never while it's being interactively sized), which is what CTDs the 1.12 client.
	if f._hudH ~= newH then f._hudH = newH; f:SetHeight(newH) end
	-- Re-derive TOPLEFT from the stored anchor corner now that height has settled -- the
	-- frame is always pinned TOPLEFT (1.12 non-TOPLEFT SetPoint bug, see Core), so a bottom-
	-- anchored HUD only grows upward if this runs after every height change.
	QM.applyFramePos(f)
	f:Show()
end

-- End any move/resize the HUD thinks is in progress, and repaint. Idempotent, so every
-- release path (the grip, the frame's own OnMouseUp, the TICK net) can call it blind.
-- A stuck qmMoving freezes renderHUD for the rest of the session, so the release paths
-- are deliberately redundant.
function QM.clearHudDrag(f)
	f = f or QM.mainFrame
	if not (f and f.qmMoving) then return end
	f:StopMovingOrSizing()
	f:SetResizable(false)
	f.qmMoving, f.qmResizing = false, false
	if QM.db then
		QM.db.frames.main.width = f:GetWidth()   -- explicitly SetWidth'd, so GetWidth is honest here
		QM.storeFramePos(f)
	end
	renderHUD()
end

-- Toggle the tracker HUD (slash /qm show|hide, and the General-tab check). One place so
-- both paths print + repaint identically.
function QM.setHudHidden(hidden)
	if not QM.db then return end
	QM.db.options.hudHidden = hidden and true or false
	QM.print(hidden and "tracker hidden" or "tracker shown")
	renderHUD()
end

-- One TICK pass: build the live data once, drive the notifications, paint the HUD.
QM.subscribe("TICK", function()
	if not QM.db or not QM.me then return end
	-- Safety net: clear a stuck move/resize flag if a mouse-up was missed off-frame, so a
	-- frozen renderHUD can't strand the HUD (qmMoving is the mid-move CTD guard, see Core).
	-- Only fires on a client that can actually report the button; QM.mouseDown returns nil
	-- when it can't (this one has no IsMouseButtonDown), and there the frame's own OnMouseUp
	-- is what clears the flag instead.
	local f = QM.mainFrame
	if f and f.qmMoving and QM.mouseDown("LeftButton") == false then QM.clearHudDrag(f) end
	updateEatSession()
	local data = C.activeBuffs()
	runNotifications(data)
	renderHUD(data)
end)

-- Process a pending capture-on-use (see C.use): adopt whichever buff appeared since the item
-- was used, retrying each tick until one lands or the window closes. Clears early once the rule
-- validates -- validateTick confirms it on the very next pass, the buff being up by then.
QM.subscribe("TICK", function()
	local p = C.pendingBuffLearn
	if not p then return end
	if QM.itemValidated(p.id) or GetTime() > p.deadline then C.pendingBuffLearn = nil; return end
	if QM.learnSelfBuff(p.id, p.before) then
		C.pendingBuffLearn = nil
		QM.fire("ITEM_META_CHANGED")
	end
end)

-- Process a pending capture-on-apply (see C.use): once the enchant we just applied has landed
-- on its slot, learn its identity for the item. Retries until it lands, then gives up after the
-- deadline (the apply may have been blocked, e.g. by the in-combat enchant restriction).
QM.subscribe("TICK", function()
	local p = C.pendingLearn
	if not p then return end
	if QM.learnWeaponEnchant(p.id, p.slot, p.beforeId, p.beforeName) or GetTime() > p.deadline then
		C.pendingLearn = nil
	end
end)

-- Immediate repaint on the edges that change WHAT is shown (not the timers, which the
-- TICK drives): list edits, inventory rescans, track/match changes, lock toggles.
QM.subscribe("DESIRED_CHANGED",   function() renderHUD() end)
QM.subscribe("INVENTORY_UPDATED", function() renderHUD() end)
QM.subscribe("ITEM_META_CHANGED", function() renderHUD() end)
QM.subscribe("LOCK_CHANGED",      function() renderHUD() end)
QM.subscribe("CONFIG_TOGGLED",    function() renderHUD() end)   -- placement mode gates the Show HUD rule

-- Give the main HUD its backdrop + a lock cue (faint border while unlocked, so it can be
-- found and dragged; subtle once locked). The frame exists by DB_READY (XML OnLoad ran);
-- Core registered it as a moveable but with no onLock, so we attach one here.
QM.subscribe("DB_READY", function()
	local f = QM.mainFrame
	if not f then return end
	f:SetBackdrop(HUD_BACKDROP)
	f:SetWidth((QM.db.frames.main and QM.db.frames.main.width) or 220)
	-- Resizability is armed ONLY during an active grip-resize (below), never permanently:
	-- a resizable frame's native size subsystem reconciles size on StopMovingOrSizing -- which
	-- on a plain MOVE collides with the height we own via SetHeight and CTDs the 1.12 client.
	f:SetMinResize(140, 1)
	f:SetMaxResize(500, 1000)

	-- WIDTH-ONLY resize grip (bottom-right corner), shown only while unlocked. StartSizing
	-- ("RIGHT") moves only the right edge -- the height is content-driven (renderHUD), and a
	-- frame whose height is set by BOTH native sizing and our SetHeight CTDs the 1.12 client,
	-- so we never let the grip touch height. The grip sits ABOVE the rows (higher frame level)
	-- so grabbing the corner can't fall through to a consume click. (cf. FearWardHelper.)
	local grip = CreateFrame("Button", nil, f)
	grip:SetWidth(16); grip:SetHeight(16)
	grip:SetPoint("BOTTOMRIGHT", -2, 2)
	grip:SetFrameLevel(f:GetFrameLevel() + 20)
	grip:SetNormalTexture("Interface\\AddOns\\Quartermaster\\textures\\ResizeGrip")
	grip:SetHighlightTexture("Interface\\AddOns\\Quartermaster\\textures\\ResizeGrip", "ADD")
	grip:SetScript("OnMouseDown", function() f.qmMoving = true; f.qmResizing = true; f:SetResizable(true); f:StartSizing("RIGHT") end)
	grip:SetScript("OnMouseUp", function() QM.clearHudDrag(f) end)
	f.qmGrip = grip

	-- The net that actually catches an off-frame release: a frame receives OnMouseUp for any
	-- press that BEGAN on it no matter where the button comes up, so this covers the drag that
	-- ends over another frame -- which is what the (unavailable) button poll was meant to.
	f:SetScript("OnMouseUp", function() QM.clearHudDrag(this) end)

	f.qmOnLock = function(fr, locked)
		fr:SetBackdropColor(0, 0, 0, locked and 0.6 or 0.8)
		fr:SetBackdropBorderColor(1, 1, 1, locked and 0.25 or 0.6)
		if fr.qmGrip then if locked then fr.qmGrip:Hide() else fr.qmGrip:Show() end end
	end

	-- Fast repaint for short cooldowns: the 0.5s TICK is too coarse to animate a 3s bar, so
	-- while one is live (hudCdActive) or just after a use/buff-gain kick (hudFastUntil) we
	-- repaint at ~20fps. Idle otherwise -- this OnUpdate returns immediately when neither is
	-- set. (Hidden frames don't run OnUpdate, so a hidden HUD costs nothing.)
	f:SetScript("OnUpdate", function()
		if this.qmMoving then
			-- A width drag blocks the full renderHUD (CTD guard), but re-abbreviating names is
			-- text-only and safe, so names track the width live instead of only on release.
			if this.qmResizing then reabbreviateRows() end
			return
		end
		if not (hudCdActive or hudEatActive or GetTime() < hudFastUntil) then hudFastAccum = 0; return end
		hudFastAccum = hudFastAccum + arg1
		if hudFastAccum < FAST_INTERVAL then return end
		hudFastAccum = 0
		renderHUD()
	end)

	QM.applyFrameLock(f)
	renderHUD()
end)

-- Immediate trigger: a buff gained/lost fires PLAYER_AURAS_CHANGED the instant you use a
-- consumable (any tracked elixir's shared cooldown starts at that moment), so kick the fast
-- repaint right away rather than waiting up to 0.5s for the next TICK to notice the cooldown.
QM.on("PLAYER_AURAS_CHANGED", function() C.kickFast(1) end)

-- config tab ("Tracker": the unified per-character list -- buffs, on-use items, and stocked
-- reagents, grouped with dividers; "target" = prep amount / restock cap)
QM.registerConfigTab({
	name = "Tracker", order = 10,
	build = function(parent)
		local page = parent
		QM.Config.listEditor(page, {
			kind      = "consumables",
			targetText = "Target",
			warnText  = "Low",
			applyText = "Use",   -- enables the per-row Use-mode (self/weapon/mh/oh/target/none) column
			trackText = "Track", -- enables the Track-axis column + per-item gear popup
			restock   = true,    -- single list holds stocked reagents too -> show the vendor-restock toggle
			dividers  = true,    -- "Add separator" button + divider rows for grouping
			afterAddRowWidth = 158, -- reserves room for the Row order drop (150w) + its 8px gap
			header    = function(page, title)
				-- Named profiles of this character's list: the dropdown switches, the
				-- buttons manage the set (ops + codec live in Profiles.lua).
				local pHdr = QM.Config.sectionHeader(page, "Profile", 8, -6)
				pHdr:ClearAllPoints()
				if title then pHdr:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
				else pHdr:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -6) end

				-- One drop answers both "switch to my list" and "give me a list to start from":
				-- this character's profiles, then the role presets (Presets.lua) under a
				-- divider. A preset entry builds a NEW profile and switches to it. Entries are
				-- tagged with a control character rather than a readable prefix so a profile
				-- can never be confused for one; an existing profile also wins the lookup in
				-- onSelect regardless, so even a profile named like a preset just switches.
				local PRESET_TAG = "\1p\1"
				local PRESET_SEP = "\1s\1"
				local TAG_LEN = string.len(PRESET_TAG)
				local presetLabels = { [PRESET_SEP] = "--- start a new profile from ---" }
				local presetTips   = {}
				local function presetValues()
					local v = QM.profileNames()
					if not QM.presetNames then return v end
					local pn = QM.presetNames()
					if table.getn(pn) > 0 then table.insert(v, PRESET_SEP) end
					for i = 1, table.getn(pn) do
						local tagged = PRESET_TAG .. pn[i]
						presetLabels[tagged] = "+ " .. pn[i]
						presetTips[tagged]   = "Create a new profile from the '" .. pn[i] .. "' preset"
						table.insert(v, tagged)
					end
					return v
				end

				local profDrop = QM.Config.dropButton(page, {
					width = 150, height = 22, menuWidth = 264,
					labels = presetLabels, tips = presetTips,
					values = presetValues,
					onSelect = function(v)
						if v == PRESET_SEP then return end   -- the divider row: not selectable
						local profiles = QM.me and QM.me.profiles
						if profiles and profiles[v] then QM.setActiveProfile(v); return end
						if string.sub(v, 1, TAG_LEN) == PRESET_TAG then
							local preset = string.sub(v, TAG_LEN + 1)
							QM.Config.confirm("Create a new profile from the '" .. preset .. "' preset?", function()
								QM.applyPreset(preset)
							end)
						end
					end,
					get      = function() return QM.activeProfile() end,
				})
				-- The menu's click handler pushes whatever was picked onto the face, which for a
				-- preset entry is the tag, not a profile. Resolve anything that isn't a real
				-- profile back to the active one so the face can never read as a preset.
				local rawSetValue = profDrop.setValue
				profDrop.setValue = function(v)
					local profiles = QM.me and QM.me.profiles
					if not (profiles and profiles[v]) then v = QM.activeProfile() end
					rawSetValue(v)
				end
				profDrop:SetPoint("TOPLEFT", pHdr, "BOTTOMLEFT", 0, -4)
				-- every profile op ends in a DESIRED_CHANGED, so this one hook keeps the
				-- face current through switch/create/rename/delete/import
				QM.subscribe("DESIRED_CHANGED", function() profDrop.setValue(QM.activeProfile()) end)
				QM.subscribe("CONFIG_SHOWN", function() profDrop.setValue(QM.activeProfile()) end)

				-- keep the border hover-brighten styleFlatButton installed when adding a tooltip
				local function btnTip(b, text)
					b:SetScript("OnEnter", function()
						this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
						GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
						GameTooltip:AddLine(text)
						GameTooltip:Show()
					end)
					b:SetScript("OnLeave", function()
						this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
						GameTooltip:Hide()
					end)
				end
				local function profButton(prev, text, width, tipText, onClick)
					local b = QM.Config.button(page, text, onClick)
					b:SetWidth(width)
					b:SetPoint("LEFT", prev, "RIGHT", 6, 0)
					btnTip(b, tipText)
					return b
				end
				local newBtn = profButton(profDrop, "New", 42, "Create an empty profile", function()
					QM.Config.promptText("New profile", "", function(text)
						return QM.createProfile(text)
					end)
				end)
				local copyBtn = profButton(newBtn, "Copy", 42, "Duplicate the current profile", function()
					local active = QM.activeProfile()
					QM.Config.promptText("Duplicate '" .. active .. "'", QM.uniqueProfileName(active), function(text)
						return QM.createProfile(text, active)
					end)
				end)
				local renBtn = profButton(copyBtn, "Rename", 52, "Rename the current profile", function()
					local active = QM.activeProfile()
					QM.Config.promptText("Rename '" .. active .. "'", active, function(text)
						return QM.renameProfile(active, text)
					end)
				end)
				local delBtn = profButton(renBtn, "Delete", 48, "Delete the current profile", function()
					local active = QM.activeProfile()
					QM.Config.confirm("Delete profile '" .. active .. "'?", function()
						QM.deleteProfile(active)
					end)
				end)
				local expBtn = profButton(delBtn, "Export", 48, "Show the current profile as a copyable string", function()
					local active = QM.activeProfile()
					QM.Config.textDialog({
						title = "Export '" .. active .. "'",
						hint  = "Press Ctrl+C to copy the selected text",
						text  = QM.exportProfile(active) or "",
					})
				end)
				local impBtn = profButton(expBtn, "Import", 48, "Paste an exported profile string to add it as a new profile", function()
					QM.Config.textDialog({
						title = "Import profile",
						hint  = "Paste a profile string (Ctrl+V), then click Import",
						onCommit = function(text)
							local ok, res = QM.importProfile(text)
							if not ok then return false, res end
							QM.print("imported profile '" .. res .. "'")
							return true
						end,
					})
				end)
				profButton(impBtn, "Prep", 40, "Show what's short on the active list, and where the rest is (bank / other characters)", function()
					QM.Config.textDialog({
						title = "Prep: '" .. QM.activeProfile() .. "'",
						hint  = "Shortfall vs Target on this list, and how much of it sits in the bank or on other characters",
						text  = C.prepPlanText(),
						buttonText = "Close",
					})
				end)

				-- Re-use guard: clicking a HUD row whose buff is still up with more than the
				-- low-duration threshold left does nothing (shift-click forces it), so a
				-- mis-click can't waste a flask with most of its time left. Same row as the
				-- low-duration slider (Row order lives inline with "+ Separator" below instead).
				local guard = QM.Config.check(page, "Don't re-use an active buff (shift-click to force)", 0, 0,
					function(v) QM.db.options.guardReuse = v end,
					function() return QM.db.options.guardReuse end)
				guard:ClearAllPoints()
				guard:SetPoint("TOPLEFT", profDrop, "BOTTOMLEFT", 0, -26)

				-- Below which a tracked buff reads as "running low": orange on the HUD
				-- duration + bar, and the consumableExpiring notice. Global across buffs.
				-- Chained off the guard's actual rendered label width so it can't overlap it.
				local lowDur = QM.Config.slider(page, "QuartermasterBuffLowDuration",
					"Low-duration warning", 30, 600, 30, 0, 0,
					function(v) QM.db.options.buffLowDuration = v end,
					function() return QM.db.options.buffLowDuration end,
					function(v) return QM.fmtTime(v) end)
				lowDur:ClearAllPoints()
				lowDur:SetPoint("LEFT", guard.label, "RIGHT", 24, -6)

				-- Consumable notification triggers (the strip's look + master switch are on the
				-- Display tab; these gate which tracker events raise one). Default on, one row --
				-- each check chained off the previous label's rendered width.
				local nHdr = QM.Config.sectionHeader(page, "Notify on", 8, 0)
				nHdr:ClearAllPoints(); nHdr:SetPoint("TOPLEFT", guard, "BOTTOMLEFT", 0, -16)
				local function notifyCheck(text, key)
					return QM.Config.check(page, text, 0, 0,
						function(on) QM.db.options.notify[key] = on end,
						function() return QM.db.options.notify[key] ~= false end)
				end
				local expiring = notifyCheck("Active consumable expiring", "consumableExpiring")
				expiring:ClearAllPoints(); expiring:SetPoint("TOPLEFT", nHdr, "BOTTOMLEFT", 0, -2)
				local lost = notifyCheck("Active consumable lost", "consumableLost")
				lost:ClearAllPoints(); lost:SetPoint("LEFT", expiring.label, "RIGHT", 16, 0)
				local lowStock = notifyCheck("Low consumable stock", "lowConsumable")
				lowStock:ClearAllPoints(); lowStock:SetPoint("LEFT", lost.label, "RIGHT", 16, 0)
				return expiring   -- bottom-most control; the add row stacks below it
			end,
			-- Tracker row order (presentation only), placed inline with "+ Separator" to save
			-- a header row:
			--   config   -- as listed here, with a "weapon"=both row split into MH + OH
			--   active   -- active buffs first, then the rest in list order
			--   duration -- active buffs by time left (least at the bottom), then inactive
			afterAddRow = function(page, anchorBtn)
				local ORDER_LABEL = { config = "Config", active = "Active", duration = "Duration" }
				local ORDER_TIP   = {
					config   = "As listed here (a \"both weapons\" item splits into MH + OH rows)",
					active   = "Active buffs first, then the rest in list order",
					duration = "Active buffs by time left (least at the bottom), then inactive",
				}
				local order = QM.Config.dropButton(page, {
					width = 150, height = 22, menuWidth = 150,
					prefix = "Row order",
					values = { "config", "active", "duration" },
					labels = ORDER_LABEL, tips = ORDER_TIP,
					onSelect = function(v) QM.db.options.rowOrder = v end,
					get      = function() return QM.db.options.rowOrder or "config" end,
				})
				order:SetPoint("LEFT", anchorBtn, "RIGHT", 8, 0)
			end,
		})
	end,
})

-- Inject a buff's spell id into the player-buff tooltip, so the id to type into a buff's
-- Track match is right there on hover. Gated by options.showBuffIds. Which GameTooltip
-- method a buff hover calls depends on the buff display, so we wrap every one we know of:
--   SetUnitAura  -- pfUI (and anything using the C_UnitAuras API); id from the aura record.
--   SetUnitBuff  -- other custom bars; id from UnitBuff's spellId return (Nampower).
--   SetPlayerBuff-- the default Blizzard buff frame; id via SuperWoW's GetPlayerBuffID.
-- Installed at READY (PLAYER_LOGIN) so our wraps land AFTER any addon that hooks the same
-- method at load (e.g. pfUI builds its buttons at load), instead of being overwritten.
local function injectBuffId(tip, id)
	if not (QM.db and QM.db.options.showBuffIds) then return end
	if id and id > 0 then
		tip:AddLine("Buff ID: " .. id, 0.5, 0.8, 1)
		tip:Show()   -- re-fit the tooltip to the added line
	end
end

-- Inject an equipped weapon's temp-enchant id into its tooltip, the discovery aid for an
-- enchantid Track match (the enchant analogue of injectBuffId). Nampower-only: GetEquippedItem
-- (via QM.equippedTempEnchantId) is the sole source of the numeric id -- the tooltip otherwise
-- shows only the enchant name.
local function injectEnchantId(tip, unit, slot)
	if not (QM.db and QM.db.options.showBuffIds) then return end
	if unit ~= "player" or not (slot == 16 or slot == 17) then return end
	local id = QM.equippedTempEnchantId(slot)
	if id and id > 0 then
		tip:AddLine("Enchant ID: " .. id, 0.5, 0.8, 1)
		tip:Show()
	end
end

QM.subscribe("READY", function()
	local origSUA = GameTooltip.SetUnitAura
	if origSUA and QM.caps.cUnitAuras then
		GameTooltip.SetUnitAura = function(self, unit, index, filter)
			origSUA(self, unit, index, filter)
			local aura = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
			injectBuffId(self, aura and aura.spellId)
		end
	end
	local origSUB = GameTooltip.SetUnitBuff
	if origSUB then
		GameTooltip.SetUnitBuff = function(self, unit, index, filter)
			origSUB(self, unit, index, filter)
			if type(UnitBuff) == "function" then
				local _, _, id = UnitBuff(unit, index)
				injectBuffId(self, id)
			end
		end
	end
	local origSPB = GameTooltip.SetPlayerBuff
	if origSPB then
		GameTooltip.SetPlayerBuff = function(self, buffIndex)
			origSPB(self, buffIndex)
			injectBuffId(self, QM.playerBuffSpellId(buffIndex))
		end
	end
	-- Preserve the (hasItem, hasCooldown, repairCost) returns -- callers branch on them.
	local origSII = GameTooltip.SetInventoryItem
	if origSII then
		GameTooltip.SetInventoryItem = function(self, unit, slot)
			local a, b, c = origSII(self, unit, slot)
			injectEnchantId(self, unit, slot)
			return a, b, c
		end
	end
end)

-- The nine screen anchor corners offered by the General tab's HUD anchor drop button.
local ANCHOR_POINTS = {
	"TOPLEFT", "TOP", "TOPRIGHT",
	"LEFT", "CENTER", "RIGHT",
	"BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}

-- config tab ("Display": all appearance + placement -- the tracker HUD AND the notification
-- strip. Feature behaviour/triggers live on their own tabs; only how things LOOK is here.)
QM.registerConfigTab({
	name = "Display", order = 5,
	build = function(parent)
		local page = QM.Config.scrollChild(parent, "QuartermasterDisplayCfgScroll", 456)
		local L = QM.Config.layout(page, -4)
		local BTN_W, COL2 = 160, 300   -- uniform drop/button width; left controls at x=16, right at COL2

		L.section("Frames")
		L.checks(
			{ "Lock frames", function(on) QM.setLocked(on) end, function() return QM.db.options.locked end },
			{ "Hide the tracker HUD", function(on) QM.setHudHidden(on) end, function() return QM.db.options.hudHidden end })

		-- Soft gate (the checkbox above is the hard master switch): while placing frames -- this
		-- panel open AND frames unlocked -- the HUD shows regardless, so it can still be
		-- positioned out of a raid. The group modes answer "who am I with", the instance modes
		-- "am I actually in there"; both axes are offered since they differ (a raid group in a
		-- city, a solo trip into an instance).
		local showInBtn = QM.Config.dropButton(page, {
			width = 220, height = 20, menuWidth = 220, prefix = "Show HUD",
			values = { "always", "group", "raid", "instance", "raidInstance" },
			labels = { always = "Always", group = "In a party or raid", raid = "In a raid group",
			           instance = "In any instance", raidInstance = "In a raid instance" },
			onSelect = function(v) QM.db.options.hudShowIn = v; renderHUD() end,
			get      = function() return QM.db.options.hudShowIn or "always" end,
		})
		showInBtn:SetPoint("TOPLEFT", page, "TOPLEFT", L.col1 + 4, L.y - 1)
		L.advance(26)

		L.section("HUD content")
		L.checks(
			{ "Show HUD header", function(on) QM.db.options.hudHeader = on; renderHUD() end, function() return QM.db.options.hudHeader end },
			{ "Show item name", function(on) QM.db.options.showItemName = on; renderHUD() end, function() return QM.db.options.showItemName end })
		L.checks(
			{ "Abbreviate names to fit", function(on) QM.db.options.abbreviateNames = on; renderHUD() end, function() return QM.db.options.abbreviateNames end },
			{ "Show target count (have/target)", function(on) QM.db.options.showTargetCount = on; renderHUD() end, function() return QM.db.options.showTargetCount end })
		L.checks(
			{ "Outline HUD text", function(on) QM.db.options.hudOutline = on; renderHUD() end, function() return QM.db.options.hudOutline end },
			{ "Show buff/enchant IDs on tooltips", function(on) QM.db.options.showBuffIds = on end, function() return QM.db.options.showBuffIds end })

		-- Only ever drawn on the HUD itself with 2+ profiles (see renderHUD), but the
		-- toggle/position stay configurable regardless of how many exist right now.
		local switchRowY = L.y
		L.checks({ "Show profile-switch row", function(on) QM.db.options.hudProfileSwitch = on; renderHUD() end,
			function() return QM.db.options.hudProfileSwitch end })
		local posBtn = QM.Config.dropButton(page, {
			width = 110, height = 20, menuWidth = 110, prefix = "Position",
			values = { "top", "bottom" }, labels = { top = "Top", bottom = "Bottom" },
			onSelect = function(v) QM.db.options.hudProfileSwitchPos = v; renderHUD() end,
			get      = function() return QM.db.options.hudProfileSwitchPos or "top" end,
		})
		posBtn:SetPoint("TOPLEFT", page, "TOPLEFT", L.col2, switchRowY - 1)

		-- Shares an edge with the profile-switch row above rather than displacing it --
		-- see renderHUD's repairAtTop/profileAtTop ordering.
		local repairRowY = L.y
		L.checks({ "Show repair status row", function(on) QM.db.options.hudRepairRow = on; renderHUD() end,
			function() return QM.db.options.hudRepairRow end })
		local repairPosBtn = QM.Config.dropButton(page, {
			width = 110, height = 20, menuWidth = 110, prefix = "Position",
			values = { "top", "bottom" }, labels = { top = "Top", bottom = "Bottom" },
			onSelect = function(v) QM.db.options.hudRepairRowPos = v; renderHUD() end,
			get      = function() return QM.db.options.hudRepairRowPos or "top" end,
		})
		repairPosBtn:SetPoint("TOPLEFT", page, "TOPLEFT", L.col2, repairRowY - 1)

		L.section("HUD appearance")
		QM.Config.slider(page, "QuartermasterHudScale", "HUD scale", 0.5, 2.0, 0.05, 16, L.y - 14,
			function(v)
				QM.db.frames.main.scale = v
				if QM.mainFrame then QM.applyFrameLayout(QM.mainFrame) end
			end,
			function() return QM.db.frames.main.scale end,
			function(v) return string.format("%.2f", v) end)
		L.advance(46)

		-- Bar texture (its face is a live preview bar labelled "Progress bar texture"; the name
		-- shows only in the open menu) alongside the HUD anchor corner.
		local texLabels, texValues, texSwatches = {}, {}, {}
		for i = 1, table.getn(C.BAR_TEXTURE_LABEL) do
			texLabels[i] = C.BAR_TEXTURE_LABEL[i]; texValues[i] = i; texSwatches[i] = C.BAR_TEXTURES[i]
		end
		local texBtn = QM.Config.dropButton(page, {
			width = BTN_W, height = 22, menuWidth = BTN_W, staticLabel = "Progress bar texture",
			values = texValues, labels = texLabels, swatches = texSwatches,
			onSelect = function(v) QM.db.options.barTexture = v; renderHUD() end,
			get      = function() return QM.db.options.barTexture end,
		})
		texBtn:SetPoint("TOPLEFT", 16, L.y)
		local anchorBtn = QM.Config.dropButton(page, {
			width = BTN_W, height = 22, menuWidth = BTN_W, prefix = "HUD anchor",
			values = ANCHOR_POINTS,
			onSelect = function(v) if QM.mainFrame then QM.setFrameAnchor(QM.mainFrame, v) end end,
			get      = function() return QM.db.frames.main.point or "CENTER" end,
		})
		anchorBtn:SetPoint("TOPLEFT", COL2, L.y)
		L.advance(30)

		-- Notification strip: its look + placement + master switch live here (the per-category
		-- triggers are on the feature tabs that raise them -- Tracker, Repair).
		L.section("Notifications")
		L.checks({ "Enable notifications", function(on) QM.db.options.notify.enabled = on end,
			function() return QM.db.options.notify.enabled end })
		QM.Config.slider(page, "QuartermasterNotifyDuration", "Display time", 2, 15, 1, 16, L.y - 14,
			function(v) QM.Notify.setDuration(v) end,
			function() return QM.db.options.notify.duration end,
			function(v) return v .. "s" end)
		QM.Config.slider(page, "QuartermasterNotifyFontSize", "Font size", 8, 24, 1, COL2, L.y - 14,
			function(v) QM.Notify.setFontSize(v) end,
			function() return QM.db.options.notify.fontSize end)
		L.advance(46)
		local notifyAnchor = QM.Config.dropButton(page, {
			width = BTN_W, height = 22, menuWidth = BTN_W, prefix = "Notify anchor",
			values = ANCHOR_POINTS,
			onSelect = function(v) QM.Notify.setPoint(v) end,
			get      = function() return QM.db.frames.notify.point or "CENTER" end,
		})
		notifyAnchor:SetPoint("TOPLEFT", 16, L.y)
		local testBtn = QM.Config.button(page, "Show test notifications", function() QM.Notify.test() end)
		testBtn:SetWidth(BTN_W); testBtn:SetPoint("TOPLEFT", COL2, L.y)
		L.advance(30)
	end,
})
