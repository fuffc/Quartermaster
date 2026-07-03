-- Quartermaster -- ItemDB
-- A name -> itemID index so the config can resolve "Greater Healing Potion" the way
-- aux does. Two modes:
--
--   * COMPAT (aux present): we don't build or persist anything -- we just READ aux's
--     own index. aux sets a global `aux` table whose `aux.account.item_ids` is a
--     [lowercase name] = itemID map, persisted in aux's SavedVariables. No aux files
--     are modified; we only read that table. (Detected at READY, after aux's
--     VARIABLES_LOADED handler has populated it.)
--
--   * STANDALONE (no aux): we build the index ourselves, the way aux does it
--     (core/cache.lua scan_wdb). On 1.12 the client keeps a persistent item cache
--     (WDB/<realm>/itemcache.wdb) and GetItemInfo("item:ID") returns from it WITHOUT
--     the server for any item the client has EVER seen -- so we walk the whole ID
--     range, harvest every cached item's name, and persist a name -> id table
--     (QuartermasterDB.itemIndex) so resolution is instant on the next login.
--
-- Either way, an item the client has genuinely never encountered won't resolve by
-- name (it isn't in the WDB) -- the real, and much narrower, 1.12 limitation.

local QM = Quartermaster
QM.ItemDB = {}

local MIN_ID = 1
local MAX_ID = 99999   -- aux uses the same ceiling to cover custom-server item IDs
local BATCH  = 500     -- IDs probed per TICK (~0.5s); GetItemInfo on a cached id is cheap

local useAux = false    -- compat mode: defer to aux's index, build nothing of our own
local index = nil       -- STANDALONE: QuartermasterDB.itemIndex -- [lowercase name] = id
local names = {}         -- STANDALONE: sorted lowercase names, for prefix completion
local namesDirty = true
local scanId = nil       -- STANDALONE scan cursor; nil = idle / finished

-- aux's name->id table, or nil if aux isn't loaded (or isn't the expected shape). We
-- never write to it. `aux` is a global aux installs; an undefined global reads as nil.
local function auxIndex()
	if aux and aux.account and type(aux.account.item_ids) == "table" then
		return aux.account.item_ids
	end
	return nil
end

local function rebuildNames()
	names = {}
	if index then
		for nm in pairs(index) do table.insert(names, nm) end
		table.sort(names)
	end
	namesDirty = false
end

-- name (any case) -> itemID, or nil. Exact full-name match.
function QM.resolveName(text)
	text = string.lower(QM.trim(text))
	if text == "" then return nil end
	if useAux then
		local ai = auxIndex()
		if ai then return ai[text] end
	end
	return index and index[text]
end

-- Indexed (lowercase) names starting with `prefix`, alphabetical, capped at `limit`.
-- Drives the add box's Tab-cycling completion. Returns {} when nothing matches.
function QM.matchNames(prefix, limit)
	prefix = string.lower(QM.trim(prefix))
	local out = {}
	if prefix == "" then return out end
	local plen = string.len(prefix)
	limit = limit or 50
	if useAux then
		-- aux keeps no sorted list we can read, so collect from its name->id map and
		-- sort. Runs on each keystroke, but a few thousand iterations is negligible.
		local ai = auxIndex()
		if not ai then return out end
		for nm in pairs(ai) do
			if string.sub(nm, 1, plen) == prefix then table.insert(out, nm) end
		end
		table.sort(out)
		while table.getn(out) > limit do table.remove(out) end
		return out
	end
	if namesDirty then rebuildNames() end
	for i = 1, table.getn(names) do
		if string.sub(names[i], 1, plen) == prefix then
			table.insert(out, names[i])
			if table.getn(out) >= limit then break end
		end
	end
	return out
end

-- how many names we can resolve (for a status line / debugging)
function QM.ItemDB.count()
	local src = useAux and auxIndex() or index
	if not src then return 0 end
	local n = 0
	for _ in pairs(src) do n = n + 1 end
	return n
end

-- STANDALONE only: harvest one batch of IDs from the client cache. Driven off Core's
-- TICK so it shares the existing OnUpdate rather than spinning up another frame.
local function scanBatch()
	if useAux or not index or not scanId then return end
	local id = scanId
	local processed = 0
	while processed < BATCH and id <= MAX_ID do
		local name = GetItemInfo("item:" .. id)
		if name then
			local key = string.lower(name)
			if not index[key] then index[key] = id; namesDirty = true end
		end
		id = id + 1
		processed = processed + 1
	end
	if id > MAX_ID then
		scanId = nil
		if namesDirty then rebuildNames() end
		QM.fire("ITEMDB_READY")
	else
		scanId = id
	end
end

QM.subscribe("TICK", scanBatch)

QM.subscribe("DB_READY", function()
	QM.db.itemIndex = QM.db.itemIndex or {}
	index = QM.db.itemIndex
	rebuildNames()
end)

-- Decide the mode at READY (PLAYER_LOGIN) -- by then aux's own VARIABLES_LOADED
-- handler has run and populated aux.account.item_ids, so detection is reliable.
QM.subscribe("READY", function()
	QM.caps = QM.caps or {}
	if auxIndex() then
		useAux = true
		QM.caps.aux = true
		QM.print("using aux's item index (" .. QM.ItemDB.count() .. " names) -- no own scan")
	else
		QM.caps.aux = false
		scanId = MIN_ID   -- no aux: build & maintain our own index in the background
	end
end)
