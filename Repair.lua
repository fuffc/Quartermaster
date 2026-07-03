-- Quartermaster -- Repair
-- Auto-repair at repair-capable vendors + gear durability status (a warning when
-- the worst item drops below a threshold).

local QM = Quartermaster
QM.Repair = {}
local Rp = QM.Repair

-- Equipped slots that take durability damage (weapons, armor; not rings/necks/etc).
local DURABILITY_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }

-- 1.12 has no GetInventoryItemDurability (added in 2.0); read it off the item tooltip
-- the way pfUI/ShaguPlates do. A hidden, owner-less tooltip we set per slot and parse.
local scanTip = CreateFrame("GameTooltip", "QuartermasterDurabilityTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
-- DURABILITY_TEMPLATE is e.g. "Durability %d / %d"; turn it into a capture pattern.
local DURABILITY_PATTERN = string.gsub(DURABILITY_TEMPLATE or "Durability %d / %d", "%%d", "(%%d+)")

local function slotDurability(slot)
	scanTip:ClearLines()
	if not scanTip:SetInventoryItem("player", slot) then return end
	for i = 1, scanTip:NumLines() do
		local fs = getglobal("QuartermasterDurabilityTipTextLeft" .. i)
		local text = fs and fs:GetText()
		if text then
			local _, _, cur, max = string.find(text, DURABILITY_PATTERN)
			if cur and max then return tonumber(cur), tonumber(max) end
		end
	end
end

-- Worst equipped durability as a percentage (100 = nothing damaged / no gear read).
function Rp.scanDurability()
	local worst = 100
	for i = 1, table.getn(DURABILITY_SLOTS) do
		local cur, max = slotDurability(DURABILITY_SLOTS[i])
		if cur and max and max > 0 then
			local pct = cur / max * 100
			if pct < worst then worst = pct end
		end
	end
	if QM.me then QM.me.durability = { worst = worst, scannedAt = time() } end
	QM.fire("DURABILITY_UPDATED")
	return worst
end

-- True when the worst item is under the configured warning threshold.
function Rp.needsRepair()
	local d = QM.me and QM.me.durability
	if not d then return false end
	return d.worst < (QM.db and QM.db.options.repairThreshold or 35)
end

-- Repair everything at the open merchant if we can afford it.
function Rp.autoRepair()
	if not CanMerchantRepair() then return end
	local cost, can = GetRepairAllCost()
	if not can or not cost or cost <= 0 then return end
	if GetMoney() >= cost then
		RepairAllItems()
		QM.print("repaired for " .. QM.money(cost))
	else
		QM.print("can't afford repairs (" .. QM.money(cost) .. ")")
	end
end

QM.on("MERCHANT_SHOW", function()
	if QM.db and QM.db.options.autoRepair then Rp.autoRepair() end
end)
QM.on("UPDATE_INVENTORY_DURABILITY", function() Rp.scanDurability() end)
QM.subscribe("READY", function() Rp.scanDurability() end)

-- Low-durability notification trigger. Deduped by a shrinking percentage BAND rather
-- than a timer: a fresh warning only fires when the worst item's durability drops into
-- a NEW, lower band -- 5%-wide normally (so a threshold of 33% first warns for the 30%
-- band, then again at 25%, 20%, ...), narrowing to 2%-wide once under 10% (damage there
-- is more urgent). Recovering back above the threshold clears the band memory so the
-- next drop warns immediately. `force` (PLAYER_ENTERING_WORLD below) bypasses the
-- banding entirely -- login and every zone/instance transition warns regardless.
local lastBand = nil

local function durabilityBand(pct)
	local step = (pct < 10) and 2 or 5
	return math.floor(pct / step) * step
end

local function checkRepairNotify(force)
	if not QM.Notify then return end
	local worst = QM.me and QM.me.durability and QM.me.durability.worst
	if not worst then return end
	if not Rp.needsRepair() then
		lastBand = nil
		return
	end
	local band = durabilityBand(worst)
	if force or not lastBand or band < lastBand then
		lastBand = band
		QM.notify(QM.Notify.label("Durability low -- worst item at ") .. math.floor(worst + 0.5) .. "%",
			{ category = "lowRepair", severity = "warn" })
	end
end

QM.subscribe("DURABILITY_UPDATED", function() checkRepairNotify(false) end)
QM.on("PLAYER_ENTERING_WORLD", function() checkRepairNotify(true) end)

-- config tab
QM.registerConfigTab({
	name = "Repair", order = 30,
	build = function(parent)
		local page = QM.Config.scrollChild(parent, "QuartermasterRepairCfgScroll", 130)
		local L = QM.Config.layout(page, -8)

		-- Auto-repair (behaviour) beside its notification trigger -- the strip's look + master
		-- switch are on the Display tab; the trigger lives with the feature. Default on.
		L.checks(
			{ "Auto-repair at vendors", function(on) QM.db.options.autoRepair = on end,
				function() return QM.db.options.autoRepair end },
			{ "Notify on low durability", function(on) QM.db.options.notify.lowRepair = on end,
				function() return QM.db.options.notify.lowRepair ~= false end })

		QM.Config.slider(page, "QuartermasterRepairThreshold", "Durability warning below",
			0, 100, 5, 16, L.y - 14,
			function(v) QM.db.options.repairThreshold = v end,
			function() return QM.db.options.repairThreshold end,
			function(v) return v .. "%" end)
	end,
})
