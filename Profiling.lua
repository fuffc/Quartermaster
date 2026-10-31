-- Opt-in profiler behind /qm prof: time and allocation per event handler, signal subscriber
-- and HUD repaint, plus the client's churn and collections. Costs nothing while stopped.

local QM = Quartermaster
QM.Profiling = {}
local P = QM.Profiling

-- debugprofilestop resolves within a frame; GetTime only advances once per frame.
local hiRes = type(debugprofilestop) == "function"
local clock = hiRes and debugprofilestop or function() return GetTime() * 1000 end

local active = false
local stats = {}   -- key -> { n, total, max, depth, start, mem, kb, gcs }
local startedAt, runSeconds = nil, 0

-- gcinfo() KB is the whole client's heap, every addon's. siteKB is the part of churnKB
-- allocated while some measured site was open.
local churnKB, siteKB = 0, 0
local lastMem, lastTick = nil, nil
local open, openMem = 0, 0
local gcCount, gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs = 0, 0, 0, 0, 0

-- A collection frees at least half the heap it walks; a table rehashing smaller drops a few KB.
local GC_MIN_DROP_KB = 256

local function stat(key)
	local s = stats[key]
	if not s then
		s = { n = 0, total = 0, max = 0, depth = 0, start = 0, mem = 0, kb = 0, gcs = 0 }
		stats[key] = s
	end
	return s
end

-- A site's KB is the heap's growth across it in gcinfo's whole-KB steps: one small call
-- reads 0 or 1, but summed over many calls the steps crossed add up to the true total.
-- Re-entry accrues once, from the outermost pair.
function QM.profBegin(key)
	if not active then return end
	local s = stat(key)
	local mem = gcinfo()
	if s.depth == 0 then
		s.start = clock()
		s.mem = mem
	end
	if open == 0 then openMem = mem end
	s.depth = s.depth + 1
	open = open + 1
end

function QM.profEnd(key)
	if not active then return end
	local s = stats[key]
	if not s or s.depth == 0 then return end
	local mem = gcinfo()
	s.depth = s.depth - 1
	if s.depth == 0 then
		local elapsed = clock() - s.start
		s.n = s.n + 1
		s.total = s.total + elapsed
		if elapsed > s.max then s.max = elapsed end
		if mem >= s.mem then
			s.kb = s.kb + (mem - s.mem)
		elseif s.mem - mem >= GC_MIN_DROP_KB then
			s.gcs = s.gcs + 1
		end
	end
	open = open - 1
	if open == 0 and mem >= openMem then siteKB = siteKB + (mem - openMem) end
end

-- Where each handler was registered ("Consumables.lua:1652"), to tell apart the several
-- handlers one event or signal has. false: registered here but the stack did not say
-- where. Core's own registrations predate this file and have no entry.
local origin = {}
local gmatch = string.gmatch or string.gfind
local function registrationSite()
	if type(debugstack) ~= "function" then return nil end
	for file, line in gmatch(debugstack() or "", "([%w_]+%.lua):(%d+)") do
		if file ~= "Profiling.lua" then return file .. ":" .. line end
	end
end

local plainOn, plainSubscribe = QM.on, QM.subscribe
function QM.on(event, fn)
	if not origin[fn] then origin[fn] = registrationSite() or false end
	plainOn(event, fn)
end
function QM.subscribe(signal, fn)
	if not origin[fn] then origin[fn] = registrationSite() or false end
	plainSubscribe(signal, fn)
end

-- Report keys, built once per handler so a dispatch allocates nothing.
local keyCache = { event = {}, signal = {} }
local function handlerKey(kind, name, fn, i)
	local byName = keyCache[kind][name]
	if not byName then
		byName = {}
		keyCache[kind][name] = byName
	end
	local key = byName[fn]
	if not key then
		local where = origin[fn]
		if where == nil then where = "Core" elseif where == false then where = "#" .. i end
		key = kind .. " " .. name .. " (" .. where .. ")"
		byName[fn] = key
	end
	return key
end

-- Copies of Core's two dispatch loops with a site around each handler, swapped in at
-- Start. An erroring handler ends the loop exactly as it does in Core's.
local function measuredOnEvent()
	local list = QM._handlers[event]
	if not list then return end
	for i = 1, table.getn(list) do
		local fn = list[i]
		local key = handlerKey("event", event, fn, i)
		QM.profBegin(key)
		fn()
		QM.profEnd(key)
	end
end

local function measuredFire(signal)
	local list = QM._signals[signal]
	if not list then return end
	for i = 1, table.getn(list) do
		local fn = list[i]
		local key = handlerKey("signal", signal, fn, i)
		QM.profBegin(key)
		fn()
		QM.profEnd(key)
	end
end

local plainOnEvent, plainFire, plainScan
local function measuredScan()
	QM.profBegin("inventory scan")
	plainScan()
	QM.profEnd("inventory scan")
end

local function install()
	plainOnEvent = QM.engine:GetScript("OnEvent")
	QM.engine:SetScript("OnEvent", measuredOnEvent)
	plainFire = QM.fire
	QM.fire = measuredFire
	plainScan = QM.scanInventory
	QM.scanInventory = measuredScan
end

local function uninstall()
	if plainOnEvent then QM.engine:SetScript("OnEvent", plainOnEvent); plainOnEvent = nil end
	if plainFire then QM.fire = plainFire; plainFire = nil end
	if plainScan then QM.scanInventory = plainScan; plainScan = nil end
end

-- Once a frame while running. Churn is the heap's upward movement; a heap a collection's
-- worth lower than last frame's means one ran in between, and the clock difference is that
-- whole frame, pause included.
local function sample()
	local now, mem = clock(), gcinfo()
	local frameMs = lastTick and now - lastTick or 0
	lastTick = now
	if lastMem then
		if mem >= lastMem then churnKB = churnKB + (mem - lastMem) end
		if lastMem - mem >= GC_MIN_DROP_KB then
			gcCount = gcCount + 1
			if frameMs > gcWorstMs then
				gcWorstMs, gcPeakKB, gcAfterKB = frameMs, lastMem, mem
			end
		elseif frameMs > worstFrameMs then
			worstFrameMs = frameMs
		end
	end
	lastMem = mem
	-- Every Begin/End pair runs inside one call, so a site still open between frames is
	-- one a handler error left open; it would otherwise never record again.
	if open ~= 0 then
		open = 0
		for _, s in pairs(stats) do s.depth = 0 end
	end
end
P.sample = sample

local sampler = CreateFrame("Frame")
sampler:Hide()
sampler:SetScript("OnUpdate", sample)

function P.start()
	if active then QM.print("profiler already running"); return end
	active = true
	startedAt = GetTime()
	lastMem, lastTick, open = nil, nil, 0
	for _, s in pairs(stats) do s.depth = 0 end
	install()
	sampler:Show()
	QM.print("profiler started (clock: " .. (hiRes and "debugprofilestop" or "GetTime, frame resolution") .. ")")
end

function P.stop()
	if not active then QM.print("profiler not running"); return end
	active = false
	uninstall()
	sampler:Hide()
	runSeconds = runSeconds + (GetTime() - startedAt)
	startedAt = nil
	QM.print("profiler stopped; /qm prof report to see results")
end

function P.reset()
	stats = {}
	churnKB, siteKB, lastMem, lastTick, open = 0, 0, nil, nil, 0
	gcCount, gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs = 0, 0, 0, 0, 0
	runSeconds = 0
	if active then startedAt = GetTime() end
	QM.print("profiler counters reset")
end

function P.isActive() return active end

function P.totals()
	return churnKB, siteKB, gcCount, gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs
end

function P.siteKB(key)
	local s = stats[key]
	return s and s.kb, s and s.gcs
end

-- `args` is "[n] [kb]": how many rows, and whether to rank them by allocation.
function P.report(args)
	args = tostring(args or "")
	local _, _, n = string.find(args, "(%d+)")
	local limit = tonumber(n) or 15
	local byKB = string.find(args, "kb", 1, true) ~= nil
	local elapsed = runSeconds
	if active and startedAt then elapsed = elapsed + (GetTime() - startedAt) end
	if elapsed <= 0 then
		QM.print("nothing recorded; /qm prof start, play a while, then /qm prof report")
		return
	end
	local minutes = elapsed / 60

	local rows = {}
	for key, s in pairs(stats) do
		if s.n > 0 then table.insert(rows, { key = key, s = s }) end
	end
	if byKB then
		table.sort(rows, function(a, b) return a.s.kb > b.s.kb end)
	else
		table.sort(rows, function(a, b) return a.s.total > b.s.total end)
	end

	QM.print(string.format("prof: %s%.0fs, clock %s", active and "running, " or "", elapsed,
		hiRes and "debugprofilestop" or "GetTime (frame resolution)"))
	QM.print(string.format("prof: client churn %.0f KB (%.0f KB/min), of which inside Quartermaster %.0f KB (%.0f%%)",
		churnKB, churnKB / minutes, siteKB, churnKB > 0 and 100 * siteKB / churnKB or 0))
	local heapKB, thresholdKB = gcinfo()
	local nextGC = ""
	if thresholdKB and churnKB > 0 then
		nextGC = string.format(", next collection in ~%.1f min at this churn",
			(thresholdKB - heapKB) / (churnKB / minutes))
	end
	QM.print(string.format("prof: heap %.0f KB, collects at %s KB%s",
		heapKB, thresholdKB and string.format("%.0f", thresholdKB) or "?", nextGC))
	if gcCount > 0 then
		QM.print(string.format("prof: %d collection%s: worst frame with one %.0f ms (heap %.0f KB before, %.0f KB live after); worst without %.0f ms",
			gcCount, gcCount == 1 and "" or "s", gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs))
	else
		QM.print(string.format("prof: no collection seen; worst frame %.0f ms", worstFrameMs))
	end
	QM.print("prof: keys nest -- a handler's time and KB include the signals it fired")
	QM.print("prof:   total ms |  ms/min |  calls |  max ms |     KB | site")
	local shown = table.getn(rows)
	if shown > limit then shown = limit end
	for i = 1, shown do
		local s = rows[i].s
		QM.print(string.format("prof: %10.1f | %7.1f | %6d | %7.2f | %6d | %s%s",
			s.total, s.total / minutes, s.n, s.max, s.kb, rows[i].key,
			s.gcs > 0 and (" (collection inside x" .. s.gcs .. ")") or ""))
	end
	if table.getn(rows) > shown then
		QM.print("prof: ... " .. (table.getn(rows) - shown) .. " more; /qm prof report "
			.. table.getn(rows) .. (byKB and " kb" or ""))
	end
end

function P.command(rest)
	local _, _, sub, arg = string.find(rest or "", "^(%S*)%s*(.-)$")
	sub = sub or ""
	if sub == "start" or sub == "on" then
		P.start()
	elseif sub == "stop" or sub == "off" then
		P.stop()
	elseif sub == "reset" then
		P.reset()
	elseif sub == "report" or sub == "" then
		P.report(arg)
	else
		QM.print("usage: /qm prof start | stop | report [n] [kb] | reset")
	end
end
