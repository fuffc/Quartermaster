-- Profiles.lua -- named per-character profiles of the Tracker list: the storage
-- ops (create/rename/delete/switch) and the text export/import codec.

local QM = Quartermaster

-- ---------------------------------------------------------------------------
-- Profile operations
-- ---------------------------------------------------------------------------
-- All operate on QM.me. Invariant: QM.me.consumables is always the SAME table as
-- profiles[activeProfile] (re-aliased here on switch, in migrateChar on load), so
-- every existing list setter/reader works on the active profile untouched. Each
-- mutating op ends with the alias valid and one DESIRED_CHANGED fire.

function QM.profileNames()
	local names = {}
	if QM.me and QM.me.profiles then
		for n in pairs(QM.me.profiles) do table.insert(names, n) end
	end
	table.sort(names)
	return names
end

function QM.activeProfile()
	return QM.me and QM.me.activeProfile or "Default"
end

function QM.setActiveProfile(name)
	local c = QM.me
	if not c or not c.profiles or not c.profiles[name] then return false end
	c.activeProfile = name
	c.consumables = c.profiles[name]
	QM.fire("DESIRED_CHANGED")
	return true
end

-- Trimmed `base` made collision-free by appending " (2)", " (3)", ...
function QM.uniqueProfileName(base)
	base = QM.trim(base or "")
	if base == "" then base = "Profile" end
	local profiles = (QM.me and QM.me.profiles) or {}
	if not profiles[base] then return base end
	local i = 2
	while profiles[base .. " (" .. i .. ")"] do i = i + 1 end
	return base .. " (" .. i .. ")"
end

-- Rows are flat, so a per-row shallow copy is a full deep copy of a list.
local function copyList(src)
	local dst = {}
	for i = 1, table.getn(src) do
		local row = {}
		for k, v in pairs(src[i]) do row[k] = v end
		table.insert(dst, row)
	end
	return dst
end

-- Create (empty, or a copy of profile `copyFrom`) and activate. -> ok, err
function QM.createProfile(name, copyFrom)
	local c = QM.me
	if not c then return false, "no character" end
	name = QM.trim(name or "")
	if name == "" then return false, "enter a profile name" end
	if c.profiles[name] then return false, "a profile with that name exists" end
	local src = copyFrom and c.profiles[copyFrom]
	c.profiles[name] = src and copyList(src) or {}
	QM.setActiveProfile(name)
	return true
end

function QM.renameProfile(old, new)
	local c = QM.me
	if not c or not c.profiles[old] then return false, "no such profile" end
	new = QM.trim(new or "")
	if new == "" then return false, "enter a profile name" end
	if new == old then return true end
	if c.profiles[new] then return false, "a profile with that name exists" end
	c.profiles[new] = c.profiles[old]
	c.profiles[old] = nil
	if c.activeProfile == old then c.activeProfile = new end
	QM.fire("DESIRED_CHANGED")
	return true
end

-- Delete. Deleting the active profile activates the first remaining one; deleting
-- the last one leaves a fresh empty "Default" active.
function QM.deleteProfile(name)
	local c = QM.me
	if not c or not c.profiles[name] then return false, "no such profile" end
	c.profiles[name] = nil
	if c.activeProfile == name then
		local names = QM.profileNames()
		if table.getn(names) == 0 then
			c.profiles["Default"] = {}
			names = { "Default" }
		end
		c.activeProfile = names[1]
		c.consumables = c.profiles[names[1]]
	end
	QM.fire("DESIRED_CHANGED")
	return true
end

-- ---------------------------------------------------------------------------
-- Export / import codec
-- ---------------------------------------------------------------------------
-- Wire format: "QMP1:" .. base64(payload). Payload lines: profile name, row count,
-- then one row per line -- item "I<tab>id<tab>target<tab>low<tab>state<tab>apply<tab>name",
-- divider "D<tab>state<tab>label". Free text is always the LAST field on its line, so
-- the only escaping needed is squashing tabs/newlines out of it at serialize time.
-- Parsed by hand (never loadstring: pasted strings are untrusted input).

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64REV = {}
for i = 1, 64 do B64REV[string.sub(B64, i, i)] = i - 1 end

local function b64char(v) return string.sub(B64, v + 1, v + 1) end

local function b64encode(s)
	local out, lineLen = {}, 0
	local n = string.len(s)
	local i = 1
	while i <= n do
		local a = string.byte(s, i)
		local b = string.byte(s, i + 1)
		local c = string.byte(s, i + 2)
		local v = a * 65536 + (b or 0) * 256 + (c or 0)
		local chunk = b64char(math.floor(v / 262144)) .. b64char(math.mod(math.floor(v / 4096), 64))
		if b then chunk = chunk .. b64char(math.mod(math.floor(v / 64), 64)) else chunk = chunk .. "=" end
		if c then chunk = chunk .. b64char(math.mod(v, 64)) else chunk = chunk .. "=" end
		table.insert(out, chunk)
		-- wrap so the export edit box shows tidy lines (decode strips whitespace)
		lineLen = lineLen + 4
		if lineLen >= 76 then table.insert(out, "\n"); lineLen = 0 end
		i = i + 3
	end
	return table.concat(out)
end

-- nil on any malformed input (unknown char, bad length, padding mid-stream).
local function b64decode(s)
	local out = {}
	local n = string.len(s)
	local i = 1
	while i <= n do
		local q1, q2 = string.sub(s, i, i), string.sub(s, i + 1, i + 1)
		local q3, q4 = string.sub(s, i + 2, i + 2), string.sub(s, i + 3, i + 3)
		local c1, c2 = B64REV[q1], B64REV[q2]
		if not c1 or not c2 or q3 == "" or q4 == "" then return nil end
		local c3 = B64REV[q3]
		local c4 = B64REV[q4]
		if not c3 and q3 ~= "=" then return nil end
		if not c4 and q4 ~= "=" then return nil end
		if not c3 and c4 then return nil end
		if (not c3 or not c4) and i + 4 <= n then return nil end
		local v = c1 * 262144 + c2 * 4096 + (c3 or 0) * 64 + (c4 or 0)
		table.insert(out, string.char(math.floor(v / 65536)))
		if c3 then table.insert(out, string.char(math.mod(math.floor(v / 256), 256))) end
		if c4 then table.insert(out, string.char(math.mod(v, 256))) end
		i = i + 4
	end
	return table.concat(out)
end

local function clean(s)
	local out = string.gsub(s or "", "[\r\n\t]", " ")
	return out
end

-- The named profile -> a copy-pasteable string (nil if it doesn't exist). Each "I" row is
-- 8 tab-separated fields (id, target, low, state, apply, restock, name); importProfile also
-- accepts the older 7-field layout (no restock column) from before restock was split out of
-- apply.
function QM.exportProfile(name)
	local c = QM.me
	local list = c and c.profiles and c.profiles[name]
	if not list then return nil end
	local lines = { clean(name), tostring(table.getn(list)) }
	for i = 1, table.getn(list) do
		local e = list[i]
		if e.divider then
			table.insert(lines, "D\t" .. QM.itemState(e) .. "\t" .. clean(e.label))
		else
			table.insert(lines, "I\t" .. (e.id or 0)
				.. "\t" .. (e.target or 10) .. "\t" .. (e.low or 5)
				.. "\t" .. QM.itemState(e)
				.. "\t" .. (e.apply or "none")
				.. "\t" .. (e.restock and "1" or "0")
				.. "\t" .. clean(e.name))
		end
	end
	return "QMP1:" .. b64encode(table.concat(lines, "\n"))
end

-- Split `line` into n tab-separated fields; the LAST one is the untouched remainder
-- (the free-text tail). nil when the line has fewer than n fields.
local function splitFields(line, n)
	local out = {}
	local pos = 1
	for i = 1, n - 1 do
		local s = string.find(line, "\t", pos, 1)
		if not s then return nil end
		table.insert(out, string.sub(line, pos, s - 1))
		pos = s + 1
	end
	table.insert(out, string.sub(line, pos))
	return out
end

local IMPORT_STATE = { enabled = true, hidden = true, off = true }
local IMPORT_APPLY = { none = true, self = true, weapon = true, mh = true, oh = true, target = true }

-- Parse a pasted export string into a new profile and activate it.
-- -> true, profileName  |  false, error message
function QM.importProfile(text)
	local c = QM.me
	if not c then return false, "no character" end
	-- base64 has no whitespace, so anything the paste picked up can be squashed first
	text = string.gsub(text or "", "%s", "")
	if string.sub(text, 1, 5) ~= "QMP1:" then
		return false, "not a Quartermaster profile string"
	end
	local payload = b64decode(string.sub(text, 6))
	if not payload then return false, "corrupted profile string" end

	local lines = {}
	for line in string.gfind(payload .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end
	local name = lines[1]
	local count = tonumber(lines[2] or "")
	if not name or not count then return false, "corrupted profile string" end

	local list = {}
	local seen = 0
	for i = 3, table.getn(lines) do
		local line = lines[i]
		if line ~= "" then
			seen = seen + 1
			local kind = string.sub(line, 1, 1)
			if kind == "I" then
				-- 8 fields (current) with a restock column, or 7 (pre-restock-split, where
				-- apply=="restock" meant "buy only" -- migrated to apply="none", restock=true).
				local f8 = splitFields(line, 8)
				local f = f8 or splitFields(line, 7)
				local id = f and tonumber(f[2])
				if not id then return false, "corrupted profile string" end
				local e = { id = id, target = tonumber(f[3]) or 10, low = tonumber(f[4]) or 5 }
				e.state = IMPORT_STATE[f[5]] and f[5] or "enabled"
				if f[6] == "restock" then
					e.apply, e.restock = "none", true
				elseif IMPORT_APPLY[f[6]] then
					e.apply = f[6]
				else
					e.apply = "none"
				end
				if f8 then
					if f[7] == "1" then e.restock = true end
					if f[8] ~= "" then e.name = f[8] end
				elseif f[7] ~= "" then
					e.name = f[7]
				end
				-- icon/quality omitted: the editor and HUD re-derive them from
				-- GetItemInfo on every paint
				table.insert(list, e)
			elseif kind == "D" then
				local f = splitFields(line, 3)
				if not f then return false, "corrupted profile string" end
				table.insert(list, { divider = true, state = IMPORT_STATE[f[2]] and f[2] or "enabled", label = f[3] })
			end
			-- other row kinds: skipped, still counted (a newer version's rows)
		end
	end
	if seen ~= count then return false, "corrupted profile string" end

	local finalName = QM.uniqueProfileName(name)
	c.profiles[finalName] = list
	QM.setActiveProfile(finalName)
	return true, finalName
end
