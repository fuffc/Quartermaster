-- Quartermaster -- Transfer
-- Moves stock both INTO and OUT OF the current character's carried bags:
--   * from/to the BANK while the bank is open -- top up shortfalls toward `target`,
--     or bank excess (/qm banksync), filling existing partial stacks first.
--   * via MAIL -- one stack per mail (1.12 allows a single attachment), sequenced
--     on MAIL_SEND_SUCCESS. Either supplying another character's shortfall, or
--     dumping the transferable list's excess to a configured recipient.
--
-- Mail sequencer idiom from ../QuickStash (AutoMailer): one stack per mail on this
-- 1.12 client, sequenced on MAIL_SEND_SUCCESS.

local QM = Quartermaster
QM.Transfer = {}
local T = QM.Transfer

-- The transferable list never rejects an add (like consumables' classifier), and
-- defaults new rows to Keep=0 (ship everything) with bankable on. It has no `low`
-- (no warn-threshold concept for this list).
QM.itemValidators["transferable"] = function(id, name, itype, isub)
	return true, nil, { target = 0, bankable = true }, { "low" }
end

-- ---------------------------------------------------------------------------
-- Planning: what does the raid character still need?
-- ---------------------------------------------------------------------------
-- For a character's desired list, compute the shortfall per item and where the rest
-- lives (bank / other characters). Returns ordered rows { id, name, short, fromBank,
-- fromAlt, alts }, where `alts` is an ordered { { char, amount }, ... } naming exactly
-- which other characters are holding it (sorted by character name), and `fromAlt` is
-- just its total (kept for callers that don't care about the breakdown).
function T.plan(charKey, kind)
	local key = charKey or QM.charKey()
	local c = QM.db and QM.db.chars[key]
	local list = c and c[kind]
	if not list then return {} end
	local rows = {}
	for i = 1, table.getn(list) do
		local e = list[i]
		if not QM.isDivider(e) and QM.itemActive(e) then
			local bags, bank
			if key == QM.charKey() then
				bags, bank = QM.itemCount(e.id)
			else
				local inv = c.inventory and c.inventory[e.id]
				bags = inv and inv.bags or 0
				bank = inv and inv.bank or 0
			end
			local short = (e.target or 0) - bags
			if short > 0 then
				local fromBank = short
				if fromBank > bank then fromBank = bank end
				local fromAlt, alts = 0, {}
				QM.eachChar(function(otherKey, rec)
					if otherKey ~= key then
						local inv = rec.inventory and rec.inventory[e.id]
						if inv and inv.total and inv.total > 0 then
							fromAlt = fromAlt + inv.total
							table.insert(alts, { char = otherKey, amount = inv.total })
						end
					end
				end)
				table.sort(alts, function(a, b) return a.char < b.char end)
				table.insert(rows, { id = e.id, name = e.name, short = short, fromBank = fromBank, fromAlt = fromAlt, alts = alts })
			end
		end
	end
	return rows
end

-- ---------------------------------------------------------------------------
-- Bag <-> bank stack mover (fill partial stacks before making new ones)
-- ---------------------------------------------------------------------------

local BANK_CONTAINER = -1

local function bagContainers()
	local list = {}
	for bag = 0, 4 do table.insert(list, bag) end
	return list
end

local function bankContainers()
	local list = { BANK_CONTAINER }
	local n  = NUM_BAG_SLOTS or 4
	local nb = NUM_BANKBAGSLOTS or 6
	for bag = n + 1, n + nb do table.insert(list, bag) end
	return list
end

-- First stack of itemID in `containers`, or nil. Returns bag, slot, count.
local function findStack(containers, itemID)
	for i = 1, table.getn(containers) do
		local bag = containers[i]
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local link = GetContainerItemLink(bag, slot)
			if link and QM.itemID(link) == itemID then
				local _, count = GetContainerItemInfo(bag, slot)
				return bag, slot, count or 0
			end
		end
	end
end

-- The first completely empty slot in `containers`, or nil.
local function findEmptySlot(containers)
	for i = 1, table.getn(containers) do
		local bag = containers[i]
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			if not GetContainerItemLink(bag, slot) then return bag, slot end
		end
	end
end

-- A destination slot in `containers` that can take more of itemID: an existing
-- partial stack first (QM.db.options.fillStacksFirst), else the first empty slot.
-- Returns bag, slot, room (nil room = unlimited, i.e. an empty slot).
local function findDest(containers, itemID, maxStack)
	if QM.db.options.fillStacksFirst then
		for i = 1, table.getn(containers) do
			local bag = containers[i]
			local slots = GetContainerNumSlots(bag) or 0
			for slot = 1, slots do
				local link = GetContainerItemLink(bag, slot)
				if link and QM.itemID(link) == itemID then
					local _, count = GetContainerItemInfo(bag, slot)
					count = count or 0
					if maxStack and count > 0 and count < maxStack then
						return bag, slot, maxStack - count
					end
				end
			end
		end
	end
	local bag, slot = findEmptySlot(containers)
	if bag then return bag, slot, maxStack end
end

-- Move up to `amount` of itemID from `fromContainers` to `toContainers`, filling
-- partial destination stacks first. Returns the amount actually moved. Container
-- moves are a single synchronous client action (PickupContainerItem pair), same as
-- any bag-sorting addon -- no OnUpdate throttling needed (unlike the mail sequencer,
-- which is throttled by the mail SERVER's round-trip, a different concern).
local function moveStacks(itemID, amount, fromContainers, toContainers)
	if not itemID or amount <= 0 then return 0 end
	local _, _, _, _, _, _, maxStack = GetItemInfo("item:" .. itemID)
	maxStack = maxStack or 1
	local moved = 0
	while moved < amount do
		local srcBag, srcSlot, srcCount = findStack(fromContainers, itemID)
		if not srcBag then break end
		local dstBag, dstSlot, room = findDest(toContainers, itemID, maxStack)
		if not dstBag then break end
		local take = amount - moved
		if take > srcCount then take = srcCount end
		if room and take > room then take = room end
		if take <= 0 then break end
		ClearCursor()
		if take < srcCount then
			SplitContainerItem(srcBag, srcSlot, take)
		else
			PickupContainerItem(srcBag, srcSlot)
		end
		PickupContainerItem(dstBag, dstSlot)
		ClearCursor()
		moved = moved + take
	end
	return moved
end

-- ---------------------------------------------------------------------------
-- Bank -> bags (fill partial stacks first)
-- ---------------------------------------------------------------------------
-- Move `amount` of itemID from the open bank into bags, topping up partial bag
-- stacks before making new ones (QM.db.options.fillStacksFirst).
function T.fromBank(itemID, amount)
	if not QM.bankOpen then QM.print("open your bank first"); return 0 end
	return moveStacks(itemID, amount, bankContainers(), bagContainers())
end

-- ---------------------------------------------------------------------------
-- Bags -> bank (fill partial stacks first)
-- ---------------------------------------------------------------------------
-- Move `amount` of itemID from bags into the open bank, topping up partial bank
-- stacks before making new ones.
function T.toBank(itemID, amount)
	if not QM.bankOpen then QM.print("open your bank first"); return 0 end
	return moveStacks(itemID, amount, bagContainers(), bankContainers())
end

-- The floor to leave behind for a transferable-list entry. If the same item is ALSO in
-- the active tracked list (and not turned off), that list's target always wins -- the
-- transferable list's own Keep only applies to items the tracked list doesn't already
-- cover, so the two lists can't fight over how much of a dual-listed item to ship (e.g.
-- a reagent you keep 20 of on the tracker but would otherwise list as Keep=0 here).
local function transferableFloor(c, e)
	local list = c.consumables or {}
	for i = 1, table.getn(list) do
		local te = list[i]
		if not QM.isDivider(te) and te.id == e.id and QM.itemActive(te) then
			return te.target or 0
		end
	end
	return e.target or 0
end

-- True when itemID is also an active row in the transferable list. QM.itemCount reads a
-- CACHED inventory snapshot (only refreshed by QM.scanInventory, which bankSync/
-- mailDumpExcess only call once at the very end), so a tracked-overage pass that ran
-- BOTH for a dual-listed item's own target AND again via transferableFloor would compute
-- the second pass off the same stale (pre-first-pass) bag count and over-process it --
-- this is what keeps the two passes from ever touching the same item: a dual-listed item
-- is handled exactly once, by the transferable-list pass (which already resolves the
-- right floor via transferableFloor), never by the plain tracked-overage pass.
local function inTransferableList(c, id)
	local list = c.transferable or {}
	for i = 1, table.getn(list) do
		local te = list[i]
		if not QM.isDivider(te) and te.id == id and QM.itemActive(te) then return true end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- /qm banksync -- top up tracked-list shortfalls from the bank, then (optionally)
-- bank tracked-list overage and everything bankable in the transferable list.
-- ---------------------------------------------------------------------------
function T.bankSync()
	if not QM.bankOpen then QM.print("open your bank first"); return end
	local c = QM.me
	if not c then return end

	local topped = 0
	local plan = T.plan(QM.charKey(), "consumables")
	for i = 1, table.getn(plan) do
		local row = plan[i]
		if row.fromBank > 0 then topped = topped + T.fromBank(row.id, row.fromBank) end
	end

	local banked = 0
	if QM.db.options.transfer.dumpTrackedOverage then
		local list = c.consumables or {}
		for i = 1, table.getn(list) do
			local e = list[i]
			-- Dual-listed items are handled below instead (transferableFloor already
			-- resolves to this same target for them) -- see inTransferableList's comment
			-- for why processing one here too would over-bank it.
			if not QM.isDivider(e) and QM.itemActive(e) and not inTransferableList(c, e.id) then
				local bags = QM.itemCount(e.id)
				local overage = bags - (e.target or 0)
				if overage > 0 then banked = banked + T.toBank(e.id, overage) end
			end
		end
	end

	local tlist = c.transferable or {}
	for i = 1, table.getn(tlist) do
		local e = tlist[i]
		if not QM.isDivider(e) and QM.itemActive(e) and e.bankable then
			local bags = QM.itemCount(e.id)
			local excess = bags - transferableFloor(c, e)
			if excess > 0 then banked = banked + T.toBank(e.id, excess) end
		end
	end

	QM.scanInventory()
	QM.print("banksync: topped up " .. topped .. ", banked " .. banked)
end

-- ---------------------------------------------------------------------------
-- Status label: what the prep/mail machinery is doing right now, floated above
-- the mailbox (everything here runs only while mail is open). nil text hides it.
-- ---------------------------------------------------------------------------
local Status
local function setStatus(text)
	if not text then
		if Status then Status:Hide() end
		return
	end
	if not Status then
		Status = CreateFrame("Frame", nil, UIParent)
		Status:SetFrameStrata("DIALOG")
		Status:SetHeight(26)
		Status:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 } })
		Status:SetBackdropColor(0, 0, 0, 0.85)
		Status.label = Status:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		Status.label:SetPoint("CENTER", 0, 0)
	end
	Status:ClearAllPoints()
	if QM.mailFrame and QM.mailFrame:IsShown() then
		Status:SetPoint("BOTTOM", QM.mailFrame, "TOP", 0, 4)
	elseif MailFrame then
		Status:SetPoint("BOTTOM", MailFrame, "TOP", 0, 8)
	else
		Status:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	end
	Status.label:SetText(text)
	Status:SetWidth(Status.label:GetStringWidth() + 26)
	Status:Show()
end

local cancelPrep   -- defined with the Prep frame below; the Mailer's MAIL_CLOSED needs it first

-- ---------------------------------------------------------------------------
-- Mail sequencer (one item per mail)
-- ---------------------------------------------------------------------------

local Mailer = CreateFrame("Frame")
Mailer:RegisterEvent("MAIL_CLOSED")
Mailer:RegisterEvent("MAIL_SEND_SUCCESS")
Mailer:RegisterEvent("UI_ERROR_MESSAGE")

Mailer.queue     = {}     -- ordered list of { bag, slot }
Mailer.index     = 0
Mailer.recipient = nil
Mailer.sending   = false
Mailer.pending   = false  -- counting down to the next send
Mailer.elapsed   = 0
Mailer.waiting   = false  -- attached + SendMail called, awaiting confirmation
Mailer.waitElapsed = 0
Mailer.sentCount = 0
Mailer.onDone    = nil    -- optional callback, fired once this batch finishes/aborts --
                          -- lets a caller chain several recipients through this one
                          -- shared Mailer (see T.mailDumpExcess).
Mailer.expected      = 0   -- attachments queued this batch (progress display)
Mailer.attachRetries = 0   -- consecutive failed attach attempts for the current queue entry
Mailer.sendRetries   = 0   -- SendMail calls for the current entry that got no server reply

local MAIL_SEND_DELAY     = 0.3
local MAIL_SEND_TIMEOUT   = 5 -- per SendMail: no MAIL_SEND_SUCCESS *or* error in this long -> retry
local MAIL_ATTACH_RETRIES = 3 -- attach attempts per queue entry before skipping that stack
local MAIL_SEND_RETRIES   = 2 -- unanswered SendMail retries per entry before aborting the batch

-- TurtleMail globally REPLACES ClickSendMailItemButton with an async, cursor-polling
-- version (installed at PLAYER_LOGIN) that never attaches anything within a single
-- synchronous call -- the native attach sequence silently attaches nothing through it
-- (no error, GetSendMailItem just stays nil). The ORIGINAL is kept in TurtleMail.orig
-- and works fine alongside its other hooks, so the one sequencer below drives every
-- setup through this helper. (An earlier compat mode handed the whole queue to
-- TurtleMail.sendmail_send instead; on this server a SendMail sometimes gets no reply
-- at all -- no MAIL_SEND_SUCCESS, no UI error -- and that path had no per-item
-- confirmation to retry from, so the whole batch just died on a watchdog. Driving
-- items one at a time is what makes the retry below possible.)
local function clickSendSlot()
	if QM.caps and QM.caps.turtleMail and TurtleMail and TurtleMail.orig and TurtleMail.orig.ClickSendMailItemButton then
		TurtleMail.orig.ClickSendMailItemButton()
	else
		ClickSendMailItemButton()
	end
end

local function finishMailing()
	Mailer:SetScript("OnUpdate", nil)
	Mailer.sending = false
	Mailer.pending = false
	Mailer.waiting = false
	-- Retrieve whatever an aborted batch left in the native send slot (ClearCursor
	-- returns the picked-up stack to the bag slot it came from).
	if GetSendMailItem() then
		ClearCursor()
		clickSendSlot()
		ClearCursor()
	end
	-- Never leave TurtleMail state behind that marks bag slots "attached" -- its
	-- GetContainerItemInfo hook renders those locked and its SplitContainerItem hook
	-- silently no-ops on them, corrupting the next batch's prep.
	if QM.caps and QM.caps.turtleMail and TurtleMail then
		TurtleMail.sendmail_state = nil
	end
	Mailer.queue   = {}
	Mailer.index   = 0
	ClearCursor()
	setStatus(nil)
	if Mailer.sentCount > 0 then
		QM.print("mailed " .. Mailer.sentCount .. " stack(s) to " .. (Mailer.recipient or "?"))
	end
	local done = Mailer.onDone
	Mailer.onDone = nil
	if done then done() end
end

local function sendCurrentMailItem()
	Mailer.pending = false
	-- Empty the send slot first: a retry's attachment from the previous attempt goes
	-- back to the bag slot it came from, so the scan below finds it again.
	ClearCursor()
	clickSendSlot()
	ClearCursor()
	-- skip queue entries whose slot no longer holds an item
	while Mailer.index <= table.getn(Mailer.queue) do
		local entry = Mailer.queue[Mailer.index]
		if GetContainerItemLink(entry.bag, entry.slot) then break end
		Mailer.index = Mailer.index + 1
		Mailer.attachRetries, Mailer.sendRetries = 0, 0
	end
	if Mailer.index > table.getn(Mailer.queue) then finishMailing(); return end

	local entry = Mailer.queue[Mailer.index]
	ClearCursor()
	PickupContainerItem(entry.bag, entry.slot)
	clickSendSlot()  -- attach the picked-up stack

	local itemName, _, stackCount = GetSendMailItem()
	if not itemName then
		-- The slot holds an item but won't attach (usually a lock that hasn't settled
		-- yet); retry a few beats before giving up on this stack.
		ClearCursor()
		Mailer.attachRetries = Mailer.attachRetries + 1
		if Mailer.attachRetries > MAIL_ATTACH_RETRIES then
			QM.print("skipping bag " .. entry.bag .. " slot " .. entry.slot .. " -- attach kept failing")
			Mailer.index = Mailer.index + 1
			Mailer.attachRetries = 0
		end
		Mailer.pending = true
		Mailer.elapsed = 0
		return
	end
	Mailer.attachRetries = 0
	-- Name each mail after its item, the way TurtleMail does.
	local subject = itemName
	if stackCount and stackCount > 1 then subject = subject .. " (" .. stackCount .. ")" end
	SendMail(Mailer.recipient, subject, "")
	Mailer.waiting = true
	Mailer.waitElapsed = 0
end

local function onMailUpdate()
	local elapsed = arg1
	if Mailer.pending then
		Mailer.elapsed = Mailer.elapsed + elapsed
		if Mailer.elapsed >= MAIL_SEND_DELAY then sendCurrentMailItem() end
	elseif Mailer.waiting then
		Mailer.waitElapsed = Mailer.waitElapsed + elapsed
		if Mailer.waitElapsed >= MAIL_SEND_TIMEOUT then
			-- SendMail got neither MAIL_SEND_SUCCESS nor an error: the observed OctoWoW
			-- failure mode (the request just dies in transit). Report what the send slot
			-- looks like and route back through sendCurrentMailItem -- if the stack is
			-- still around it gets re-attached and re-sent, if it genuinely left (a
			-- success whose event we missed) its now-empty bag slot gets skipped.
			Mailer.sendRetries = Mailer.sendRetries + 1
			if Mailer.sendRetries > MAIL_SEND_RETRIES then
				QM.print("mail send timed out " .. (MAIL_SEND_RETRIES + 1) .. " times -- stopping")
				finishMailing()
				return
			end
			local itemName = GetSendMailItem()
			QM.print("no server reply to SendMail (send slot: " .. (itemName or "empty") .. ") -- retrying")
			Mailer.waiting = false
			Mailer.pending = true
			Mailer.elapsed = 0
		end
	end
end

-- Public entry: mail a prepared queue of { bag, slot } stacks to `recipient`. Requires
-- the mail window open. `onDone`, if given, fires once this batch finishes (or aborts) --
-- lets a caller chain several recipients through this one shared Mailer. Works with or
-- without TurtleMail: the attach goes through clickSendSlot (see its comment), and any
-- TurtleMail state that would make its bag hooks interfere is dropped up front.
function T.mailItems(recipient, queue, onDone)
	if Mailer.sending then
		QM.print("already mailing -- wait for the current batch to finish")
		return
	end
	if QM.caps and QM.caps.turtleMail and TurtleMail and TurtleMail.sendmail_sending then
		QM.print("TurtleMail is mid-send -- wait for it to finish")
		return
	end
	if not recipient or recipient == "" then
		QM.print("no mail recipient set")
		if onDone then onDone() end
		return
	end
	if not queue or table.getn(queue) < 1 then
		QM.print("nothing to mail")
		if onDone then onDone() end
		return
	end
	if MailFrameTab_OnClick then MailFrameTab_OnClick(2) end  -- switch to Send Mail tab

	-- Neutralize TurtleMail before driving the native flow: drop any leftover
	-- sendmail_state (its GetContainerItemInfo/SplitContainerItem hooks treat those
	-- slots as attached) and detach anything staged in its attachment UI.
	if QM.caps and QM.caps.turtleMail and TurtleMail then
		TurtleMail.sendmail_state = nil
		if TurtleMail.sendmail_clear then TurtleMail.sendmail_clear() end
	end

	Mailer.recipient = recipient
	Mailer.sentCount = 0
	Mailer.sending   = true
	Mailer.onDone    = onDone
	Mailer.expected  = table.getn(queue)
	Mailer.attachRetries, Mailer.sendRetries = 0, 0
	setStatus("Mailing to " .. recipient .. " (0/" .. Mailer.expected .. ")")

	Mailer.queue   = queue
	Mailer.index   = 1
	Mailer.waiting = false
	Mailer.pending = true
	Mailer.elapsed = 0
	Mailer:SetScript("OnUpdate", onMailUpdate)
end

Mailer:SetScript("OnEvent", function()
	if event == "MAIL_SEND_SUCCESS" then
		if not Mailer.sending then return end
		Mailer.sentCount = Mailer.sentCount + 1
		Mailer.attachRetries, Mailer.sendRetries = 0, 0
		setStatus("Mailing to " .. (Mailer.recipient or "?") .. " (" .. Mailer.sentCount .. "/" .. Mailer.expected .. ")")
		Mailer.waiting = false
		Mailer.index = Mailer.index + 1
		Mailer.pending = true   -- defer the next send a beat so item locks settle
		Mailer.elapsed = 0
	elseif event == "MAIL_CLOSED" then
		if cancelPrep then cancelPrep() end
		if Mailer.sending then finishMailing() end
	elseif event == "UI_ERROR_MESSAGE" then
		if Mailer.sending and (arg1 == ERR_MAIL_TO_SELF
			or arg1 == ERR_PLAYER_WRONG_FACTION
			or arg1 == ERR_MAIL_TARGET_NOT_FOUND
			or arg1 == ERR_MAIL_REACHED_CAP
			or arg1 == ERR_NOT_ENOUGH_MONEY) then
			QM.print("mail failed: " .. (arg1 or ""))
			finishMailing()
		elseif Mailer.sending and arg1 then
			-- A server-side rejection can carry error text we don't match above; surface
			-- anything that fires mid-batch so it names itself (don't abort -- it may be
			-- unrelated to mail entirely).
			QM.print("during send: " .. arg1)
		end
	end
end)

-- ---------------------------------------------------------------------------
-- /qm mailtest <recipient> [delaySeconds] -- one bare SendMail with NO attachment,
-- fully instrumented, to isolate the SendMail call itself from the bag/attach
-- machinery. Reports every signal for 10s: MAIL_SEND_SUCCESS (with latency), any
-- UI_ERROR_MESSAGE, and the postage delta -- money only leaves the character when
-- the server actually processed the send. The optional delay defers the dispatch
-- (hands off mouse/keyboard!) to test whether the server only honors SendMail
-- close to real user input -- the typed slash command itself is a hardware event,
-- a delayed dispatch provably isn't.
-- ---------------------------------------------------------------------------
local MailTest = CreateFrame("Frame")
MailTest:RegisterEvent("MAIL_SEND_SUCCESS")
MailTest:RegisterEvent("UI_ERROR_MESSAGE")
MailTest.active = false

local function mailTestStop()
	MailTest.active = false
	MailTest:SetScript("OnUpdate", nil)
end

local function mailTestDispatch()
	MailTest.startedAt = GetTime()
	MailTest.startMoney = GetMoney()
	MailTest.elapsed = 0
	-- Keep this probe MINIMAL -- a bare SendMail call and nothing else -- so it
	-- isolates the send itself. Only touch the send slot if something is attached.
	if GetSendMailItem() then
		ClearCursor()
		clickSendSlot()
		ClearCursor()
	end
	QM.print("mailtest: SendMail('" .. MailTest.recipient .. "', no attachment) dispatched -- watching 10s")
	SendMail(MailTest.recipient, "QM mail test", "test")
end

MailTest:SetScript("OnEvent", function()
	if not MailTest.active or not MailTest.startedAt then return end
	if event == "MAIL_SEND_SUCCESS" then
		QM.print("mailtest: MAIL_SEND_SUCCESS after "
			.. string.format("%.1f", GetTime() - MailTest.startedAt) .. "s, money spent: "
			.. (MailTest.startMoney - GetMoney()) .. "c")
		mailTestStop()
	elseif event == "UI_ERROR_MESSAGE" then
		QM.print("mailtest: UI error: " .. (arg1 or "?"))
	end
end)

function T.mailTest(recipient, delay)
	if not recipient or recipient == "" then
		QM.print("usage: /qm mailtest <recipient> [delaySeconds] (mailbox must be open)")
		return
	end
	if Mailer.sending then QM.print("mailer is busy"); return end
	delay = tonumber(delay) or 0
	MailTest.recipient = recipient
	MailTest.active = true
	MailTest.startedAt = nil
	MailTest.waitLeft = delay
	MailTest.elapsed = 0
	if delay > 0 then
		QM.print("mailtest: dispatching to " .. recipient .. " in " .. delay
			.. "s -- do NOT touch mouse/keyboard until it fires")
	end
	MailTest:SetScript("OnUpdate", function()
		if MailTest.waitLeft > 0 then
			MailTest.waitLeft = MailTest.waitLeft - arg1
			if MailTest.waitLeft <= 0 then mailTestDispatch() end
			return
		end
		MailTest.elapsed = MailTest.elapsed + arg1
		if MailTest.elapsed >= 10 then
			QM.print("mailtest: NO reply after 10s (no success, no error), money spent: "
				.. (MailTest.startMoney - GetMoney()) .. "c")
			mailTestStop()
		end
	end)
	if delay <= 0 then mailTestDispatch() end
end

-- ---------------------------------------------------------------------------
-- Mail pickup: clear this character's own in-flight placeholder once the real
-- item actually lands (QM.clearInFlight) -- the counterpart to T.supplySend's
-- QM.addInFlight on the sending side. Reads the itemID by link the same way the
-- rest of this file does (QM.itemID), since GetInboxItemLink's extra returns
-- aren't reliable on this client. A no-op for any item that isn't in flight.
-- GetInboxItemLink itself is a ClassicAPI client-patch addition, not native to this
-- client (QM.caps.inboxItemLink) -- without it, fall back to GetInboxItem's own name
-- return resolved through ItemDB (exact match; the name IS the item's real name here).
-- ---------------------------------------------------------------------------
local origTakeInboxItem = TakeInboxItem
function TakeInboxItem(index, attachIndex)
	local charKey = QM.me and QM.charKey()
	local itemID, count
	if charKey then
		local name, _, c = GetInboxItem(index, attachIndex)
		if QM.caps.inboxItemLink then
			local link = GetInboxItemLink(index, attachIndex)
			itemID = link and QM.itemID(link)
		else
			itemID = name and QM.resolveName(name)
		end
		if itemID then count = c or 1 end
	end
	origTakeInboxItem(index, attachIndex)
	if itemID then QM.clearInFlight(charKey, itemID, count) end
end

-- Opening the mailbox resets this character's own in-flight bookkeeping outright
-- rather than trusting it. It's meant to be a short-lived placeholder cleared by
-- TakeInboxItem above the moment the real mail is picked up -- but a corrupted send
-- (T.mailItems/TurtleMail failing after QM.addInFlight already ran, e.g. a broken
-- multi-attachment batch) can otherwise strand an entry forever, permanently masking
-- a real shortfall. Wiping it here can also make us forget mail that's genuinely
-- still in transit, understating QM.inFlightCount and letting a second mule
-- double-queue a resend -- but a redundant mail is far cheaper than a shortfall that
-- silently never gets covered because the cache thinks it's already handled.
QM.on("MAIL_SHOW", function()
	local c = QM.me
	if c then c.inFlight = nil end
end)

-- ---------------------------------------------------------------------------
-- Mail-queue building: turn "item X, send N" into a { bag, slot } queue
-- ---------------------------------------------------------------------------
-- One bag slot (stack) per queue entry -> one mail each (1.12's single-attachment
-- limit). Splits `amount` into the fewest possible stacks (maxStack-sized chunks,
-- remainder last) and, for each chunk, scans ALL of itemID's stacks for an exact
-- size match before planning any moves, so a stack that's already the right size
-- costs zero manipulations. A chunk with no exact match is assembled by topping up
-- the largest unclaimed stack from the next-largest ones, splitting only the
-- contributor that would overshoot. This favors full stacks over whatever's already
-- sitting in bags: e.g. two equal partials that already sum to a full stack plus a
-- remainder get merged into that shape even though sending them as-is would cost
-- zero manipulations -- a full stack is worth the extra move.
--
-- Packs `amount` out of `stacks` (already scanned & sorted by count descending) into
-- the fewest maxStack-sized chunks (remainder last), marking whichever stacks it
-- claims `used`. An exact-size unclaimed stack is claimed as a chunk for free; a chunk
-- with no exact match tops up the largest unclaimed stack from the next-largest ones,
-- splitting only the contributor that would overshoot. Returns the finished
-- { bag, slot } queue for `amount` (a `pending` placeholder marks a chunk whose final
-- slot isn't known until execution -- see the "trim" action in runAction) plus the
-- ordered Pickup/Split `actions` needed to realize it.
local function packStacks(stacks, amount, maxStack)
	local chunks, claimed = {}, {}
	local remaining = amount
	while remaining > 0 do
		local size = remaining > maxStack and maxStack or remaining
		table.insert(chunks, size)
		remaining = remaining - size
	end
	local chunkCount = table.getn(chunks)

	local queue, actions = {}, {}

	-- Exact-size stacks need no manipulation at all -- claim those first.
	for c = 1, chunkCount do
		for i = 1, table.getn(stacks) do
			local s = stacks[i]
			if not s.used and s.count == chunks[c] then
				s.used = true
				claimed[c] = true
				table.insert(queue, { bag = s.bag, slot = s.slot })
				break
			end
		end
	end

	-- Whatever's left is assembled by topping up the largest unclaimed stack from
	-- the next-largest ones, splitting only the contributor that would overshoot.
	for c = 1, chunkCount do
		if not claimed[c] then
			local size = chunks[c]
			local destIndex
			for i = 1, table.getn(stacks) do
				if not stacks[i].used then destIndex = i; break end
			end
			if not destIndex then break end
			local dest = stacks[destIndex]
			dest.used = true
			local have = dest.count
			if have > size then
				-- The largest unclaimed stack already overshoots this (necessarily the
				-- smallest/remainder) chunk -- trim it down. Its destination (a free bag
				-- slot) is only known once findEmptySlot runs at execution time, so the
				-- queue gets a placeholder keyed to this action's index for now.
				table.insert(actions, { kind = "trim", bag = dest.bag, slot = dest.slot, amount = size })
				table.insert(queue, { pending = table.getn(actions) })
			else
				while have < size do
					local srcIndex
					for i = 1, table.getn(stacks) do
						if not stacks[i].used then srcIndex = i; break end
					end
					if not srcIndex then break end
					local src = stacks[srcIndex]
					local need = size - have
					if src.count <= need then
						src.used = true
						table.insert(actions, { kind = "move", bag = src.bag, slot = src.slot,
							destBag = dest.bag, destSlot = dest.slot })
						have = have + src.count
					else
						table.insert(actions, { kind = "splitmove", bag = src.bag, slot = src.slot,
							amount = need, destBag = dest.bag, destSlot = dest.slot })
						src.count = src.count - need
						have = have + need
					end
				end
				table.insert(queue, { bag = dest.bag, slot = dest.slot })
			end
		end
	end

	return queue, actions
end

-- Mail can't carry soulbound, quest, or conjured items, and 1.12 has no API flag
-- for any of them -- the tooltip text is the only tell. Per SLOT, not per item:
-- binding is per item instance (a bound and an unbound copy of a BoE can coexist).
local mailTip
local function slotMailable(bag, slot)
	if not mailTip then
		mailTip = CreateFrame("GameTooltip", "QuartermasterMailTip", nil, "GameTooltipTemplate")
	end
	mailTip:SetOwner(UIParent, "ANCHOR_NONE")
	mailTip:ClearLines()
	mailTip:SetBagItem(bag, slot)
	for i = 1, mailTip:NumLines() do
		local line = getglobal("QuartermasterMailTipTextLeft" .. i)
		local text = line and line:GetText()
		if text == ITEM_SOULBOUND or text == ITEM_BIND_QUEST or text == ITEM_CONJURED then
			return false
		end
	end
	return true
end

-- planStacks itself only READS bag state and is pure planning -- it returns the
-- final { bag, slot } queue to send plus an ordered list of the actual Pickup/Split
-- "actions" needed to realize it (that queue's mail-side use of `pending` placeholders
-- is documented on packStacks above), plus how much of `amount` unmailable slots cost
-- (the caller's count doesn't know about binding). The actions are NOT run here: see
-- prepNextStep below for why.
local function planStacks(itemID, amount)
	local _, _, _, _, _, _, maxStack = GetItemInfo("item:" .. itemID)
	maxStack = maxStack or 1

	local stacks, mailable, unmailable = {}, 0, 0
	for bag = 0, 4 do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local link = GetContainerItemLink(bag, slot)
			if link and QM.itemID(link) == itemID then
				local _, count = GetContainerItemInfo(bag, slot)
				if slotMailable(bag, slot) then
					table.insert(stacks, { bag = bag, slot = slot, count = count or 0, used = false })
					mailable = mailable + (count or 0)
				else
					unmailable = unmailable + (count or 1)
				end
			end
		end
	end
	table.sort(stacks, function(a, b) return a.count > b.count end)

	local short = amount - mailable
	if short < 0 then short = 0 end
	if short > unmailable then short = unmailable end
	if short > 0 then amount = mailable end

	local queue, actions = packStacks(stacks, amount, maxStack)

	-- Picking stacks for `amount` can strand an oddly-sized remainder behind -- e.g.
	-- trimming a stack down to size for the mail leaves its cut-off leftover sitting
	-- next to some other untouched partial instead of merging with it. Consolidate
	-- whatever's left (now the unclaimed stacks) with the same packing, so a target of
	-- 10 doesn't end up as a 9-stack and a 1-stack when it could be one clean 10. Its
	-- queue is discarded -- there's nothing to send -- only the merge actions matter.
	local leftover = 0
	for i = 1, table.getn(stacks) do
		if not stacks[i].used then leftover = leftover + stacks[i].count end
	end
	if leftover > 0 then
		local _, restackActions = packStacks(stacks, leftover, maxStack)
		for i = 1, table.getn(restackActions) do table.insert(actions, restackActions[i]) end
	end

	return queue, actions, short
end

-- ---------------------------------------------------------------------------
-- Async queue prep: turn several items' { id, amount } requests into one combined
-- { bag, slot } queue, running at most one bag-touching action per PREP_STEP_DELAY
-- tick -- across items AND within a single item's own stack assembly -- before
-- handing the complete queue off in one shot.
-- ---------------------------------------------------------------------------
-- IMPORTANT: this is the only place allowed to execute a planStacks() plan. Firing
-- several Pickup/SplitContainerItem pairs back-to-back with zero delay between them --
-- even for the SAME item, e.g. merging two partial stacks together and THEN topping the
-- result up from a third -- desyncs this client (compounded by TurtleMail globally
-- hooking PickupContainerItem): items are left locked ("greyed") mid-transaction and
-- TurtleMail's attach never completes, so no mail fires and the batch just stalls on
-- its watchdog timeout. One manipulation per tick, no exceptions, fixes it.
local Prep = CreateFrame("Frame")
local PREP_STEP_DELAY = 0.3 -- lets one manipulation settle before the next --
                            -- either the next item, or the next step within this
                            -- item's own assembly -- touches bags. See above.
local SETTLE_TIMEOUT = 5    -- settle gate: give up waiting for locks and send
                            -- whatever is actually sendable (see queueSettled)

local function runAction(a, queue)
	ClearCursor()
	if a.kind == "move" then
		PickupContainerItem(a.bag, a.slot)
		PickupContainerItem(a.destBag, a.destSlot)
	elseif a.kind == "splitmove" then
		SplitContainerItem(a.bag, a.slot, a.amount)
		PickupContainerItem(a.destBag, a.destSlot)
	elseif a.kind == "trim" then
		local freeBag, freeSlot = findEmptySlot(bagContainers())
		local resolved
		if freeBag then
			SplitContainerItem(a.bag, a.slot, a.amount)
			PickupContainerItem(freeBag, freeSlot)
			resolved = { bag = freeBag, slot = freeSlot }
		else
			-- no free slot to split into: fall back to sending the stack whole
			resolved = { bag = a.bag, slot = a.slot }
		end
		for i = 1, table.getn(queue) do
			if queue[i].pending == a.token then queue[i] = resolved end
		end
	end
	ClearCursor()
end

-- Settle gate: every queued slot must hold its item, unlocked. A slot still
-- lock-pending from a split/move a tick earlier either attaches as NOTHING or --
-- worse -- attaches fine off the client's optimistic state and the SendMail then
-- dies server-side with no event at all; both are observed failure modes of
-- handing the Mailer a queue before the server has acked the last manipulation
-- (the Mailer's own retries are the second line of defense, this is the first).
local function queueSettled(queue)
	for i = 1, table.getn(queue) do
		local q = queue[i]
		if q.bag then
			local link = GetContainerItemLink(q.bag, q.slot)
			local _, _, locked = GetContainerItemInfo(q.bag, q.slot)
			if not link or locked then return false end
		end
	end
	return true
end

local function finishPrep()
	Prep:SetScript("OnUpdate", nil)
	Prep.settling = false
	setStatus(nil)
	local cb, queue = Prep.callback, Prep.queue
	Prep.items, Prep.queue, Prep.callback = nil, nil, nil
	if cb then cb(queue) end
end

local function beginItem()
	Prep.index = Prep.index + 1
	if Prep.index > table.getn(Prep.items) then
		-- Plan done, but don't hand the queue over yet -- hold it at the settle gate
		-- (see queueSettled) until the last manipulations' locks clear.
		Prep.settling, Prep.settleElapsed = true, 0
		setStatus("Waiting for item locks to settle")
		return
	end
	local item = Prep.items[Prep.index]
	local name = item.name or GetItemInfo("item:" .. item.id) or ("item " .. item.id)
	setStatus("Preparing stacks: " .. name .. " (" .. Prep.index .. "/" .. table.getn(Prep.items) .. ")")
	local itemQueue, actions, unmailable = planStacks(item.id, item.amount)
	if unmailable > 0 then
		QM.print(unmailable .. "x " .. name .. " skipped -- can't be mailed (soulbound/quest/conjured)")
	end
	for i = 1, table.getn(actions) do actions[i].token = i end
	Prep.itemQueue, Prep.actions, Prep.actionIndex = itemQueue, actions, 0
end

-- One tick, one action: either the next manipulation this item's plan still needs, or
-- (once it has none left) folding its finished queue in and planning the next item.
-- Once all items are planned, ticks poll the settle gate instead.
local function prepNextStep()
	if Prep.settling then
		if queueSettled(Prep.queue) then finishPrep(); return end
		Prep.settleElapsed = Prep.settleElapsed + PREP_STEP_DELAY
		if Prep.settleElapsed >= SETTLE_TIMEOUT then
			-- Something never unlocked, or a planned slot ended up empty. Drop what
			-- can't attach and send the rest rather than stall the whole batch.
			local kept = {}
			for i = 1, table.getn(Prep.queue) do
				local q = Prep.queue[i]
				if q.bag and GetContainerItemLink(q.bag, q.slot) then table.insert(kept, q) end
			end
			local dropped = table.getn(Prep.queue) - table.getn(kept)
			if dropped > 0 then QM.print(dropped .. " stack(s) skipped -- bag slot never settled") end
			Prep.queue = kept
			finishPrep()
		end
		return
	end
	if Prep.actions and Prep.actionIndex < table.getn(Prep.actions) then
		Prep.actionIndex = Prep.actionIndex + 1
		runAction(Prep.actions[Prep.actionIndex], Prep.itemQueue)
		return
	end
	if Prep.itemQueue then
		for i = 1, table.getn(Prep.itemQueue) do table.insert(Prep.queue, Prep.itemQueue[i]) end
	end
	beginItem()
end

-- Mailbox closed mid-prep: nothing downstream can send anymore, so stop stepping
-- and drop the batch (the callback is never fired).
cancelPrep = function()
	if not Prep.items then return end
	Prep:SetScript("OnUpdate", nil)
	Prep.items, Prep.queue, Prep.callback, Prep.settling = nil, nil, nil, false
	setStatus(nil)
end

-- Build the combined { bag, slot } queue for `items` ({ {id=,amount=}, ... }), one
-- manipulation per tick, then calls callback(queue). The first step runs on the next
-- frame (not synchronously) so every item, including the first, goes through the
-- exact same paced path.
local function prepareQueue(items, callback)
	if table.getn(items) == 0 then callback({}); return end
	if Prep.items then
		-- A second run would clobber the in-flight one's state mid-batch and
		-- interleave bag manipulations -- exactly the desync this frame exists to
		-- prevent. (A stuck prep can't wedge this forever: the settle gate times out.)
		QM.print("bag prep already running -- try again in a moment")
		return
	end
	Prep.items, Prep.index, Prep.queue, Prep.callback = items, 0, {}, callback
	Prep.itemQueue, Prep.actions, Prep.actionIndex = nil, nil, 0
	Prep.settling, Prep.settleElapsed = false, 0
	Prep.elapsed = PREP_STEP_DELAY
	Prep:SetScript("OnUpdate", function()
		Prep.elapsed = Prep.elapsed + arg1
		if Prep.elapsed >= PREP_STEP_DELAY then Prep.elapsed = 0; prepNextStep() end
	end)
end

-- ---------------------------------------------------------------------------
-- Recipients: known characters (same realm+faction, mail can't cross either)
-- plus a manually managed custom list, for the Transfer tab's dropdowns.
-- ---------------------------------------------------------------------------
function QM.transferRecipients()
	local seen, out = {}, {}
	local custom = QM.db and QM.db.mailRecipients or {}
	for i = 1, table.getn(custom) do
		local n = custom[i]
		if not seen[n] then seen[n] = true; table.insert(out, n) end
	end
	local me, myKey = QM.me, QM.charKey()
	QM.eachChar(function(key, rec)
		if key ~= myKey and me and rec.realm == me.realm and rec.faction == me.faction and not seen[key] then
			seen[key] = true
			table.insert(out, key)
		end
	end)
	table.sort(out)
	return out
end

function QM.addMailRecipient(name)
	name = QM.trim(name or "")
	if name == "" or not QM.db then return end
	QM.db.mailRecipients = QM.db.mailRecipients or {}
	local list = QM.db.mailRecipients
	for i = 1, table.getn(list) do
		if list[i] == name then return end
	end
	table.insert(list, name)
	QM.fire("DESIRED_CHANGED")
end

function QM.removeMailRecipient(name)
	local list = QM.db and QM.db.mailRecipients
	if not list then return end
	for i = 1, table.getn(list) do
		if list[i] == name then
			table.remove(list, i)
			QM.fire("DESIRED_CHANGED")
			return
		end
	end
end

function QM.setDefaultMailRecipient(value)
	local c = QM.me
	if not c then return end
	c.defaultMailRecipient = (value and value ~= "") and value or nil
	QM.fire("DESIRED_CHANGED")
end

-- Remembers this character's last "supply another character" target -- both the
-- Transfer tab's chained dropdowns and /qm mailsync write through this, so either
-- entry point picks up where the other left off.
function QM.setMailTarget(charKey, profileName)
	local c = QM.me
	if not c then return end
	c.mailTarget = { char = charKey, profile = profileName }
	QM.fire("DESIRED_CHANGED")
end

-- Character names with at least one non-empty tracker profile, same realm+faction
-- as me, excluding myself -- candidates for the "supply another character" dropdown.
function QM.eachCharWithList()
	local out = {}
	local me, myKey = QM.me, QM.charKey()
	QM.eachChar(function(key, rec)
		if key ~= myKey and me and rec.realm == me.realm and rec.faction == me.faction and rec.profiles then
			for _, list in pairs(rec.profiles) do
				if table.getn(list) > 0 then table.insert(out, key); break end
			end
		end
	end)
	table.sort(out)
	return out
end

-- Profile names of an ARBITRARY character (unlike QM.profileNames, which only ever
-- reads QM.me) -- backs the Transfer tab's character->profile dropdown chain.
function QM.charProfileNames(charKey)
	local rec = QM.db and QM.db.chars[charKey]
	local names = {}
	if rec and rec.profiles then
		for n in pairs(rec.profiles) do table.insert(names, n) end
	end
	table.sort(names)
	return names
end

-- ---------------------------------------------------------------------------
-- Mail dump: ship everything over its Keep floor in the transferable list to
-- each row's resolved recipient (its own mailRecipient, else the character's
-- defaultMailRecipient), one recipient batch after another through the Mailer.
-- ---------------------------------------------------------------------------
function T.mailDumpExcess()
	local c = QM.me
	if not c then return end
	local groups, order = {}, {}

	local function queueExcess(id, excess, recipient)
		if excess <= 0 or not (recipient and recipient ~= "") then return end
		if not groups[recipient] then groups[recipient] = {}; table.insert(order, recipient) end
		table.insert(groups[recipient], { id = id, amount = excess })
	end

	local list = c.transferable or {}
	for i = 1, table.getn(list) do
		local e = list[i]
		if not QM.isDivider(e) and QM.itemActive(e) then
			local bags = QM.itemCount(e.id)
			queueExcess(e.id, bags - transferableFloor(c, e), e.mailRecipient or c.defaultMailRecipient)
		end
	end

	-- Tracked-list overage has no per-item recipient of its own (it isn't on the
	-- transferable list), so it only ships to the default -- and only when one is set,
	-- same as a per-item entry with no override and no default would otherwise be
	-- silently skipped below. Dual-listed items are excluded (handled above instead --
	-- see inTransferableList's comment for why processing one here too would over-mail it).
	if QM.db.options.transfer.mailTrackedOverage and c.defaultMailRecipient and c.defaultMailRecipient ~= "" then
		local tlist = c.consumables or {}
		for i = 1, table.getn(tlist) do
			local e = tlist[i]
			if not QM.isDivider(e) and QM.itemActive(e) and not inTransferableList(c, e.id) then
				local bags = QM.itemCount(e.id)
				queueExcess(e.id, bags - (e.target or 0), c.defaultMailRecipient)
			end
		end
	end

	if table.getn(order) == 0 then
		QM.print("nothing to mail -- set a mail recipient (per item, or a default)")
		return
	end

	local function sendNext(i)
		if i > table.getn(order) then QM.scanInventory(); return end
		local recipient = order[i]
		prepareQueue(groups[recipient], function(queue)
			if table.getn(queue) > 0 then
				T.mailItems(recipient, queue, function() sendNext(i + 1) end)
			else
				sendNext(i + 1)
			end
		end)
	end
	sendNext(1)
end

-- Seed the transferable list from one of this character's Tracker profiles -- e.g. a
-- bank alt that wants everything the raid profile carries also shed to Transferable.
-- Items already on the transferable list (by id) are left untouched, so this is safe
-- to run repeatedly as the source profile changes. Returns the count actually added.
function T.importFromProfile(profileName)
	local c = QM.me
	if not c or not c.profiles then return 0 end
	local src = c.profiles[profileName]
	if not src then return 0 end
	local list = c.transferable
	if not list then list = {}; c.transferable = list end
	local have = {}
	for i = 1, table.getn(list) do
		local e = list[i]
		if not QM.isDivider(e) then have[e.id] = true end
	end
	local added = 0
	for i = 1, table.getn(src) do
		local e = src[i]
		if not QM.isDivider(e) and not have[e.id] then
			table.insert(list, { id = e.id, name = e.name, icon = e.icon, quality = e.quality,
				target = 0, bankable = true, state = "enabled" })
			have[e.id] = true
			added = added + 1
		end
	end
	if added > 0 then QM.fire("DESIRED_CHANGED") end
	return added
end

-- ---------------------------------------------------------------------------
-- Mail supply: what can I personally cover of another character's shortfall?
-- Distinct from T.plan (which answers "what do I still need") -- this answers
-- "what does THAT character need, that I'm carrying right now".
-- ---------------------------------------------------------------------------
function T.supplyPlan(targetCharKey, profileName)
	local rec = QM.db and QM.db.chars[targetCharKey]
	local list = rec and rec.profiles and rec.profiles[profileName]
	if not list then return {} end
	local rows = {}
	for i = 1, table.getn(list) do
		local e = list[i]
		if not QM.isDivider(e) and QM.itemActive(e) then
			local inv = rec.inventory and rec.inventory[e.id]
			local have = inv and inv.total or 0
			-- Net out anything already mailed toward this shortfall but not yet picked
			-- up, so a second mule doesn't queue a duplicate send for the same amount.
			local short = (e.target or 0) - have - QM.inFlightCount(targetCharKey, e.id)
			if short > 0 then
				local mine = QM.itemCount(e.id)
				local amount = short
				if mine < amount then amount = mine end
				if amount > 0 then table.insert(rows, { id = e.id, name = e.name, amount = amount }) end
			end
		end
	end
	return rows
end

-- Build the queue from T.supplyPlan and send it in one batch to targetCharKey. Marks
-- in-flight toward targetCharKey only once the batch is over and each row's bag count
-- actually dropped by some amount (a real bags-before vs. bags-after delta), not just
-- because T.mailItems ran -- T.mailItems has no per-item send confirmation, and a
-- corrupted/aborted send (T.mailItems/TurtleMail failing partway through a
-- multi-attachment batch) would otherwise mark stock as in-flight that never actually
-- left, permanently masking a real shortfall (QM.inFlightCount nets it out of every
-- future T.supplyPlan). Marking less than requested, or nothing, for a partial/failed
-- send is correct: only what's verifiably gone is safe to treat as "on its way".
-- Real stock only replaces it once targetCharKey's own session takes the mail
-- (Transfer.lua's TakeInboxItem hook, QM.clearInFlight) -- or, failing that, once
-- targetCharKey's own MAIL_SHOW resets the cache outright (see above).
function T.supplySend(targetCharKey, profileName)
	local rows = T.supplyPlan(targetCharKey, profileName)
	if table.getn(rows) == 0 then
		QM.print(targetCharKey .. " isn't short on anything you're carrying")
		return
	end
	QM.scanInventory()
	local before = {}
	for i = 1, table.getn(rows) do before[rows[i].id] = QM.itemCount(rows[i].id) end
	prepareQueue(rows, function(queue)
		T.mailItems(targetCharKey, queue, function()
			QM.scanInventory()
			for i = 1, table.getn(rows) do
				local id = rows[i].id
				local sent = (before[id] or 0) - QM.itemCount(id)
				if sent > 0 then QM.addInFlight(targetCharKey, id, sent) end
			end
		end)
	end)
end

-- /qm mailsync <character> [list] -- list defaults to that character's active profile.
-- Updates the stored mail target the same as picking it from the Transfer tab.
function T.mailSyncTo(charKey, profileName)
	local rec = QM.db and QM.db.chars[charKey]
	if not rec and QM.db then
		-- slash input is easy to mis-case; fall back to a case-insensitive key match.
		local lower = string.lower(charKey)
		for key, r in pairs(QM.db.chars) do
			if string.lower(key) == lower then charKey, rec = key, r; break end
		end
	end
	if not rec then QM.print("unknown character '" .. charKey .. "'"); return end
	local profile = profileName or rec.activeProfile
	if not profile or not rec.profiles or not rec.profiles[profile] then
		QM.print(charKey .. " has no profile '" .. (profile or "?") .. "'")
		return
	end
	QM.setMailTarget(charKey, profile)
	T.supplySend(charKey, profile)
end

-- ---------------------------------------------------------------------------
-- Mail panel (Quartermaster_Mail, Quartermaster.xml): Dump Excess + the
-- character/profile drop buttons, live on the actual mailbox instead of buried in
-- config. Shown only while the mailbox is open, anchored to its top edge.
-- ---------------------------------------------------------------------------

-- Anchored directly to Blizzard's MailFrame rather than QM.registerMoveable's
-- UIParent-relative system: this panel should track the mailbox, not a stored
-- screen position (registerMoveable's storeFramePos assumes a TOPLEFT/UIParent
-- anchor, which a MailFrame-relative one isn't). Re-run on every MAIL_SHOW, and
-- defensively on DB_READY/LOCK_CHANGED in the rare case those land while mail is
-- already open (both fire well after Core's own moveable-position handlers, so
-- this always has the last word).
local function anchorMailFrame()
	local frame = QM.mailFrame
	if not (frame and MailFrame) then return end
	frame:ClearAllPoints()
	frame:SetPoint("BOTTOM", MailFrame, "TOP", 0, 8)
end

QM.on("MAIL_SHOW", function()
	if not QM.mailFrame then return end
	anchorMailFrame()
	QM.mailFrame:Show()
end)
QM.on("MAIL_CLOSED", function() if QM.mailFrame then QM.mailFrame:Hide() end end)
QM.subscribe("DB_READY", function() if QM.mailFrame and QM.mailFrame:IsShown() then anchorMailFrame() end end)
QM.subscribe("LOCK_CHANGED", function() if QM.mailFrame and QM.mailFrame:IsShown() then anchorMailFrame() end end)

function Quartermaster_Mail_OnLoad()
	local frame = this
	QM.mailFrame = frame

	local dumpBtn = QM.Config.button(frame, "Dump Excess", function() T.mailDumpExcess() end)
	dumpBtn:SetWidth(100)
	dumpBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -26)

	local profileDrop  -- forward decl: charDrop's onSelect repaints its face

	-- Backed by QM.me.mailTarget (not an ephemeral local), so the last character/
	-- profile picked here -- or via /qm mailsync -- survives a reload/reopen.
	local charDrop = QM.Config.dropButton(frame, {
		width = 110, height = 22, menuWidth = 130,
		values = function() return QM.eachCharWithList() end,
		get    = function() local t = QM.me and QM.me.mailTarget; return (t and t.char) or "Character" end,
		onSelect = function(v)
			local rec = QM.db.chars[v]
			local profile = rec and rec.activeProfile
			QM.setMailTarget(v, profile)
			if profileDrop then profileDrop.setValue(profile or "Profile") end
		end,
	})
	charDrop:SetPoint("LEFT", dumpBtn, "RIGHT", 8, 0)

	-- Picking a profile sends immediately (see the tooltip, built from T.supplyPlan, for
	-- a preview first). Choosing a character auto-selects ITS active profile, so accepting
	-- the default is just: pick a character, then click the (already-shown) profile.
	profileDrop = QM.Config.dropButton(frame, {
		width = 110, height = 22, menuWidth = 150,
		values = function()
			local t = QM.me and QM.me.mailTarget
			return (t and t.char) and QM.charProfileNames(t.char) or {}
		end,
		get = function() local t = QM.me and QM.me.mailTarget; return (t and t.profile) or "Profile" end,
		tipLines = function(v)
			local t = QM.me and QM.me.mailTarget
			if not (t and t.char) then return {} end
			local rows = T.supplyPlan(t.char, v)
			if table.getn(rows) == 0 then return { "Nothing to send" } end
			local lines = {}
			for i = 1, table.getn(rows) do
				table.insert(lines, rows[i].amount .. "x " .. (rows[i].name or ("item " .. rows[i].id)))
			end
			return lines
		end,
		onSelect = function(v)
			local t = QM.me and QM.me.mailTarget
			if t and t.char then
				QM.setMailTarget(t.char, v)
				T.supplySend(t.char, v)
			end
		end,
	})
	profileDrop:SetPoint("LEFT", charDrop, "RIGHT", 8, 0)

	QM.subscribe("DESIRED_CHANGED", function()
		local t = QM.me and QM.me.mailTarget
		charDrop.setValue((t and t.char) or "Character")
		profileDrop.setValue((t and t.profile) or "Profile")
	end)
end

-- ---------------------------------------------------------------------------
-- "Transfer" config tab
-- ---------------------------------------------------------------------------
QM.registerConfigTab({
	name = "Transfer", order = 40,
	build = function(parent)
		local page = QM.Config.scrollChild(parent, "QuartermasterTransferCfgScroll", 560)

		QM.Config.listEditor(page, {
			kind = "transferable",
			targetText   = "Keep",   -- floor to leave behind; sync ships everything above it
			bankable     = true,
			recipientText = "Mail To",
			afterAddRowWidth = 158, -- reserves room for the Import-profile drop (150w) + its 8px gap

			-- Above the list: manage the custom recipient-name pool, this character's
			-- default recipient, and the banksync overage option.
			header = function(page, title)
				local RECIPIENT_ROW_H = 20
				local RECIPIENT_LIST_W = 150
				local recipientRows = {}
				local recipientList

				local function recipientRow(i)
					local row = recipientRows[i]
					if row then return row end
					row = CreateFrame("Frame", nil, recipientList)
					row:SetHeight(RECIPIENT_ROW_H)
					row:SetPoint("TOPLEFT", recipientList, "TOPLEFT", 0, -(i - 1) * RECIPIENT_ROW_H)
					row:SetPoint("RIGHT", recipientList, "RIGHT", 0, 0)
					row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
					row.label:SetPoint("LEFT", 4, 0)
					row.del = QM.Config.button(row, "x", function()
						if row.name then QM.removeMailRecipient(row.name) end
					end)
					row.del:SetWidth(20)
					row.del:SetPoint("RIGHT", 0, 0)
					recipientRows[i] = row
					return row
				end

				local function refreshRecipientRows()
					local custom = (QM.db and QM.db.mailRecipients) or {}
					local n = table.getn(custom)
					for i = 1, n do
						local row = recipientRow(i)
						row.name = custom[i]
						row.label:SetText(custom[i])
						row:Show()
					end
					for i = n + 1, table.getn(recipientRows) do recipientRows[i]:Hide() end
					recipientList:SetHeight(((n > 0) and n or 1) * RECIPIENT_ROW_H)
				end

				local recipHdr = QM.Config.sectionHeader(page, "Mail recipients", 8, -6)
				if title then recipHdr:ClearAllPoints(); recipHdr:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8) end

				-- One row, left-aligned under the section header: the add box + Add button
				-- first, then the custom-recipient listbox, then the default-recipient drop.
				-- No onCommit (add explicitly via Enter/the Add button only): this is an
				-- add-new-entry box, not a persistent field, so blurring away from it (see
				-- QM.Config.editbox) must not silently add whatever text is left sitting in it.
				local addRecipBox
				addRecipBox = QM.Config.editbox(page, 100)
				addRecipBox:SetScript("OnEnterPressed", function()
					QM.addMailRecipient(this:GetText())
					addRecipBox:SetText("")
					this:ClearFocus()
				end)
				addRecipBox:SetPoint("TOPLEFT", recipHdr, "BOTTOMLEFT", 0, -6)
				local addRecipBtn = QM.Config.button(page, "Add", function()
					QM.addMailRecipient(addRecipBox:GetText())
					addRecipBox:SetText(""); addRecipBox:ClearFocus()
				end)
				addRecipBtn:SetWidth(44)
				addRecipBtn:SetPoint("LEFT", addRecipBox, "RIGHT", 6, 0)

				recipientList = CreateFrame("Frame", nil, page)
				recipientList:SetWidth(RECIPIENT_LIST_W)
				recipientList:SetPoint("LEFT", addRecipBtn, "RIGHT", 10, 0)
				recipientList:SetPoint("TOP", addRecipBox, "TOP", 0, 0)
				recipientList:SetHeight(RECIPIENT_ROW_H)
				QM.subscribe("DESIRED_CHANGED", refreshRecipientRows)
				QM.subscribe("CONFIG_SHOWN", refreshRecipientRows)
				refreshRecipientRows()

				-- Used when a transferable row has no per-item mailRecipient override.
				local defaultDrop = QM.Config.dropButton(page, {
					width = 225, height = 22, menuWidth = 255,
					prefix = "Default recipient",
					values = function()
						local v = { "(none)" }
						local r = QM.transferRecipients()
						for i = 1, table.getn(r) do table.insert(v, r[i]) end
						return v
					end,
					onSelect = function(v) QM.setDefaultMailRecipient(v == "(none)" and nil or v) end,
					get = function() local c = QM.me; return (c and c.defaultMailRecipient) or "(none)" end,
				})
				defaultDrop:SetPoint("LEFT", recipientList, "RIGHT", 16, 0)
				defaultDrop:SetPoint("TOP", addRecipBox, "TOP", 0, 0)
				QM.subscribe("DESIRED_CHANGED", function() defaultDrop.setValue((QM.me and QM.me.defaultMailRecipient) or "(none)") end)

				local overageCheck = QM.Config.check(page,
					"Also bank tracked-list overage on /qm banksync", 0, 0,
					function(v) QM.db.options.transfer.dumpTrackedOverage = v end,
					function() return QM.db.options.transfer.dumpTrackedOverage ~= false end)
				overageCheck:ClearAllPoints()
				-- X from the row's left edge (addRecipBox), Y from whichever of the row's
				-- pieces is tallest (recipientList, once it holds more than one custom name).
				overageCheck:SetPoint("LEFT", addRecipBox, "LEFT", 0, 0)
				overageCheck:SetPoint("TOP", recipientList, "BOTTOM", 0, -12)

				-- Mail's counterpart: tracked-list overage has no per-item recipient of its
				-- own (it isn't on the transferable list), so it only ever goes to the
				-- default above -- and only when Dump Excess/mailsync sees one set.
				local mailOverageCheck = QM.Config.check(page,
					"Also mail tracked-list overage to the default recipient", 0, 0,
					function(v) QM.db.options.transfer.mailTrackedOverage = v end,
					function() return QM.db.options.transfer.mailTrackedOverage ~= false end)
				mailOverageCheck:ClearAllPoints()
				mailOverageCheck:SetPoint("LEFT", overageCheck.label, "RIGHT", 16, 0)

				-- What this list is for, right above the shared "Add item:" row. A fixed
				-- width (rather than anchoring RIGHT to the scrollChild) guarantees it wraps
				-- onto multiple lines regardless of the scrollChild's own fit()-derived width,
				-- which isn't reliably resolved yet the instant this header builds (see
				-- QM.Config.scrollChild's GetWidth() caveat).
				local explain = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
				explain:SetPoint("TOPLEFT", overageCheck, "BOTTOMLEFT", 0, -10)
				explain:SetWidth(600)
				explain:SetJustifyH("LEFT")
				explain:SetTextColor(0.7, 0.7, 0.7)
				explain:SetText("Items below are shed rather than restocked: Keep is the floor left on " ..
					"this character -- anything held above it can be banked (Bankable, /qm banksync) " ..
					"or mailed (Mail To, or the default above).")

				return explain   -- bottom-most; the add row stacks below it
			end,
			-- Bulk-seed the list from a Tracker profile (T.importFromProfile), inline with
			-- the add row rather than a whole header section for one action button. Its face
			-- is fixed text (staticLabel): this is a one-shot action, not a persistent field,
			-- so there's nothing to keep displaying after the pick.
			afterAddRow = function(page, anchorBtn)
				local importDrop = QM.Config.dropButton(page, {
					width = 150, height = 22, menuWidth = 170,
					staticLabel = "Import profile",
					values = function() return QM.profileNames() end,
					get = function() return nil end,
					onSelect = function(v)
						local n = T.importFromProfile(v)
						QM.print(n .. " item" .. (n == 1 and "" or "s") .. " imported from \"" .. v .. "\"")
					end,
				})
				importDrop:SetPoint("LEFT", anchorBtn, "RIGHT", 8, 0)
			end,
			-- No footer here: Dump Excess + the character/profile pickers live on the
			-- Quartermaster_Mail panel instead (shown only while the mailbox is open --
			-- see Quartermaster_Mail_OnLoad below), not buried in a config tab.
		})
	end,
})
