-- Quartermaster -- ItemMeta
-- Account-wide, item-intrinsic tracking metadata keyed by itemID: how an item is
-- live-tracked (track = buff/cd/none), the descriptor used to match its effect, and
-- the effect's max duration. Per-ID, not per-character -- a flask buffs everyone the
-- same. A static SEED holds curated defaults; QM.db.items holds only user/learned
-- overrides; QM.itemMeta(id) merges the two per field, so a seed change still reaches
-- untouched fields. Seed harvested from ../ConsumesManager/Itemlist.lua.

local QM = Quartermaster

-- Track axis -- drives the in-raid live indicator only (separate from `apply`):
--   "buff" -- track the effect's time-left (and stacks when readable); when the
--             buff is down, fall back to showing the item's usability cooldown.
--   "cd"   -- no trackable effect (healing/mana pot); just show the cooldown.
--   "food" -- like buff, but with an extra EATING phase: while you sit and eat, a progress
--             bar fills toward the (learned) time to receive the Well Fed buff, then it
--             transitions to that buff's duration on success. See Consumables' eat session.
--   "stock" -- no timer; a count-only HUD row (carried count vs target). Reagents and
--             other "just tell me how many I have" items default here.
QM.TRACK_BUFF, QM.TRACK_CD, QM.TRACK_STOCK = "buff", "cd", "stock"
QM.TRACK_FOOD = "food"
local VALID_TRACK = { buff = true, cd = true, food = true, stock = true }

-- ---------------------------------------------------------------------------
-- Central capability / compatibility table
-- ---------------------------------------------------------------------------
-- One source of truth for which optional native services / sibling addons are
-- present, so modules branch on shared flags instead of re-probing. We prefer
-- SuperWoW / Nampower and never depend on ClassicAPI. Detected once at READY: all
-- addons are loaded by PLAYER_LOGIN and a client's native services don't change
-- mid-session.
--   superwow     -- SetAutoloot or SpellInfo present (either injected global).
--   nampower     -- GetNampowerVersion present; nampowerVer = {maj,min,pat}.
--   equippedItem -- GetEquippedItem present (Nampower 2.18+; temp-enchant identity).
--   cUnitAuras   -- C_UnitAuras.GetAuraDataByIndex present (from the ClassicAPI addon, a
--                   pfUI dependency -- NOT native; used only with a fallback, never required).
--   itemIdCooldown -- GetItemIdCooldown present (Nampower; surfaces shared CATEGORY cooldowns).
--   turtleMail   -- TurtleMail loaded with a usable send API (delegate multi-send).
--   aux          -- aux loaded; reuse its name->id index instead of scanning (set in ItemDB).
QM.caps = QM.caps or {}

QM.subscribe("READY", function()
	QM.caps.superwow = (SetAutoloot ~= nil) or (SpellInfo ~= nil)

	if type(GetNampowerVersion) == "function" then
		local maj, min, pat = GetNampowerVersion()
		QM.caps.nampower    = true
		QM.caps.nampowerVer = { tonumber(maj) or 0, tonumber(min) or 0, tonumber(pat) or 0 }
	else
		QM.caps.nampower = false
	end
	-- Probe the exact function the enchantid match needs (Nampower v2.18+), rather than
	-- inferring it from the version number -- immune to version-scheme quirks.
	QM.caps.equippedItem = (type(GetEquippedItem) == "function")

	-- Aura API from the ClassicAPI addon (a pfUI dependency, so present when pfUI is) -- NOT
	-- native, so always gate on this cap and fall back. Gives direct spellId/timing per aura
	-- index; the only way to read what a pfUI buff button shows (it calls SetUnitAura).
	QM.caps.cUnitAuras = (type(C_UnitAuras) == "table"
		and type(C_UnitAuras.GetAuraDataByIndex) == "function") or false

	-- Nampower's per-item cooldown read. Unlike the bag-slot GetContainerItemCooldown it
	-- reports shared CATEGORY cooldowns (e.g. one elixir putting the others on cooldown).
	QM.caps.itemIdCooldown = (type(GetItemIdCooldown) == "function")

	QM.caps.turtleMail = (IsAddOnLoaded("TurtleMail")
		and TurtleMail
		and type(TurtleMail.sendmail_send) == "function"
		and type(TurtleMail.sendmail_clear) == "function"
		and true) or false
end)

-- The Track axis's fourth value was renamed "none" -> "stock" (no longer "hide from the
-- HUD" -- that is the Hidden state's job -- but "show a count-only row"). Convert any
-- persisted override once; idempotent (nothing left to convert on a later load).
QM.subscribe("DB_READY", function()
	local store = QM.db and QM.db.items
	if not store then return end
	for _, rec in pairs(store) do
		if rec.track == "none" then rec.track = "stock" end
	end
end)

-- Which match strategies each capability tier unlocks. icon/name/enchantname are
-- always available (native GetPlayerBuffTexture read / tooltip scan); id needs
-- SuperWoW (buff spellId); enchantid needs Nampower's GetEquippedItem.
local MATCH_REQUIRES = { id = "superwow", enchantid = "equippedItem" }
local MATCH_REQUIRES_LABEL = { superwow = "SuperWoW", equippedItem = "Nampower (GetEquippedItem)" }
local VALID_MATCH_BY = { icon = true, name = true, id = true, enchantid = true, enchantname = true }

-- Is a given match strategy usable on this client right now?
function QM.itemMatchAvailable(by)
	local need = MATCH_REQUIRES[by]
	if not need then return true end
	return (QM.caps[need] and true) or false
end

-- ---------------------------------------------------------------------------
-- Curated seed -- id -> { track, maxDuration (seconds), icon }
-- ---------------------------------------------------------------------------
-- Curated default, never written to SavedVariables (static like APPLY_OVERRIDES).
-- `match` is intentionally absent -- the buff/enchant identity is learned at runtime,
-- since a buff icon often differs from the item icon. `maxDuration` is omitted for
-- cd/none items (cd reads the live GetContainerItemCooldown; none has no timer).
-- Weapon poisons use vanilla's 30-min application.
local SEED = {
	-- Elixirs (stat buffs)
	[13452] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_32" }, -- Elixir of the Mongoose
	[9187]  = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_94" }, -- Elixir of Greater Agility
	[13453] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_40" }, -- Elixir of Brute Force
	[13447] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_29" }, -- Elixir of the Sages
	[13454] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_25" }, -- Greater Arcane Elixir
	[13445] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_66" }, -- Elixir of Superior Defense
	[17708] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_03" }, -- Elixir of Frost Power
	[22193] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_21" }, -- Bloodkelp Elixir of Resistance
	[3825]  = { track = "buff", maxDuration = 3600, match = { by = "id", value = 3593 }, icon = "Interface\\Icons\\INV_Potion_43" }, -- Elixir of Fortitude (buff 3593)
	[9206]  = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_61" }, -- Elixir of Giants
	[9179]  = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_10" }, -- Elixir of Greater Intellect
	[50237] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_22" }, -- Elixir of Greater Nature Power
	[21546] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_60" }, -- Elixir of Greater Firepower
	[3386]  = { track = "stock",                    icon = "Interface\\Icons\\INV_Potion_12" }, -- Elixir of Poison Resistance (instant cure)
	[9264]  = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_46" }, -- Elixir of Shadow Power
	[61224] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_12" }, -- Dreamshard Elixir
	[9224]  = { track = "buff", maxDuration = 300,  icon = "Interface\\Icons\\INV_Potion_27" }, -- Elixir of Demonslaying
	[55048] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_32" }, -- Elixir of Greater Arcane Power

	-- Flasks (2h, persist through death)
	[13513] = { track = "buff", maxDuration = 7200, icon = "Interface\\Icons\\INV_Potion_48" }, -- Flask of Chromatic Resistance
	[13511] = { track = "buff", maxDuration = 7200, icon = "Interface\\Icons\\INV_Potion_97" }, -- Flask of Distilled Wisdom
	[13512] = { track = "buff", maxDuration = 7200, icon = "Interface\\Icons\\INV_Potion_41" }, -- Flask of Supreme Power
	[13510] = { track = "buff", maxDuration = 7200, icon = "Interface\\Icons\\INV_Potion_62" }, -- Flask of the Titans
	[13506] = { track = "buff", maxDuration = 60,   icon = "Interface\\Icons\\INV_Potion_26" }, -- Flask of Petrification

	-- Protection Potions (absorb shields)
	[13457] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_24" }, -- Greater Fire Protection Potion
	[13456] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_20" }, -- Greater Frost Protection Potion
	[13458] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_22" }, -- Greater Nature Protection Potion
	[13459] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_23" }, -- Greater Shadow Protection Potion
	[13461] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_83" }, -- Greater Arcane Protection Potion
	[13460] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_09" }, -- Greater Holy Protection Potion
	[9036]  = { track = "buff", maxDuration = 180,  icon = "Interface\\Icons\\INV_Potion_16" }, -- Magic Resistance Potion
	[3384]  = { track = "buff", maxDuration = 180,  icon = "Interface\\Icons\\INV_Potion_08" }, -- Minor Magic Resistance Potion

	-- Weapon Enhancements (temp weapon enchants; 30 min unless noted)
	[12404] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Stone_SharpeningStone_05" }, -- Dense Sharpening Stone
	[12645] = { track = "stock",                    icon = "Interface\\Icons\\INV_Misc_Armorkit_20" },        -- Thorium Shield Spike (permanent)
	[20748] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_100" }, -- Brilliant Mana Oil
	[20749] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_105" }, -- Brilliant Wizard Oil
	[23123] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_26" },  -- Blessed Wizard Oil
	[3829]  = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_20" },  -- Frost Oil
	[23122] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\inv_stone_sharpeningstone_02" }, -- Consecrated Sharpening Stone
	[18262] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Stone_02" },   -- Elemental Sharpening Stone
	[8928]  = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\Ability_Poisons" }, -- Instant Poison VI
	[3776]  = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_19" },  -- Crippling Poison II
	[20844] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\Ability_Rogue_DualWeild" }, -- Deadly Poison V
	[9186]  = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\Spell_Nature_NullifyDisease" }, -- Mind-numbing Poison III
	[10922] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\Ability_PoisonSting" }, -- Wound Poison IV
	[12643] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_stone_weightstone_05" }, -- Dense Weightstone
	[47409] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\inv_corrosive_01" }, -- Corrosive Poison II
	[54010] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\Spell_Nature_Slowpoison" }, -- Dissolvent Poison II
	[65032] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\spell_nature_nullifypoison" }, -- Agitating Poison

	-- Combat Potions (short reactive buffs; share the 2-min potion cooldown)
	[13455] = { track = "buff", maxDuration = 120,  icon = "Interface\\Icons\\INV_Potion_69" }, -- Greater Stoneshield Potion
	[13442] = { track = "buff", maxDuration = 20,   icon = "Interface\\Icons\\INV_Potion_41" }, -- Mighty Rage Potion
	[20007] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\INV_Potion_45" }, -- Mageblood Potion
	[61423] = { track = "buff", maxDuration = 1200, icon = "Interface\\Icons\\INV_Potion_10" }, -- Dreamtonic
	[61181] = { track = "buff", maxDuration = 30,   icon = "Interface\\Icons\\inv_potion_08" }, -- Potion of Quickness

	-- Utility Items (reactive; the usability cooldown is the live signal)
	[20008] = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_07" }, -- Living Action Potion
	[3387]  = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_62" }, -- Limited Invulnerability Potion
	[5634]  = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_04" }, -- Free Action Potion
	[61225] = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_36" }, -- Lucidity Potion
	[9030]  = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_01" }, -- Restorative Potion
	[4390]  = { track = "cd",   icon = "Interface\\Icons\\INV_Misc_Bomb_08" }, -- Iron Grenade
	[15993] = { track = "cd",   icon = "Interface\\Icons\\INV_Misc_Bomb_08" }, -- Thorium Grenade
	[18641] = { track = "cd",   icon = "Interface\\Icons\\INV_Misc_Bomb_06" }, -- Dense Dynamite
	[10646] = { track = "cd",   icon = "Interface\\Icons\\spell_fire_selfdestruct" }, -- Goblin Sapper Charge
	[61675] = { track = "cd",   icon = "Interface\\Icons\\INV_Drink_Milk_05" }, -- Nordanaar Herbal Tea
	[13462] = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_31" }, -- Purification Potion
	[13444] = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_76" }, -- Major Mana Potion
	[13446] = { track = "cd",   icon = "Interface\\Icons\\INV_Potion_54" }, -- Major Healing Potion
	[7676]  = { track = "cd",   icon = "Interface\\Icons\\INV_Drink_Milk_05" }, -- Thistle Tea
	[20004] = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\inv_potion_80" }, -- Major Troll's Blood Potion
	[14530] = { track = "cd",   icon = "Interface\\Icons\\inv_misc_bandage_12" }, -- Heavy Runecloth Bandage
	[13180] = { track = "cd",   icon = "Interface\\Icons\\inv_potion_75" }, -- Stratholme Holy Water
	[20520] = { track = "cd",   icon = "Interface\\Icons\\spell_shadow_sealofkings" }, -- Dark Rune
	[12662] = { track = "cd",   icon = "Interface\\Icons\\inv_misc_rune_04" }, -- Demonic Rune
	[9172]  = { track = "cd",   icon = "Interface\\Icons\\inv_potion_25" }, -- Invisibility Potion
	[3823]  = { track = "cd",   icon = "Interface\\Icons\\inv_potion_18" }, -- Lesser Invisibility Potion

	-- Food Buffs (Well Fed; 1h for full meals, 15 min for the rest). track="food" adds the
	-- sit-and-eat progress phase before the Well Fed buff lands (see Consumables eat session).
	[21023] = { track = "food", maxDuration = 900, icon = "Interface\\Icons\\INV_Misc_Food_65" }, -- Dirge's Kickin' Chimaerok Chops
	[18254] = { track = "food", maxDuration = 900, icon = "Interface\\Icons\\INV_Misc_Food_63" }, -- Runn Tum Tuber Surprise
	[13931] = { track = "food", maxDuration = 900, icon = "Interface\\Icons\\INV_Drink_17" },     -- Nightfin Soup
	[20452] = { track = "food", maxDuration = 900, icon = "Interface\\Icons\\INV_Misc_Food_64" }, -- Smoked Desert Dumplings
	[51711] = { track = "food", maxDuration = 900, icon = "Interface\\Icons\\INV_Misc_Food_40" }, -- Sweet Mountain Berry (Agility)
	[51714] = { track = "food", maxDuration = 900, icon = "Interface\\Icons\\INV_Misc_Food_40" }, -- Sweet Mountain Berry (Stamina)
	[51717] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Mushroom_11" },  -- Hardened Mushroom
	[51720] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Mushroom_11" },  -- Power Mushroom
	[13935] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Fish_20" }, -- Baked Salmon
	[13933] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Drink_17" },     -- Lobster Stew
	[12218] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Food_06" }, -- Monster Omelet
	[60977] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Food_06" }, -- Danonzo's Tel'Abim Delight
	[60978] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Food_07" }, -- Danonzo's Tel'Abim Medley
	[60976] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Food_09" }, -- Danonzo's Tel'Abim Surprise
	[84041] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\inv_drink_19" },     -- Gilneas Hot Stew
	[21217] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\inv_misc_fish_21" }, -- Sagefish Delight
	[18045] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\inv_misc_food_47" }, -- Tender Wolf Steak
	[53015] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\inv_drink_17" },     -- Gurubashi Gumbo
	[84040] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Fishe_Au_Chocolate" }, -- Le Fishe Au Chocolat
	[83309] = { track = "food", maxDuration = 900,  icon = "Interface\\Icons\\INV_Misc_Food_Salad" }, -- Empowering Herbal Salad

	-- Alcohol (15 min)
	[18269] = { track = "buff", maxDuration = 900,  icon = "Interface\\Icons\\INV_Drink_03" }, -- Gordok Green Grog
	[18284] = { track = "buff", maxDuration = 900,  icon = "Interface\\Icons\\INV_Drink_05" }, -- Kreeg's Stout Beatdown
	[61174] = { track = "buff", maxDuration = 900,  icon = "Interface\\Icons\\INV_Drink_Waterskin_05" }, -- Medivh's Merlot
	[61175] = { track = "buff", maxDuration = 900,  icon = "Interface\\Icons\\INV_Drink_Waterskin_01" }, -- Medivh's Merlot Blue
	[21151] = { track = "buff", maxDuration = 900,  icon = "Interface\\Icons\\INV_Drink_04" }, -- Rumsey Rum Black Label

	-- Special Buffs (jujus, zanza, scorpok set, scroll)
	[12451] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Misc_MonsterScales_11" }, -- Juju Power
	[12460] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Misc_MonsterScales_07" }, -- Juju Might
	[12455] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Misc_MonsterScales_15" }, -- Juju Ember
	[12457] = { track = "buff", maxDuration = 600,  icon = "Interface\\Icons\\INV_Misc_MonsterScales_09" }, -- Juju Chill
	[12450] = { track = "buff", maxDuration = 20,   icon = "Interface\\Icons\\inv_misc_monsterscales_17" }, -- Juju Flurry
	[12820] = { track = "buff", maxDuration = 1200, icon = "Interface\\Icons\\INV_Potion_92" }, -- Winterfall Firewater
	[20079] = { track = "buff", maxDuration = 7200, icon = "Interface\\Icons\\INV_Potion_30" }, -- Spirit of Zanza
	[20081] = { track = "buff", maxDuration = 7200, icon = "Interface\\Icons\\inv_potion_31" }, -- Swiftness of Zanza
	[8412]  = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\inv_misc_dust_02" }, -- Ground Scorpok Assay
	[8410]  = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\inv_stone_15" },    -- R.O.I.D.S.
	[8423]  = { track = "buff", maxDuration = 3600, icon = "Interface\\Icons\\inv_potion_32" },   -- Cerebral Cortex Compound
	[9088]  = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Potion_28" },   -- Gift of Arthas
	[10305] = { track = "buff", maxDuration = 1800, icon = "Interface\\Icons\\INV_Scroll_07" },   -- Scroll of Protection IV
}

-- Food grants the generic "Well Fed" buff whose icon differs from the item icon, so the
-- derived icon default (below) can't confirm it -- seed a name match for the cooked-food
-- group instead, so they validate on the first meal. (You only eat one food at a time, so
-- matching the shared "Well Fed" name is enough to answer "is my food buff up".)
local WELL_FED = { 21023, 18254, 13931, 20452, 13935, 13933, 12218, 21217, 18045, 53015 }
for i = 1, table.getn(WELL_FED) do
	local s = SEED[WELL_FED[i]]
	if s then s.match = { by = "name", value = "Well Fed" } end
end

-- Exposed read-only for inspection / future seeding tools (do not mutate).
QM.itemSeed = SEED

-- ---------------------------------------------------------------------------
-- Accessors (curated-default-plus-learned-override merge)
-- ---------------------------------------------------------------------------

-- Merged metadata for an item: a FRESH table combining the persisted override
-- (QM.db.items[id], per field) over the static SEED, falling back to track="stock".
-- Always returns a table (never nil), so callers can read .track directly.
function QM.itemMeta(id)
	local seed  = SEED[id]
	local saved = QM.db and QM.db.items and QM.db.items[id]
	local m = {
		track       = (saved and saved.track) or (seed and seed.track) or QM.TRACK_STOCK,
		maxDuration = (saved and saved.maxDuration) or (seed and seed.maxDuration),
		icon        = (saved and saved.icon) or (seed and seed.icon),
		match       = (saved and saved.match) or (seed and seed.match),
		eatTime     = (saved and saved.eatTime) or (seed and seed.eatTime),   -- food: learned secs to Well Fed
		eatMatch    = (saved and saved.eatMatch) or (seed and seed.eatMatch), -- food: learned eating-aura identity
	}
	return m
end

-- Convenience single-field readers.
function QM.itemTrack(id)       return QM.itemMeta(id).track end
function QM.itemMatch(id)       return QM.itemMeta(id).match end

-- Effect duration in seconds: explicit (override/seed) wins, else the value parsed from the
-- item's tooltip "Use:" line (QM.tooltipDuration), else nil. The parsed value is derived, never
-- persisted -- it backstops items intentionally left on auto so their HUD bar still scales right.
function QM.itemMaxDuration(id)
	local d = QM.itemMeta(id).maxDuration
	if d then return d end
	return QM.tooltipDuration(id)
end
function QM.itemEatTime(id)     return QM.itemMeta(id).eatTime end
function QM.itemEatMatch(id)    return QM.itemMeta(id).eatMatch end

-- SuperWoW's GetPlayerBuffID returns the buff's spell id as a SIGNED 16-bit int, so any
-- id above 32767 comes back negative; undo that wrap. nil without SuperWoW / for an empty
-- buff slot. `buffIndex` is a GetPlayerBuff index (the same one SetPlayerBuff takes).
function QM.playerBuffSpellId(buffIndex)
	if type(GetPlayerBuffID) ~= "function" then return nil end
	local id = GetPlayerBuffID(buffIndex)
	if not id then return nil end
	if id < -1 then id = id + 65536 end
	return id
end

-- ---------------------------------------------------------------------------
-- Setters (write ONLY the changed field into the persisted override store)
-- ---------------------------------------------------------------------------
-- Sparse on purpose: we never copy a whole seed record into SavedVariables, so a
-- later seed change still reaches the user for fields they haven't touched.

local function overrideRecord(id)
	if not (QM.db and id) then return nil end
	local store = QM.db.items
	if not store then store = {}; QM.db.items = store end
	local rec = store[id]
	if not rec then rec = {}; store[id] = rec end
	return rec
end

-- Set the Track axis ("buff"/"cd"/"food"/"stock"). Returns false on a bad value.
function QM.setItemTrack(id, track)
	if not VALID_TRACK[track] then return false, "unknown track: " .. tostring(track) end
	local rec = overrideRecord(id); if not rec then return false end
	rec.track = track
	QM.fire("ITEM_META_CHANGED")
	return true
end

-- Set the effect's max duration in seconds (nil clears the override).
function QM.setItemMaxDuration(id, seconds)
	local rec = overrideRecord(id); if not rec then return false end
	rec.maxDuration = tonumber(seconds)
	QM.fire("ITEM_META_CHANGED")
	return true
end

-- Set a food item's learned eat-to-Well-Fed time in seconds (nil clears it). Written once
-- when an eat cycle is first observed end-to-end; thereafter it scales the eating bar.
function QM.setItemEatTime(id, seconds)
	local rec = overrideRecord(id); if not rec then return false end
	rec.eatTime = tonumber(seconds)
	QM.fire("ITEM_META_CHANGED")
	return true
end

-- Set a food item's eating-aura identity (the "still eating" signal), a match descriptor
-- { by, value } -- learned automatically on the first eat, or set/cleared in the gear popup.
-- Pass by=nil to clear (forgets the learned aura for THIS item only).
function QM.setItemEatMatch(id, by, value)
	local rec = overrideRecord(id); if not rec then return false end
	if by == nil then rec.eatMatch = nil
	else rec.eatMatch = { by = by, value = value } end
	QM.fire("ITEM_META_CHANGED")
	return true
end

-- Clear all learned eat data (aura + time) for one food item.
function QM.resetItemEat(id)
	local rec = overrideRecord(id); if not rec then return false end
	rec.eatMatch = nil
	rec.eatTime = nil
	QM.fire("ITEM_META_CHANGED")
	return true
end

-- Set the match descriptor used to find this item's effect in raid. `by` is one of
-- icon / name / id / enchantid / enchantname; pass by=nil to clear it. id/enchantid
-- need SuperWoW / Nampower respectively -- refused (graceful degrade) when absent so
-- a caller can fall back to icon/name.
function QM.setItemMatch(id, by, value)
	local rec = overrideRecord(id); if not rec then return false end
	if by == nil then
		rec.match = nil
		rec.validated = nil   -- a rule change must be re-confirmed by observation
		QM.fire("ITEM_META_CHANGED")
		return true
	end
	if not VALID_MATCH_BY[by] then return false, "unknown match type: " .. tostring(by) end
	if not QM.itemMatchAvailable(by) then
		return false, "match by " .. by .. " needs " .. MATCH_REQUIRES_LABEL[MATCH_REQUIRES[by]]
	end
	rec.match = { by = by, value = value }
	rec.validated = nil
	QM.fire("ITEM_META_CHANGED")
	return true
end

-- ---------------------------------------------------------------------------
-- Effective match + passive validation
-- ---------------------------------------------------------------------------
-- A buff-tracked item with no explicit match still gets a sensible DEFAULT: match by
-- the item's own icon (the buff icon equals the item icon for most vanilla elixirs/
-- flasks/oils/potions). That default isn't trusted blindly -- a rule (default OR set by
-- the user) starts "pending" and only becomes "validated" once we actually OBSERVE the
-- effect on the player/weapon in game (see the validation tick). Items whose buff icon
-- differs from the item icon (food's generic "Well Fed", a few stat buffs) stay pending
-- until corrected in the gear popup, which is the cue to fix them.

local function isWeaponApply(apply)
	return apply == "weapon" or apply == "mh" or apply == "oh"
end

-- The match rule actually in force for an item, or nil (nothing to match on). `apply` matters:
--   weapon -- matched ONLY by an explicit enchant identity (enchantid/enchantname), learned on
--             apply or set in the gear popup. NO guessed default: a loose "any temp enchant"
--             rule would validate against whatever OTHER enchant is on the weapon (the cause of
--             the mis-validation / mis-learn), and a buff icon/name describes a player buff, not
--             a weapon enchant -- so neither is honoured here even if stored.
--   self/target -- the explicit override/seed match, else a derived buff-icon default (the buff
--             icon equals the item icon for most elixirs/flasks/potions).
function QM.itemMatchEffective(id, apply)
	local meta = QM.itemMeta(id)
	if isWeaponApply(apply) then
		if meta.match and (meta.match.by == "enchantid" or meta.match.by == "enchantname") then
			return meta.match
		end
		return nil
	end
	if meta.match then return meta.match end
	if (meta.track == QM.TRACK_BUFF or meta.track == QM.TRACK_FOOD) and meta.icon then
		return { by = "icon", value = meta.icon }
	end
	return nil
end

-- Has the in-force rule been confirmed by observing the effect in game (account-wide)?
function QM.itemValidated(id)
	local rec = QM.db and QM.db.items and QM.db.items[id]
	return (rec and rec.validated) and true or false
end

-- Match state for the UI: "none" (no rule -> red), "pending" (rule set but unseen ->
-- yellow), "validated" (effect observed -> green). A weapon enchant with no learned identity
-- yet reads "pending", not "none": it auto-learns on first apply (capture-on-apply), the same
-- waiting state as a configured elixir before its buff is seen -- not an error to fix.
function QM.itemMatchStatus(id, apply)
	if not QM.itemMatchEffective(id, apply) then
		local tr = QM.itemTrack(id)
		if isWeaponApply(apply) and (tr == QM.TRACK_BUFF or tr == QM.TRACK_FOOD) then return "pending" end
		return "none"
	end
	if QM.itemValidated(id) then return "validated" end
	return "pending"
end

-- ---- effect-present probes (shared tooltip/aura scan helpers) -----------------
local scanTip

-- Inventory slot ids the apply mode covers (16 main hand, 17 off hand).
local function weaponSlots(apply)
	if apply == "oh" then return { 17 } end
	if apply == "mh" then return { 16 } end
	return { 16, 17 }
end

local function getScanTip()
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "QuartermasterScanTip", nil, "GameTooltipTemplate")
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	return scanTip
end

-- ---- tooltip duration parse ---------------------------------------------------
-- Seconds-per-unit for the duration words vanilla tooltips use (lower-cased, no plurals
-- distinction needed -- "min"/"minute"/"minutes" all map the same).
local TIME_UNIT = {
	sec = 1, secs = 1, second = 1, seconds = 1,
	min = 60, mins = 60, minute = 60, minutes = 60,
	hour = 3600, hours = 3600, hr = 3600, hrs = 3600,
}

-- Buff duration (s) from one tooltip line, or nil. The CD clause ("CD: 2.0 min") is dropped
-- first so it can't be read as the duration; the buff length is then anchored on "for"/"lasts"
-- so incidental times ("over 30 sec", "spend at least 10 seconds eating") are skipped.
local function parseDurationLine(text)
	if not text then return nil end
	local low = string.lower(text)
	local cd = string.find(low, "cd:", 1, true)
	if cd then low = string.sub(low, 1, cd - 1) end
	local n, unit
	_, _, n, unit = string.find(low, "for%s+the%s+next%s+(%d+)%s*(%a+)")
	if not n then _, _, n, unit = string.find(low, "for%s+(%d+)%s*(%a+)") end
	if not n then _, _, n, unit = string.find(low, "lasts%s+(%d+)%s*(%a+)") end
	if not n then return nil end
	local mult = TIME_UNIT[unit]
	if not mult then return nil end
	return tonumber(n) * mult
end

-- Parsed effect duration (s) for an item from its tooltip, or nil. Cached per session (the WDB
-- tooltip text doesn't change); we only cache once the tooltip is actually populated, so an item
-- not yet in the WDB cache is retried on a later call instead of being stuck at nil.
local durCache = {}
function QM.tooltipDuration(id)
	if not id then return nil end
	local c = durCache[id]
	if c ~= nil then return c or nil end
	local tip = getScanTip()
	tip:ClearLines()
	tip:SetHyperlink("item:" .. id)   -- reads the offline WDB cache for any seen item
	local n = tip:NumLines()
	if not n or n == 0 then return nil end
	local found
	for i = 1, n do
		local fs = getglobal("QuartermasterScanTipTextLeft" .. i)
		local d = parseDurationLine(fs and fs:GetText())
		if d then found = d; break end
	end
	durCache[id] = found or false
	return found
end

-- Name on tooltip line 1 of the indexed player buff, or nil.
local function buffName(buffIndex)
	local tip = getScanTip()
	tip:ClearLines()
	tip:SetPlayerBuff(buffIndex)
	local fs = getglobal("QuartermasterScanTipTextLeft1")
	local t = fs and fs:GetText()
	if t and t ~= "" then return t end
end

-- The enchant NAME off a weapon slot's tooltip: the green time-marked line, time marker
-- stripped -- the portable, zero-dependency identity (SuperCleveRoid's idiom).
local function weaponEnchantName(slot)
	local tip = getScanTip()
	tip:ClearLines()
	tip:SetInventoryItem("player", slot)
	for i = 1, tip:NumLines() do
		local fs = getglobal("QuartermasterScanTipTextLeft" .. i)
		local line = fs and fs:GetText()
		if line then
			local r, g, b = fs:GetTextColor()
			if g > 0.8 and r < 0.2 and b < 0.2 then
				local low = string.lower(line)
				if string.find(low, "%(") and (string.find(low, " min%)") or string.find(low, " sec%)") or string.find(low, "charge")) then
					return QM.trim(string.gsub(line, "%s*%(.-%)%s*$", ""))
				end
			end
		end
	end
end

-- Whether a weapon slot currently carries a temp enchant. GetWeaponEnchantInfo is the LIVE,
-- reliable presence signal (16 main hand, 17 off hand) -- unlike GetEquippedItem's id, which is
-- a snapshot that can lag the apply.
local function slotHasEnchant(slot)
	local hasM, _, _, hasO = GetWeaponEnchantInfo()
	if slot == 17 then return (hasO and true) or false end
	return (hasM and true) or false
end

-- Current (id, name) of a slot's temp enchant -- the "before" snapshot capture-on-apply records
-- prior to replacing an enchant, so it can wait for the NEW one to actually land.
function QM.weaponEnchantIdentity(slot)
	return QM.equippedTempEnchantId(slot), weaponEnchantName(slot)
end

-- Learn THIS item's weapon-enchant identity from a slot we just enchanted with it -- the only
-- attributable moment (a passive slot scan can't tell which listed item produced the enchant).
-- Gated on GetWeaponEnchantInfo presence so it waits for the enchant to actually LAND (an apply
-- onto an empty weapon, or one held behind a confirm, lands a beat later). `beforeId`/`beforeName`
-- are the slot's identity BEFORE we applied: when REPLACING, a read that still matches them is the
-- stale prior enchant, so wait (committing early is how a mana oil over a sharpening stone learned
-- the STONE). Prefers the exact enchant id (Nampower); falls back to the live tooltip name when the
-- id snapshot hasn't refreshed -- which is the empty-weapon case. AUTHORITATIVE: overwrites a
-- stale/mis-learned match. Returns the learned by-kind, "done" if already correct, or nil to retry.
function QM.learnWeaponEnchant(id, slot, beforeId, beforeName)
	if not (id and slot) then return nil end
	if not slotHasEnchant(slot) then return nil end   -- not landed yet; keep waiting
	local eid = QM.equippedTempEnchantId(slot)
	local nm  = weaponEnchantName(slot)
	-- Has the NEW enchant landed? The live tooltip name is the freshness signal (the id snapshot
	-- can lag a replace, and may never refresh from empty); fall back to the id only when there is
	-- no readable name, else bail and retry.
	local landed
	if nm and nm ~= "" then landed = (nm ~= beforeName)
	elseif eid and eid > 0 then landed = (eid ~= beforeId)
	else landed = false end
	if not landed then return nil end
	local cur = QM.itemMeta(id).match
	-- Prefer the exact id, but only when it is FRESH (not the stale prior id); else the live name.
	if eid and eid > 0 and eid ~= beforeId then
		if cur and cur.by == "enchantid" and cur.value == eid then return "done" end
		QM.setItemMatch(id, "enchantid", eid); return "enchantid"
	end
	if nm and nm ~= "" then
		if cur and cur.by == "enchantname" and cur.value == nm then return "done" end
		QM.setItemMatch(id, "enchantname", nm); return "enchantname"
	end
	return nil
end

-- Manual learn from the weapon as it is RIGHT NOW (the gear popup's "learn from weapon"): the
-- user asserts the current enchant on this item's slot(s) is this item, so there is no "before"
-- to diff -- take the first enchanted slot for the apply mode. Returns the learned by-kind or nil.
function QM.learnWeaponEnchantNow(id, apply)
	local slots = weaponSlots(apply)
	for s = 1, table.getn(slots) do
		local r = QM.learnWeaponEnchant(id, slots[s])
		if r then return r end
	end
	return nil
end

-- Live status of the matching self-buff: present, time left (s), stacks. Walks the
-- player's HELPFUL buffs for one satisfying the rule, then reads its remaining time
-- (GetPlayerBuffTimeLeft) and stack count (GetPlayerBuffApplications) -- both native 1.12.
function QM.selfBuffPresent(m)
	if not m then return false end
	if not GetPlayerBuff then return false end
	local i = 0
	while true do
		local bi = GetPlayerBuff(i, "HELPFUL")
		if bi == -1 or bi == nil then break end
		local hit
		if m.by == "icon" then
			-- Compare case-INsensitively: the buff aura's icon path and the item's icon
			-- path point at the same file but differ in case on 1.12 (GetPlayerBuffTexture
			-- vs GetItemInfo) -- an exact == never matches (cf. FearWardHelper's lower()).
			local tex = GetPlayerBuffTexture(bi)
			hit = tex and m.value and string.lower(tex) == string.lower(m.value)
		elseif m.by == "name" then
			local nm = buffName(bi)
			hit = nm and m.value and string.lower(nm) == string.lower(m.value)
		elseif m.by == "id" then
			hit = QM.playerBuffSpellId(bi) == m.value
		end
		if hit then
			local tl = GetPlayerBuffTimeLeft and GetPlayerBuffTimeLeft(bi, "HELPFUL") or nil
			local st = GetPlayerBuffApplications and GetPlayerBuffApplications(bi) or nil
			if st and st < 2 then st = nil end   -- a single application is not a "stack"
			return true, tl, st
		end
		i = i + 1
	end
	return false
end

-- Live status of the matching weapon temp-enchant: present, time left (s), charges.
-- The TIMER always comes from GetWeaponEnchantInfo -- its per-slot expiration (ms) counts
-- down each call, whereas GetEquippedItem's tempEnchantmentTimeLeftMs is a snapshot taken at
-- application and only refreshed on an inventory change (it would freeze on the HUD). The
-- presence/charges come from GetWeaponEnchantInfo too; it is identity-blind (any temp enchant
-- on the slot counts), so the rule's enchant id/name is what disambiguates WHICH enchant: an
-- enchantname rule via the slot tooltip, an enchantid rule via Nampower's GetEquippedItem (whose
-- ambiguous slot index QM.equippedTempEnchantId resolves, below).

-- The temp-enchant id on a 1-indexed inventory slot (16 main hand, 17 off hand), or nil.
-- GetEquippedItem's slot index is ambiguous across Nampower builds (0-indexed here, but the raw
-- 1-indexed slot in some sibling addons), so resolve it by picking the candidate whose itemId
-- matches the slot's actually-equipped weapon -- the 0-indexed form is tried first, so when no
-- itemId is available to confirm against, prior behaviour is unchanged. Nampower only.
function QM.equippedTempEnchantId(slot)
	if not (QM.caps.equippedItem and type(GetEquippedItem) == "function") then return nil end
	local wantId
	local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
	if link then local _, _, s = string.find(link, "item:(%d+)"); wantId = tonumber(s) end
	local cands = { slot - 1, slot }
	local fallback
	for i = 1, 2 do
		local info = GetEquippedItem("player", cands[i])
		if info and info.itemId then
			if wantId then
				if info.itemId == wantId then return info.tempEnchantId end
			elseif not fallback then
				fallback = info.tempEnchantId
			end
		end
	end
	return fallback
end

local function effectWeapon(m, apply)
	local slots = weaponSlots(apply)
	local hasM, expM, chM, hasO, expO, chO = GetWeaponEnchantInfo()
	for s = 1, table.getn(slots) do
		local slot = slots[s]
		local has, exp, ch
		if slot == 16 then has, exp, ch = hasM, expM, chM else has, exp, ch = hasO, expO, chO end
		if has then
			-- A weapon rule is always enchantid/enchantname (itemMatchEffective guarantees it);
			-- default false so an unexpected rule never falsely matches an arbitrary enchant.
			local ok = false
			if m.by == "enchantid" then
				ok = (QM.equippedTempEnchantId(slot) == m.value)
			elseif m.by == "enchantname" then
				local nm = weaponEnchantName(slot)
				ok = nm and m.value and string.lower(nm) == string.lower(m.value)
			end
			if ok then return true, exp and exp / 1000 or nil, ch end
		end
	end
	return false
end

-- Live status of an item's tracked effect under the in-force match rule: present(bool),
-- timeLeft(seconds|nil), count(stacks|charges|nil). The in-raid HUD reads this; the
-- passive validator below takes just the presence flag.
function QM.itemEffect(id, apply)
	local m = QM.itemMatchEffective(id, apply)
	if not m then return false end
	if isWeaponApply(apply) then return effectWeapon(m, apply) end
	return QM.selfBuffPresent(m)
end

-- Passive validation: each tick, confirm any configured-but-unseen buff rule the moment
-- its effect is actually up on the player (or weapon). Replaces the old manual probe --
-- it needs no arming and only scans items still pending, so it idles cheaply once the
-- common (icon-equals-item-icon) cases have self-confirmed.
local function validateTick()
	local me = QM.me
	if not me then return end
	local changed = false
	local function scan(list)
		if not list then return end
		for i = 1, table.getn(list) do
			local e = list[i]
			local tr = e and e.id and QM.itemTrack(e.id)
			local apply = e and (e.apply or "self")
			if e and e.id and QM.itemActive(e)
			   and (tr == QM.TRACK_BUFF or tr == QM.TRACK_FOOD)
			   and not QM.itemValidated(e.id)
			   and QM.itemMatchEffective(e.id, apply)
			   and QM.itemEffect(e.id, apply) then
				local rec = overrideRecord(e.id)
				if rec then rec.validated = true; changed = true end
			end
		end
	end
	scan(me.consumables)
	if changed then QM.fire("ITEM_META_CHANGED") end
end

QM.subscribe("TICK", validateTick)
