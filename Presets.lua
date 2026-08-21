-- Quartermaster -- Presets
-- Ready-made raid consumable lists, offered from the Tracker tab's "Preset" drop. Picking
-- one builds a NEW profile from it and switches to it: presets are templates, never a live
-- list, so applying one can't disturb anything already set up.
--
-- Item ids were resolved against pfQuest's vanilla and Turtle name databases; Turtle-only
-- items (Dreamshard Elixir, the Concoctions, Potion of Quickness, ...) are in here too.
-- Each row is { itemID, target }. Targets are the quantities from the source list; where it
-- offered alternatives ("2x A or 2x B") BOTH are listed as their own rows, and where it named
-- a food category rather than an item, a representative food is used. Trim what you don't
-- want with each row's state chip rather than deleting, so it's easy to flip back on.

local QM = Quartermaster

QM.presets = {
	{
		name = "Hunter - Ranged/BM",
		items = {
			{ 13452, 2 },   -- Elixir of the Mongoose
			{ 13928, 6 },   -- Grilled Squid (agility food)
			{ 12451, 6 },   -- Juju Power (BM)
			{ 10309, 6 },   -- Scroll of Agility IV (BM)
			{ 13511, 1 },   -- Flask of Distilled Wisdom
			{ 13510, 1 },   -- Flask of the Titans
			{ 12450, 12 },  -- Juju Flurry (BM)
			{ 8412,  2 },   -- Ground Scorpok Assay
			{ 20007, 2 },   -- Mageblood Potion
		},
	},
	{
		name = "Caster DPS - Mage/Lock/Priest/Boomkin",
		items = {
			{ 13512, 1 },   -- Flask of Supreme Power
			{ 13454, 2 },   -- Greater Arcane Elixir
			{ 9264,  2 },   -- Elixir of Shadow Power
			{ 55048, 2 },   -- Elixir of Greater Arcane Power
			{ 17708, 2 },   -- Elixir of Frost Power
			{ 21546, 2 },   -- Elixir of Greater Firepower
			{ 61224, 2 },   -- Dreamshard Elixir
			{ 20007, 2 },   -- Mageblood Potion
			{ 61423, 5 },   -- Dreamtonic
			{ 20749, 1 },   -- Brilliant Wizard Oil
			{ 18254, 6 },   -- Runn Tum Tuber Surprise (intellect food)
			{ 13931, 6 },   -- Nightfin Soup (mp5 food)
			{ 61181, 12 },  -- Potion of Quickness
			{ 12450, 12 },  -- Juju Flurry
			{ 8423,  2 },   -- Cerebral Cortex Compound
			{ 61175, 5 },   -- Medivh's Merlot Blue
		},
	},
	{
		name = "Magic Melee - Spelladin/Shaman",
		items = {
			{ 47410, 2 },   -- Concoction of the Emerald Mongoose
			{ 13452, 2 },   -- Elixir of the Mongoose
			{ 61224, 2 },   -- Dreamshard Elixir
			{ 47412, 2 },   -- Concoction of the Arcane Giant
			{ 13454, 2 },   -- Greater Arcane Elixir
			{ 9206,  2 },   -- Elixir of Giants
			{ 12451, 5 },   -- Juju Power
			{ 20007, 2 },   -- Mageblood Potion
			{ 47414, 5 },   -- Concoction of the Dreamwater
			{ 12820, 5 },   -- Winterfall Firewater
			{ 61423, 5 },   -- Dreamtonic
			{ 20452, 6 },   -- Smoked Desert Dumplings (strength food)
			{ 20749, 1 },   -- Brilliant Wizard Oil
			{ 23122, 4 },   -- Consecrated Sharpening Stone (paladin)
			{ 13512, 1 },   -- Flask of Supreme Power
			{ 13510, 1 },   -- Flask of the Titans
			{ 61181, 12 },  -- Potion of Quickness
			{ 12450, 12 },  -- Juju Flurry
			{ 8410,  2 },   -- R.O.I.D.S.
			{ 8412,  2 },   -- Ground Scorpok Assay
			{ 8423,  2 },   -- Cerebral Cortex Compound
			{ 61175, 5 },   -- Medivh's Merlot Blue
		},
	},
	{
		name = "Physical Melee - Warr/Dru/Rogue",
		items = {
			{ 13452, 2 },   -- Elixir of the Mongoose
			{ 9206,  2 },   -- Elixir of Giants
			{ 12451, 5 },   -- Juju Power
			{ 12820, 6 },   -- Winterfall Firewater
			{ 20452, 6 },   -- Smoked Desert Dumplings (strength food)
			{ 13928, 6 },   -- Grilled Squid (agility food)
			{ 18262, 6 },   -- Elemental Sharpening Stone
			{ 7676,  10 },  -- Thistle Tea (rogue)
			{ 13510, 1 },   -- Flask of the Titans
			{ 61224, 2 },   -- Dreamshard Elixir (rogue)
			{ 47410, 2 },   -- Concoction of the Emerald Mongoose
			{ 61181, 12 },  -- Potion of Quickness
			{ 12450, 12 },  -- Juju Flurry
			{ 8410,  2 },   -- R.O.I.D.S.
			{ 8412,  2 },   -- Ground Scorpok Assay
			{ 20007, 2 },   -- Mageblood Potion
		},
	},
	{
		name = "Healer",
		items = {
			{ 13511, 1 },   -- Flask of Distilled Wisdom
			{ 61224, 2 },   -- Dreamshard Elixir
			{ 20007, 2 },   -- Mageblood Potion
			{ 20748, 1 },   -- Brilliant Mana Oil
			{ 13931, 6 },   -- Nightfin Soup (mp5 food)
			{ 21217, 6 },   -- Sagefish Delight (spirit food)
			{ 12450, 12 },  -- Juju Flurry
			{ 8424,  2 },   -- Gizzard Gum
			{ 8423,  2 },   -- Cerebral Cortex Compound
			{ 61175, 5 },   -- Medivh's Merlot Blue
			{ 3387,  1 },   -- Limited Invulnerability Potion
		},
	},
	{
		name = "All Raiders - baseline",
		items = {
			{ 13457, 10 },  -- Greater Fire Protection Potion
			{ 13459, 3 },   -- Greater Shadow Protection Potion
			{ 13461, 2 },   -- Greater Arcane Protection Potion
			{ 13446, 10 },  -- Major Healing Potion
			{ 13444, 10 },  -- Major Mana Potion
			{ 61675, 10 },  -- Nordanaar Herbal Tea
			{ 15723, 10 },  -- Tea with Sugar
			{ 11951, 10 },  -- Whipper Root Tuber
			{ 11952, 10 },  -- Night Dragon's Breath
			{ 20520, 10 },  -- Dark Rune
			{ 12662, 10 },  -- Demonic Rune
			{ 20081, 1 },   -- Swiftness of Zanza
			{ 20079, 1 },   -- Spirit of Zanza
			{ 9030,  1 },   -- Restorative Potion
			{ 18253, 5 },   -- Major Rejuvenation Potion
			{ 16023, 1 },   -- Masterwork Target Dummy (engineer)
			{ 10646, 5 },   -- Goblin Sapper Charge (engineer)
			{ 3825,  2 },   -- Elixir of Fortitude (low hp)
			{ 18045, 6 },   -- Tender Wolf Steak (low hp)
			{ 51717, 6 },   -- Hardened Mushroom (low hp)
			{ 21151, 10 },  -- Rumsey Rum Black Label (low hp)
		},
	},
	{
		name = "Main Tank",
		items = {
			{ 13510, 2 },   -- Flask of the Titans
			{ 13445, 2 },   -- Elixir of Superior Defense
			{ 8951,  2 },   -- Elixir of Greater Defense
			{ 3825,  2 },   -- Elixir of Fortitude
			{ 18045, 10 },  -- Tender Wolf Steak
			{ 21151, 10 },  -- Rumsey Rum Black Label
			{ 13455, 2 },   -- Greater Stoneshield Potion
			{ 8411,  2 },   -- Lung Juice Cocktail
			{ 12450, 12 },  -- Juju Flurry
			{ 51717, 5 },   -- Hardened Mushroom
			{ 12455, 5 },   -- Juju Ember
		},
	},
	{
		name = "Tank - Warrior/Druid",
		items = {
			{ 13452, 2 },   -- Elixir of the Mongoose
			{ 9206,  2 },   -- Elixir of Giants
			{ 12451, 5 },   -- Juju Power
			{ 12820, 4 },   -- Winterfall Firewater
			{ 18262, 6 },   -- Elemental Sharpening Stone
		},
	},
	{
		name = "Tank - Paladin",
		items = {
			{ 9187,  2 },   -- Elixir of Greater Agility
			{ 13452, 2 },   -- Elixir of the Mongoose
			{ 13454, 2 },   -- Greater Arcane Elixir
			{ 61224, 2 },   -- Dreamshard Elixir
			{ 20749, 1 },   -- Brilliant Wizard Oil
			{ 61423, 5 },   -- Dreamtonic
			{ 47412, 2 },   -- Concoction of the Arcane Giant
			{ 47410, 2 },   -- Concoction of the Emerald Mongoose
			{ 47414, 5 },   -- Concoction of the Dreamwater
		},
	},
}

-- Preset display names, in table order, for the config drop.
function QM.presetNames()
	local names = {}
	for i = 1, table.getn(QM.presets) do table.insert(names, QM.presets[i].name) end
	return names
end

local function presetByName(name)
	for i = 1, table.getn(QM.presets) do
		if QM.presets[i].name == name then return QM.presets[i] end
	end
end

-- One tracked row from a preset entry. Name/icon/quality come from the item cache when the
-- client has seen the item and are backfilled by the list editor on first draw when it hasn't,
-- so an unseen item still lands as a working row (the id is what everything keys off). The
-- apply mode comes from the same classifier the add box uses, so a flask reads as Self and a
-- sharpening stone as Wpn without the preset having to say so.
local function presetRow(id, target)
	local name, _, quality, _, itype, isub, _, _, icon = GetItemInfo("item:" .. id)
	local rec = { id = id, name = name, icon = icon, quality = quality,
		target = target or 1, low = 0, state = "enabled", apply = "none" }
	local validate = QM.itemValidators and QM.itemValidators["consumables"]
	if validate then
		local ok, _, meta = validate(id, name, itype, isub)
		if ok and meta then
			for k, v in pairs(meta) do rec[k] = v end
		end
	end
	return rec
end

-- Build a new profile from the named preset and switch to it. Never touches an existing
-- profile: the name is uniquified, so applying the same preset twice gives you a second copy
-- rather than overwriting the one you have already tuned. -> ok, err
function QM.applyPreset(name)
	local preset = presetByName(name)
	if not preset then return false, "unknown preset" end
	local c = QM.me
	if not c then return false, "no character" end

	local profileName = QM.uniqueProfileName(preset.name)
	local ok, err = QM.createProfile(profileName)   -- also makes it active
	if not ok then return false, err end

	local list = c.profiles[profileName]
	for i = 1, table.getn(preset.items) do
		local entry = preset.items[i]
		table.insert(list, presetRow(entry[1], entry[2]))
	end
	c.consumables = list
	QM.fire("DESIRED_CHANGED")
	QM.print("created profile '" .. profileName .. "' -- " .. table.getn(list) .. " item(s)")
	return true
end
