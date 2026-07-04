-- Quartermaster -- Config
-- A modular, tabbed config panel. Each feature module owns a tab, registered via
-- QM.registerConfigTab{ name=, order=, build=function(page) } at load time; this
-- file just lays the tabs out down the left and builds each page lazily into the
-- content area on the right. New features add a tab instead of fighting for space
-- on one crowded panel -- that's the answer to "we'll run out of config room".
--
-- The reusable QM.Config.listEditor (a FauxScrollFrame list with add / reorder /
-- remove + a per-row amount) backs both the Buffs and Items tabs, so the
-- per-character add/reorder UX is one widget, not two.
--
-- Widget idioms (custom edit-box backdrop, value-in-title sliders, the upvalue
-- discipline) follow the sibling FearWardHelper config; see its CLAUDE.md.

local QM = Quartermaster
QM.Config = {}

local PANEL_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 5, right = 5, top = 5, bottom = 5 },
}
local EDITBOX_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 9,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
-- Backdrop for the apply-mode drop button's popup menu (a touch heavier border than
-- the edit boxes so the floating list reads as a distinct panel).
local MENU_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Popups that float outside the tab-page hierarchy -- dropdown menus, the gear popup,
-- the modal dialogs -- are deliberately parented straight to the panel (not a tab's page)
-- so a ScrollFrame never clips them. That means hiding a page on tab switch never hides
-- them as a side effect. Anything built that way registers itself here once; selectTab()
-- and toggleConfig()'s hide branch close whatever's left open so a stray popup can't
-- survive a tab switch or a close/reopen of the panel.
local floaters = {}
local function registerFloater(frame)
	floaters[table.getn(floaters) + 1] = frame
end
local function closeFloaters()
	for i = 1, table.getn(floaters) do
		if floaters[i]:IsShown() then floaters[i]:Hide() end
	end
end

-- Route shift-clicked item links into whichever Quartermaster edit box currently has
-- focus (_linkSink, set by the add box on focus gain, cleared on focus loss).
local function routeLink(text)
	local sink = QM.Config._linkSink
	if text and sink and sink:IsVisible() then
		sink:Insert(text)
		sink:SetFocus()
		return true
	end
	return false
end

-- On 1.12 a shift-click in the world/bags is handled by HandleModifiedItemClick, which
-- only forwards to ChatEdit_InsertLink when the CHAT edit box is visible -- so wrapping
-- ChatEdit_InsertLink alone never catches links destined for a custom box. We intercept
-- HandleModifiedItemClick itself (the real entry point), and still wrap
-- ChatEdit_InsertLink for the path that reaches it directly (clicking a link in chat).
local origModifiedClick = HandleModifiedItemClick
function HandleModifiedItemClick(link)
	if link and IsModifiedClick("CHATLINK") and routeLink(link) then return true end
	if origModifiedClick then return origModifiedClick(link) end
end

local origInsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(text)
	if routeLink(text) then return true end
	if origInsertLink then return origInsertLink(text) end
	return false
end

-- Drag/drop support. Vanilla has no API to read the item sitting on the cursor, so we
-- remember its link as it is picked up (from a bag or an equipped slot -- captured BEFORE
-- the pickup empties the source) and consume that when an item is dropped on a focused
-- add box. Cleared whenever a pickup leaves the cursor empty.
local origPickupContainer = PickupContainerItem
function PickupContainerItem(bag, slot)
	local link = GetContainerItemLink(bag, slot)
	if origPickupContainer then origPickupContainer(bag, slot) end
	QM.Config._cursorLink = CursorHasItem() and link or nil
end

local origPickupInventory = PickupInventoryItem
function PickupInventoryItem(slot)
	local link = GetInventoryItemLink("player", slot)
	if origPickupInventory then origPickupInventory(slot) end
	QM.Config._cursorLink = CursorHasItem() and link or nil
end

-- Drop the cursor's item into `box` (the add box). Returns true if a link was placed.
function QM.Config.dropCursorItem(box)
	if not CursorHasItem() then return false end
	local link = QM.Config._cursorLink
	if link then box:Insert(link); box:SetFocus() end
	ClearCursor()
	QM.Config._cursorLink = nil
	return link and true or false
end

-- ---------------------------------------------------------------------------
-- Small widget factories (shared by every tab)
-- ---------------------------------------------------------------------------

-- A text/numeric edit box with a tooltip-style backdrop (InputBoxTemplate's
-- border renders a black bar at small heights, hence the custom backdrop).
function QM.Config.editbox(parent, width, onCommit)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetWidth(width); e:SetHeight(20)
	e:SetAutoFocus(false)
	e:SetFontObject(GameFontHighlightSmall)
	e:SetTextInsets(5, 5, 2, 2)
	e:SetBackdrop(EDITBOX_BACKDROP)
	e:SetBackdropColor(0, 0, 0, 0.7)
	e:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	local escaping = false
	e:SetScript("OnEnterPressed", function() onCommit(this:GetText()); this:ClearFocus() end)
	-- Escape means discard: suppress the focus-lost commit below so the box just reverts
	-- to the saved value on the next repaint instead of committing the abandoned text.
	e:SetScript("OnEscapePressed", function() escaping = true; this:ClearFocus() end)
	-- Commit on focus loss too, not just Enter -- so a value typed then abandoned by
	-- clicking elsewhere still lands rather than reverting silently. Tracked in
	-- QM.Config._focusedEditBox so the panel's OnHide can force this even when hiding the
	-- frame doesn't itself raise a focus-lost event (closing the config with a box still
	-- focused).
	e:SetScript("OnEditFocusGained", function() QM.Config._focusedEditBox = this end)
	e:SetScript("OnEditFocusLost", function()
		if QM.Config._focusedEditBox == this then QM.Config._focusedEditBox = nil end
		if escaping then escaping = false
		elseif onCommit then onCommit(this:GetText()) end
	end)
	return e
end

-- A checkbox; onClick gets the new boolean. Optional get() seeds the initial state.
function QM.Config.check(parent, text, x, y, onClick, get)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetWidth(22); cb:SetHeight(22)
	cb:SetPoint("TOPLEFT", x, y)
	local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0); fs:SetText(text)
	cb.label = fs   -- exposed so callers can chain a neighbour off its rendered width
	cb:SetScript("OnClick", function() onClick(this:GetChecked() and true or false) end)
	if get then cb:SetChecked(get() and true or false) end
	return cb
end

-- A horizontal slider whose title carries the live value. onChange gets the new
-- value; optional get()/fmt() seed and format it. A guard flag suppresses the
-- OnValueChanged feedback while we seed the value.
function QM.Config.slider(parent, name, label, min, max, step, x, y, onChange, get, fmt)
	local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
	s:SetMinMaxValues(min, max)
	s:SetValueStep(step)
	s:SetWidth(170); s:SetHeight(16)
	s:SetPoint("TOPLEFT", x, y)
	getglobal(name .. "Low"):SetText("")
	getglobal(name .. "High"):SetText("")
	local function paint(v) getglobal(name .. "Text"):SetText(label .. ": " .. (fmt and fmt(v) or v)) end
	s:SetScript("OnValueChanged", function()
		if QM.Config._setting then return end
		onChange(this:GetValue())
		paint(this:GetValue())
	end)
	if get then
		QM.Config._setting = true
		s:SetValue(get())
		QM.Config._setting = false
		paint(get())
	end
	return s
end

-- A small gold section sub-header, so a page of controls reads as grouped clusters rather
-- than one long stack (matches the HUD's gold category labels).
function QM.Config.sectionHeader(page, text, x, y)
	local fs = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	fs:SetTextColor(1, 0.82, 0)
	return fs
end

-- A top-down layout cursor for a config page: stacks section headers and 1-or-2-column
-- checkbox rows while tracking the running Y, so a tab doesn't hand-compute every offset.
-- Non-checkbox controls (sliders, drop buttons) read `L.y` for their top and call
-- `L.advance(px)` to reserve their height. `col1`/`col2` are the two checkbox column x's.
function QM.Config.layout(page, top)
	local L = { page = page, y = top or -8, col1 = 8, col2 = 300 }
	function L.section(text)
		L.y = L.y - 8
		QM.Config.sectionHeader(page, text, 8, L.y)
		L.y = L.y - 18
	end
	-- One row of up to two checkboxes; each arg is { label, setFn, getFn }. Returns the
	-- left-column checkbox (a page-left handle later controls can anchor beneath).
	function L.checks(a, b)
		local c1 = QM.Config.check(page, a[1], L.col1, L.y, a[2], a[3])
		if b then QM.Config.check(page, b[1], L.col2, L.y, b[2], b[3]) end
		L.y = L.y - 24
		return c1
	end
	function L.advance(px) L.y = L.y - (px or 12) end
	return L
end

-- The shared "flat dark" button look used across the whole panel (the drop / icon /
-- state / tab / action buttons all read alike): the tooltip-style backdrop, plus a
-- hover-brighten on the border. Callers that need a custom OnEnter (a tooltip, an
-- enabled check) set their own afterwards.
local function styleFlatButton(b)
	b:SetBackdrop(EDITBOX_BACKDROP)
	b:SetBackdropColor(0, 0, 0, 0.7)
	b:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
	b:SetScript("OnEnter", function() this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end)
end

-- A generic flat action button in the shared style. Centered label on `b.label`;
-- pressing nudges the label.
-- Caller sets the width; height defaults to 22. onClick is optional (wire it later if the
-- handler isn't in scope yet).
function QM.Config.button(parent, text, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetHeight(22)
	styleFlatButton(b)
	local fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	fs:SetPoint("CENTER", 0, 0)
	fs:SetText(text or "")
	b.label = fs
	b:SetScript("OnMouseDown", function() this.label:SetPoint("CENTER", 1, -1) end)
	b:SetScript("OnMouseUp", function() this.label:SetPoint("CENTER", 0, 0) end)
	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

-- A selectable button in the same style, for the config tab strip: b.setSelected(on)
-- shows the pressed/active look (lit background + gold border + bright label) and unselected
-- dims the label; the selected button ignores hover so the active tab stays lit.
function QM.Config.toggleButton(parent, text, onClick)
	local b = QM.Config.button(parent, text, onClick)
	b.label:SetTextColor(0.7, 0.7, 0.7)
	function b.setSelected(on)
		b.selected = on and true or false
		if b.selected then
			b:SetBackdropColor(0.22, 0.20, 0.05, 0.95)
			b:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
			b.label:SetTextColor(1, 1, 1)
		else
			b:SetBackdropColor(0, 0, 0, 0.7)
			b:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
			b.label:SetTextColor(0.7, 0.7, 0.7)
		end
	end
	b:SetScript("OnEnter", function() if not this.selected then this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end end)
	b:SetScript("OnLeave", function() if not this.selected then this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end end)
	return b
end

-- A drop button (edit-box styled, like the in-row controls) showing the current value
-- and dropping a popup list to change it -- no cycling. Used for both the in-row apply
-- column and the bigger Row-order config control. `spec`:
--   width/height   -- button size (height defaults to 18)
--   menuWidth      -- popup width (defaults to width + 12)
--   values         -- ordered list of stored values (menu order), or a function returning
--                     one: the menu is then rebuilt on every open (dynamic sets, e.g.
--                     profile names)
--   labels         -- value -> display label (the menu entries + button face); optional
--   tips           -- value -> tooltip line; optional
--   prefix         -- shown before the value on the face, e.g. "Row order: Config"; optional
--   onSelect(v)    -- called when a menu entry is picked
--   get()          -- optional: when given, the button self-paints from it on build and
--                     after each pick. Omit it for recycled rows (the caller repaints via
--                     b.setValue each draw instead).
-- The popup floats on DIALOG strata so it draws above the list rows; the live value is
-- stashed on b.value for the hover tooltip.
function QM.Config.dropButton(parent, spec)
	local values   = spec.values
	local labels   = spec.labels or {}
	local tips     = spec.tips
	local tipLines = spec.tipLines   -- value -> array of lines; computed live on hover
	                                  -- (vs. the static `tips` map), for a preview that
	                                  -- depends on other UI state (e.g. a chosen character).
	local width  = spec.width or 46

	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(width); b:SetHeight(spec.height or 18)
	styleFlatButton(b)

	-- Optional texture swatch behind the face: a full green progress bar drawn in the
	-- candidate texture, so the picker previews the actual bar (spec.swatches: value->path).
	-- The label sits on the swatch (a child frame draws above the button's own regions).
	local faceSwatch
	if spec.swatches then
		faceSwatch = CreateFrame("StatusBar", nil, b)
		faceSwatch:SetPoint("TOPLEFT", 3, -3); faceSwatch:SetPoint("BOTTOMRIGHT", -3, 3)
		faceSwatch:SetMinMaxValues(0, 1); faceSwatch:SetValue(1)
		faceSwatch:SetStatusBarColor(0.2, 0.8, 0.2)
	end
	local fs = (faceSwatch or b):CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.label = fs

	-- Paint the face from a stored value (also stashed for the tooltip). Exposed so the
	-- recycled-row caller can repaint per draw.
	function b.setValue(v)
		b.value = v
		-- staticLabel: the face always reads this fixed text (the value shows only in the open
		-- menu) -- for a picker where the face is a live preview, e.g. the bar-texture swatch.
		local txt = spec.staticLabel or labels[v] or v or "?"
		if spec.prefix and not spec.staticLabel then txt = spec.prefix .. ": " .. txt end
		fs:SetText(txt)
		if faceSwatch and spec.swatches[v] then faceSwatch:SetStatusBarTexture(spec.swatches[v]) end
	end

	-- Popup menu, toggled on click. It is hosted on the PANEL (not the
	-- button) at a high strata BY DEFAULT: parented under its button a drop menu sits inside
	-- the tab's ScrollFrame, so it gets clipped where it overflows and shares the rows'
	-- strata, landing behind the controls below. It still anchors to the button, so it
	-- tracks position. (menuParent/menuStrata override for callers outside the panel.)
	local MENU_ITEM_H = spec.swatches and 20 or 14
	local menu = CreateFrame("Frame", nil, spec.menuParent or getglobal("Quartermaster_Config") or b)
	menu:SetBackdrop(MENU_BACKDROP)
	menu:SetBackdropColor(0, 0, 0, 0.95)
	menu:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	menu:SetWidth(spec.menuWidth or (width + 12))
	menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, 0)
	menu:SetFrameStrata(spec.menuStrata or "FULLSCREEN_DIALOG")
	menu:SetToplevel(true)
	menu:Hide()
	registerFloater(menu)
	b.menu = menu

	-- Entry buttons are pooled so a dynamic menu (spec.values as a FUNCTION, e.g. profile
	-- names) can be rebuilt on every open; static menus build once below.
	menu.items = {}
	local function menuItem(i)
		local item = menu.items[i]
		if item then return item end
		item = CreateFrame("Button", nil, menu)
		item:SetHeight(MENU_ITEM_H)
		item:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -(4 + (i - 1) * MENU_ITEM_H))
		item:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
		-- A swatch entry previews the texture as a filled bar (a tinted ARTWORK texture, so
		-- the label OVERLAY and the auto HIGHLIGHT still layer over it on the same button).
		if spec.swatches then
			local sw = item:CreateTexture(nil, "ARTWORK")
			sw:SetPoint("TOPLEFT", 1, -1); sw:SetPoint("BOTTOMRIGHT", -1, 1)
			sw:SetVertexColor(0.2, 0.8, 0.2)
			item.swatch = sw
		end
		local ifs = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		ifs:SetPoint("LEFT", item, "LEFT", 4, 0)
		item.label = ifs
		local hl = item:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(item); hl:SetTexture(0.3, 0.3, 0.8, 0.5)
		item:SetScript("OnClick", function()
			menu:Hide()
			if spec.onSelect then spec.onSelect(this.value) end
			if spec.get then b.setValue(this.value) end
		end)
		if tips or tipLines then
			item:SetScript("OnEnter", function()
				GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
				if tipLines then
					local lines = tipLines(this.value) or {}
					for i = 1, table.getn(lines) do GameTooltip:AddLine(lines[i]) end
				else
					GameTooltip:AddLine(tips[this.value] or "")
				end
				GameTooltip:Show()
			end)
			item:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		menu.items[i] = item
		return item
	end

	local function buildItems(vals)
		local n = table.getn(vals)
		for i = 1, n do
			local item = menuItem(i)
			item.value = vals[i]
			item.label:SetText(labels[vals[i]] or vals[i])
			if item.swatch then
				if spec.swatches[vals[i]] then
					item.swatch:SetTexture(spec.swatches[vals[i]]); item.swatch:Show()
				else
					item.swatch:Hide()
				end
			end
			item:Show()
		end
		for i = n + 1, table.getn(menu.items) do menu.items[i]:Hide() end
		menu:SetHeight(n * MENU_ITEM_H + 8)
	end
	if type(values) ~= "function" then buildItems(values) end

	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		if tips and this.value then
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(tips[this.value] or "")
			GameTooltip:AddLine("Click to change", 0.5, 0.5, 0.5)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide() end)
	b:SetScript("OnClick", function()
		if menu:IsShown() then
			menu:Hide()
			return
		end
		-- Don't pop an empty menu (e.g. the Mail panel's profile drop before a character
		-- is picked, or a character drop with no other tracked characters yet) -- there's
		-- nothing to select, so it would just be a dead dropdown.
		local vals = (type(values) == "function") and values() or values
		if not vals or table.getn(vals) == 0 then return end
		if type(values) == "function" then buildItems(vals) end
		menu:Show()
	end)

	if spec.get then b.setValue(spec.get()) end
	return b
end

-- ---------------------------------------------------------------------------
-- Reusable modal popups: name prompt, confirm, big text dialog
-- ---------------------------------------------------------------------------
-- One lazy instance each, floated on FULLSCREEN_DIALOG so they draw above the
-- panel and its scroll regions (StaticPopup lives on the panel's own DIALOG
-- strata and would z-fight it).

local function modalShell(width, height)
	local p = CreateFrame("Frame", nil, getglobal("Quartermaster_Config") or UIParent)
	p:SetWidth(width); p:SetHeight(height)
	p:SetBackdrop(PANEL_BACKDROP)
	p:SetBackdropColor(0, 0, 0, 1)
	p:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
	p:SetFrameStrata("FULLSCREEN_DIALOG")
	p:SetToplevel(true)
	p:EnableMouse(true)   -- swallow clicks so they do not fall through
	p:SetPoint("CENTER", 0, 40)
	p:Hide()
	registerFloater(p)

	-- The DialogBox backdrop texture is itself semi-translucent; a solid black fill
	-- inside the border makes the popup fully opaque.
	local solid = p:CreateTexture(nil, "BACKGROUND")
	solid:SetPoint("TOPLEFT", 5, -5)
	solid:SetPoint("BOTTOMRIGHT", -5, 5)
	solid:SetTexture(0, 0, 0, 1)

	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetPoint("RIGHT", p, "RIGHT", -30, 0)
	title:SetJustifyH("LEFT")
	title:SetTextColor(1, 0.82, 0)
	p.title = title

	local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
	close:SetWidth(26); close:SetHeight(26)
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function() p:Hide() end)

	local err = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	err:SetJustifyH("LEFT")
	err:SetTextColor(1, 0.3, 0.3)
	p.err = err
	return p
end

-- Prompt for one line of text. onCommit(text) -> ok, err: on ok the popup closes,
-- otherwise err is shown and it stays open for another attempt.
local promptFrame
function QM.Config.promptText(titleText, initial, onCommit)
	if not promptFrame then
		local p = modalShell(300, 92)
		promptFrame = p
		-- No onCommit here (and OnEnterPressed set explicitly below): this is a one-shot
		-- OK/Cancel action, not a persistent field, so closing it any other way (the X,
		-- or the panel closing under it) must discard rather than auto-commit on blur.
		p.box = QM.Config.editbox(p, 200)
		p.box:SetScript("OnEnterPressed", function() p.commit(this:GetText()); this:ClearFocus() end)
		p.box:SetPoint("TOPLEFT", 12, -32)
		local ok = QM.Config.button(p, "OK", function() p.commit(p.box:GetText()) end)
		ok:SetWidth(60)
		ok:SetPoint("LEFT", p.box, "RIGHT", 8, 0)
		p.err:SetPoint("TOPLEFT", p.box, "BOTTOMLEFT", 0, -4)
		p.err:SetPoint("RIGHT", p, "RIGHT", -12, 0)
	end
	promptFrame.commit = function(text)
		local ok, err = onCommit(text)
		if ok then promptFrame:Hide() else promptFrame.err:SetText(err or "") end
	end
	promptFrame.title:SetText(titleText or "")
	promptFrame.err:SetText("")
	promptFrame.box:SetText(initial or "")
	promptFrame:Show()
	promptFrame.box:SetFocus()
	promptFrame.box:HighlightText()
end

-- Accept/Cancel confirmation; onAccept runs on Accept.
local confirmFrame
function QM.Config.confirm(message, onAccept)
	if not confirmFrame then
		local p = modalShell(300, 100)
		confirmFrame = p
		local msg = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		msg:SetPoint("TOPLEFT", 12, -30)
		msg:SetPoint("RIGHT", p, "RIGHT", -12, 0)
		msg:SetJustifyH("LEFT")
		p.msg = msg
		local yes = QM.Config.button(p, "Accept", function()
			p:Hide()
			if p.onAccept then p.onAccept() end
		end)
		yes:SetWidth(80)
		yes:SetPoint("BOTTOMLEFT", 12, 12)
		local no = QM.Config.button(p, "Cancel", function() p:Hide() end)
		no:SetWidth(80)
		no:SetPoint("LEFT", yes, "RIGHT", 8, 0)
	end
	confirmFrame.title:SetText("Confirm")
	confirmFrame.msg:SetText(message or "")
	confirmFrame.onAccept = onAccept
	confirmFrame:Show()
end

-- Big multiline text dialog for export/import strings. spec:
--   title, hint     -- header + grey helper line
--   text            -- prefilled content ("show" mode: selected for Ctrl+C)
--   buttonText      -- action button label (defaults: Close / Import)
--   onCommit(text)  -- "input" mode: -> ok, err; ok closes, err shows and stays open.
--                      Omit onCommit for "show" mode (the action button just closes).
local textFrame
function QM.Config.textDialog(spec)
	if not textFrame then
		local p = modalShell(440, 260)
		textFrame = p
		local hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", 12, -28)
		hint:SetPoint("RIGHT", p, "RIGHT", -12, 0)
		hint:SetJustifyH("LEFT")
		hint:SetTextColor(0.7, 0.7, 0.7)
		p.hint = hint

		-- backdrop behind the scroll area so the box reads as an input (created before
		-- the scroll frame so it draws underneath)
		local boxBg = CreateFrame("Frame", nil, p)
		boxBg:SetBackdrop(EDITBOX_BACKDROP)
		boxBg:SetBackdropColor(0, 0, 0, 0.7)
		boxBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
		boxBg:SetPoint("TOPLEFT", 12, -44)
		boxBg:SetPoint("BOTTOMRIGHT", -12, 44)
		boxBg:EnableMouse(true)

		local scroll = CreateFrame("ScrollFrame", "QuartermasterTextDialogScroll", p, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", boxBg, "TOPLEFT", 6, -6)
		scroll:SetPoint("BOTTOMRIGHT", boxBg, "BOTTOMRIGHT", -8, 6)

		-- Fixed oversized height + hidden scrollbar is the working 1.12 idiom for a
		-- multiline box in this template (the box auto-scrolls to keep the cursor visible).
		local box = CreateFrame("EditBox", nil, scroll)
		box:SetWidth(390)
		box:SetHeight(10000)
		box:SetMultiLine(true)
		box:SetAutoFocus(false)
		box:SetFontObject(GameFontHighlightSmall)
		box:SetScript("OnEscapePressed", function() this:ClearFocus() end)
		box:SetScript("OnTextChanged", function() scroll:UpdateScrollChildRect() end)
		-- in show mode a stray click must not cost the selection
		box:SetScript("OnEditFocusGained", function() if p.selectAll then this:HighlightText() end end)
		scroll:SetScrollChild(box)
		p.box = box
		boxBg:SetScript("OnMouseDown", function() box:SetFocus() end)

		local scrollBar = getglobal("QuartermasterTextDialogScrollScrollBar")
		if scrollBar then
			scrollBar:Hide()
			scrollBar.Show = function() end
		end

		p.action = QM.Config.button(p, "", function() p.onAction() end)
		p.action:SetWidth(100)
		p.action:SetPoint("BOTTOMLEFT", 12, 12)
		p.err:SetPoint("LEFT", p.action, "RIGHT", 8, 0)
		p.err:SetPoint("RIGHT", p, "RIGHT", -12, 0)
	end
	local p = textFrame
	p.title:SetText(spec.title or "")
	p.hint:SetText(spec.hint or "")
	p.err:SetText("")
	p.selectAll = not spec.onCommit
	p.box:SetText(spec.text or "")
	if spec.onCommit then
		p.action.label:SetText(spec.buttonText or "Import")
		p.onAction = function()
			local ok, err = spec.onCommit(p.box:GetText())
			if ok then p:Hide() else p.err:SetText(err or "") end
		end
	else
		p.action.label:SetText(spec.buttonText or "Close")
		p.onAction = function() p:Hide() end
	end
	p:Show()
	p.box:SetFocus()
	if p.selectAll then p.box:HighlightText() end
end

-- ---------------------------------------------------------------------------
-- Reusable list editor (FauxScrollFrame) -- add / reorder / remove + amount
-- ---------------------------------------------------------------------------

local ROW_H    = 20
local VISIBLE  = 11  -- rows shown at once (the list scrolls past this); the taller list still
                     -- fits above/within the (scrollable) page with the top controls + add row
local LIST_PAD = 4   -- inner padding of the bordered list container

-- Column geometry shared by the header labels and each row's controls, so the two
-- can never drift apart. Measured as RIGHT-edge offsets from the row's right edge.
local BTN_W   = 20   -- reorder / delete button width
local BTN_GAP = 2
local AMT_W   = 44   -- target / low edit-box width
local AMT_GAP = 6
local APPLY_W   = 46 -- apply-mode drop button width (consumables only)
local APPLY_GAP = 6
local RECIPIENT_W = APPLY_W * 2.5 -- mail-recipient drop button width (Transfer only) --
                                   -- wider than Use since it shows a character/custom name,
                                   -- not a short mode label; shares APPLY_GAP/the Use slot
local TRACK_W   = 44 -- track-axis drop button (Buff/CD/None)
local TRACK_GAP = 6
local GEAR_W    = 18 -- per-row gear opener for the buff/enchant tracking popup
local GEAR_GAP  = 3
local RESTOCK_W   = 18 -- vendor-restock toggle, right of Target
local RESTOCK_GAP = 4
local STATE_W   = 18 -- tristate enabled/hidden/off chip (leftmost column)
local STATE_GAP = 4

-- Row reorder/delete buttons, styled to match the edit boxes (dark tooltip backdrop)
-- since they sit right beside them. The glyph is an icon texture exposed as `b.icon`
-- so callers can recolour it (up/down are tinted green/grey per row by whether the
-- move is possible).
local function iconButton(parent, icon, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(BTN_W); b:SetHeight(18)
	styleFlatButton(b)

	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetWidth(11); t:SetHeight(11)
	t:SetPoint("CENTER", 0, 0)
	t:SetTexture(icon)
	b.icon = t

	-- hover brightens the border (only while enabled); press nudges the glyph
	b:SetScript("OnEnter", function() if this:IsEnabled() == 1 then this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1) end end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end)
	b:SetScript("OnMouseDown", function() this.icon:SetPoint("CENTER", 1, -1) end)
	b:SetScript("OnMouseUp", function() this.icon:SetPoint("CENTER", 0, 0) end)
	b:SetScript("OnClick", onClick)
	return b
end

-- Icon textures for the row controls. up/down are our own white arrows (recoloured per
-- row); delete is the group-loot X (confirmed present on the 1.12 client).
local TEX_DIR     = "Interface\\AddOns\\Quartermaster\\textures\\"
local ICON_UP     = TEX_DIR .. "up"
local ICON_DOWN   = TEX_DIR .. "down"
local ICON_CIRCLE = TEX_DIR .. "circle"   -- tristate state chip, tinted per state
local ICON_DELETE = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local ICON_GEAR   = "Interface\\Icons\\INV_Misc_Gear_01"   -- per-row track-config opener
local ICON_COIN   = "Interface\\Icons\\INV_Misc_Coin_01"   -- per-row vendor-restock toggle
local ICON_BAG    = "Interface\\Icons\\INV_Misc_Bag_08"    -- per-row bankable toggle (Transfer)

-- arrow tints: bright green when the row can move that way, grey when it can't
local MOVE_OK   = { 0.2, 0.9, 0.2 }
local MOVE_NONE = { 0.5, 0.5, 0.5 }

-- Use-mode drop button. Modes match Consumables.APPLY_* ("none"/"self"/"weapon"/"mh"/"oh"/
-- "target"); kept as literals here to avoid a load-order dependency. "weapon" means both
-- weapons; "mh"/"oh" narrow it to one hand. "none" is a stocked/reagent row with no direct
-- use. Vendor auto-restock is a SEPARATE per-row toggle (see restockButton), independent of
-- this mode -- an item can be both "self" and restocked.
local APPLY_ORDER = { "none", "self", "target", "weapon", "mh", "oh" }   -- menu order
local APPLY_LABEL = { none = "None", self = "Self", target = "Tgt", weapon = "Wpn", mh = "MH", oh = "OH" }
local APPLY_TIP   = {
	none   = "Not applied directly -- count only (a stocked reagent)",
	self   = "Used on yourself (potions, elixirs, flasks, food)",
	target = "Targeted items (scrolls, jujus) -- always cast on yourself",
	weapon = "Applied to both weapons (stones, oils, poisons)",
	mh     = "Applied to the main hand only",
	oh     = "Applied to the off hand only",
}

-- The in-row Use column is just the shared drop button (QM.Config.dropButton) at the
-- narrow APPLY_W width, with no get() -- the row repaints it per draw from the entry's
-- stored mode via b.setValue. Picking a mode calls onSelect(mode) (wired to QM.setApply).
local function applyButton(parent, onSelect)
	return QM.Config.dropButton(parent, {
		width = APPLY_W, height = 18,
		values = APPLY_ORDER, labels = APPLY_LABEL, tips = APPLY_TIP,
		onSelect = onSelect,
	})
end

-- Mail-recipient drop button (Transfer tab only). Unlike Use/Track the candidate list is
-- DYNAMIC (known characters + the manually managed custom list, see Transfer.lua's
-- QM.transferRecipients) and always includes a synthetic "(default)" entry mapping to a
-- nil row.mailRecipient (falls back to the character's own defaultMailRecipient). No
-- get() -- recycled rows repaint via b.setValue from the entry, like Use/Track.
local function recipientButton(parent, onSelect)
	return QM.Config.dropButton(parent, {
		width = RECIPIENT_W, height = 18,
		values = function()
			local v = { "(default)" }
			local r = QM.transferRecipients and QM.transferRecipients() or {}
			for i = 1, table.getn(r) do table.insert(v, r[i]) end
			return v
		end,
		onSelect = onSelect,
	})
end

-- Track-axis drop button (QM.TRACK_*). Unlike Use, it writes the ACCOUNT-WIDE item
-- record (QM.setItemTrack), not the per-row entry -- one source for every alt. No
-- get() (recycled rows repaint via b.setValue per draw from QM.itemTrack).
local TRACK_ORDER = { "buff", "cd", "food", "stock" }
local TRACK_LABEL = { buff = "Buff", cd = "CD", food = "Food", stock = "Stock" }
local TRACK_TIP   = {
	buff  = "Track the buff/enchant time left; falls back to the item cooldown when down",
	cd    = "Track the item's usability cooldown only (healing/mana pots)",
	food  = "Like Buff, plus a sit-and-eat progress bar before the Well Fed buff lands",
	stock = "Count only -- no timer, just the carried count vs target (reagents)",
}
local function trackButton(parent, onSelect)
	return QM.Config.dropButton(parent, {
		width = TRACK_W, height = 18,
		values = TRACK_ORDER, labels = TRACK_LABEL, tips = TRACK_TIP,
		onSelect = onSelect,
	})
end

-- Tiny gear opener (shown on Buff rows): opens the per-item tracking popup. The glyph is
-- tinted per the match-rule state (b.icon:SetVertexColor in the row refresh); b.tipExtra,
-- if set, adds a line (the live validation state) to its tooltip.
local function gearButton(parent, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(GEAR_W); b:SetHeight(18)
	styleFlatButton(b)
	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetWidth(14); t:SetHeight(14)
	t:SetPoint("CENTER", 0, 0)
	t:SetTexture(ICON_GEAR)
	t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.icon = t
	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Configure buff/enchant tracking")
		if this.tipExtra then local x = this.tipExtra(); if x then GameTooltip:AddLine(x) end end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide() end)
	b:SetScript("OnMouseDown", function() this.icon:SetPoint("CENTER", 1, -1) end)
	b:SetScript("OnMouseUp", function() this.icon:SetPoint("CENTER", 0, 0) end)
	b:SetScript("OnClick", onClick)
	return b
end

-- Vendor-restock toggle, right of Target: a coin glyph tinted gold when the entry buys up to
-- Target at a merchant that sells it, grey otherwise. Independent of the Use column -- an
-- item can be both used (self/weapon/target) AND restocked. b.on carries the current state
-- for the tooltip; the row refresh sets it and the tint each paint.
local RESTOCK_ON  = { 0.95, 0.82, 0.20 }
local RESTOCK_OFF = { 0.45, 0.45, 0.45 }
local function restockButton(parent, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(RESTOCK_W); b:SetHeight(18)
	styleFlatButton(b)
	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetWidth(13); t:SetHeight(13)
	t:SetPoint("CENTER", 0, 0)
	t:SetTexture(ICON_COIN)
	t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.icon = t
	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:AddLine(this.on and "Vendor-restock: ON" or "Vendor-restock: OFF")
		GameTooltip:AddLine("Buys up to Target from a merchant that sells it", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("Click to toggle", 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide() end)
	b:SetScript("OnMouseDown", function() this.icon:SetPoint("CENTER", 1, -1) end)
	b:SetScript("OnMouseUp", function() this.icon:SetPoint("CENTER", 0, 0) end)
	b:SetScript("OnClick", onClick)
	return b
end

-- Bankable toggle (Transfer tab only), the same right-of-Target slot restockButton uses on
-- the Tracker tab (the two never appear on the same list, so they share RESTOCK_W/GAP).
-- A bag glyph tinted green when the entry's excess (bag qty above Keep) is OK to bank on
-- /qm banksync, grey otherwise.
local BANKABLE_ON  = { 0.30, 0.85, 0.35 }
local BANKABLE_OFF = { 0.45, 0.45, 0.45 }
local function bankableButton(parent, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(RESTOCK_W); b:SetHeight(18)
	styleFlatButton(b)
	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetWidth(13); t:SetHeight(13)
	t:SetPoint("CENTER", 0, 0)
	t:SetTexture(ICON_BAG)
	t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.icon = t
	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:AddLine(this.on and "Bankable: ON" or "Bankable: OFF")
		GameTooltip:AddLine("OK to bank this item's excess on /qm banksync", 0.6, 0.6, 0.6)
		GameTooltip:AddLine("Click to toggle", 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide() end)
	b:SetScript("OnMouseDown", function() this.icon:SetPoint("CENTER", 1, -1) end)
	b:SetScript("OnMouseUp", function() this.icon:SetPoint("CENTER", 0, 0) end)
	b:SetScript("OnClick", onClick)
	return b
end

-- Tristate enabled/hidden/off chip (the leftmost column). Modes match QM.itemState's
-- "enabled"/"hidden"/"off": one circle icon tinted three ways (a traffic-light "level
-- of involvement").
local STATE_COLOR = {
	enabled = { 0.20, 0.80, 0.20 },   -- green: shown + counted
	hidden  = { 0.95, 0.75, 0.10 },   -- amber: counted but not shown
	off     = { 0.45, 0.45, 0.45 },   -- grey: ignored (kept in list)
}
local STATE_TIP = {
	enabled = "Enabled -- shown in the tracker and counted for restock",
	hidden  = "Hidden -- not shown in the tracker, still counted for restock",
	off     = "Off -- ignored everywhere (kept in the list)",
}

local function stateButton(parent, onCycle)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(STATE_W); b:SetHeight(STATE_W)
	styleFlatButton(b)
	local sw = b:CreateTexture(nil, "ARTWORK")
	sw:SetWidth(STATE_W - 6); sw:SetHeight(STATE_W - 6)
	sw:SetPoint("CENTER", 0, 0)
	sw:SetTexture(ICON_CIRCLE)   -- white circle, tinted per state via SetVertexColor
	b.swatch = sw
	b:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
		if this.state then
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(STATE_TIP[this.state] or "")
			GameTooltip:AddLine("Click to change", 0.5, 0.5, 0.5)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function() this:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); GameTooltip:Hide() end)
	b:SetScript("OnClick", onCycle)
	return b
end

-- Weapon-applied items track a temp-ENCHANT identity rather than a player buff.
local function isWeaponApply(apply)
	return apply == "weapon" or apply == "mh" or apply == "oh"
end

-- Human-readable account of the in-force match rule, so the status line can tell the user HOW
-- an effect is identified (which enchant id/name, or which buff).
local function describeMatch(m)
	if not m then return "nothing" end
	if m.by == "enchantid"   then return "enchant id " .. tostring(m.value) end
	if m.by == "enchantname" then return "enchant name '" .. tostring(m.value) .. "'" end
	if m.by == "icon"        then return "the buff icon" end
	if m.by == "name"        then return "buff name '" .. tostring(m.value) .. "'" end
	if m.by == "id"          then return "buff id " .. tostring(m.value) end
	return "nothing"
end

-- The per-item buff/enchant tracking popup opened by a row's gear button (one instance
-- per list editor, re-bound to whichever item's gear was clicked). Every field edits the
-- ACCOUNT-WIDE items[id] record (QM.setItemMatch / setItemMaxDuration), so configuring an
-- item once works on every alt. The status line tracks validation (QM.itemMatchStatus):
-- the rule auto-confirms the moment its effect is seen in game (QM's passive validateTick).
local function buildGearPopup(parent)
	local p = CreateFrame("Frame", nil, parent)
	p:SetWidth(236); p:SetHeight(166)
	p:SetBackdrop(PANEL_BACKDROP)
	p:SetBackdropColor(0, 0, 0, 1)
	p:SetBackdropBorderColor(0.9, 0.8, 0.2, 1)
	p:SetFrameStrata("FULLSCREEN_DIALOG")
	p:SetToplevel(true)
	p:EnableMouse(true)   -- swallow clicks so they do not fall through to the rows
	p:Hide()
	registerFloater(p)

	-- The DialogBox backdrop texture is itself semi-translucent, so the list shows through.
	-- A solid black fill inside the border makes the popup fully opaque.
	local solid = p:CreateTexture(nil, "BACKGROUND")
	solid:SetPoint("TOPLEFT", 5, -5)
	solid:SetPoint("BOTTOMRIGHT", -5, 5)
	solid:SetTexture(0, 0, 0, 1)

	local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetPoint("RIGHT", p, "RIGHT", -30, 0)
	title:SetJustifyH("LEFT")
	title:SetTextColor(1, 0.82, 0)

	local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
	close:SetWidth(26); close:SetHeight(26)
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function() p:Hide() end)

	-- "Match by icon" stores match{ by="icon" } (the reliable native primitive), cleared
	-- when a name/id is typed instead. A buff-tracked item already matches its own icon by
	-- default, so this just makes that explicit / re-asserts it.
	local iconCheck = QM.Config.check(p, "Match by buff icon", 8, -30, function(on)
		local id = p.id; if not id then return end
		if on then
			local m = QM.itemMatchEffective(id, p.apply)
			local val = (m and m.by == "icon" and m.value) or QM.itemMeta(id).icon
			if not val then
				local _, _, _, _, _, _, _, _, tex = GetItemInfo("item:" .. id)
				val = tex
			end
			QM.setItemMatch(id, "icon", val)
			p.nameBox:SetText("")
		else
			QM.setItemMatch(id, nil)
		end
	end)
	p.iconCheck = iconCheck

	-- Weapon items (no buff icon to match) get a "learn from weapon" button in the icon check's
	-- place instead: the user puts the enchant on, then clicks to capture its identity off the
	-- equipped weapon. refreshFields shows exactly one of the two for the item's apply mode.
	local learnBtn = QM.Config.button(p, "Learn from weapon", function()
		local id = p.id; if not id then return end
		local r = QM.learnWeaponEnchantNow(id, p.apply)
		if not r then p.setStatus("no temp enchant on the weapon to learn") end
		p.refreshFields()
	end)
	learnBtn:SetWidth(150); learnBtn:SetPoint("TOPLEFT", 8, -30)
	learnBtn:Hide()
	p.learnBtn = learnBtn

	local nameLabel = p:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	nameLabel:SetPoint("TOPLEFT", 12, -58)
	local nameBox = QM.Config.editbox(p, 150, function(text)
		local id = p.id; if not id then return end
		text = QM.trim(text)
		if text == "" then QM.setItemMatch(id, nil); return end
		local num = tonumber(text)
		local by, value
		if isWeaponApply(p.apply) then
			if num and QM.caps.equippedItem then by, value = "enchantid", num
			else by, value = "enchantname", text end
		else
			if num and QM.caps.superwow then by, value = "id", num
			else by, value = "name", text end
		end
		local ok, err = QM.setItemMatch(id, by, value)
		if ok then iconCheck:SetChecked(false) else p.setStatus(err) end
	end)
	nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)
	p.nameBox = nameBox

	local durLabel = p:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	durLabel:SetText("Duration (sec, 0 = auto)")
	durLabel:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 0, -8)
	local durBox = QM.Config.editbox(p, 56, function(text)
		local n = tonumber(text)
		QM.setItemMaxDuration(p.id, (n and n > 0) and n or nil)
	end)
	durBox:SetPoint("TOPLEFT", durLabel, "BOTTOMLEFT", 0, -4)
	durBox:SetJustifyH("RIGHT")
	p.durBox = durBox

	-- Live validation state: the rule auto-confirms the moment the effect is seen in raid
	-- (no manual probe). Red = nothing to match on; yellow = configured but not yet seen;
	-- green = effect observed.
	local status = p:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	status:SetPoint("TOPLEFT", durBox, "BOTTOMLEFT", 0, -12)
	status:SetPoint("RIGHT", p, "RIGHT", -10, 0)
	status:SetJustifyH("LEFT")
	function p.setStatus(t) status:SetText(t or "") end

	-- Food only: the auto-learned eating aura + eat time, with a per-item reset. Reset clears
	-- just THIS food's learned eat data (eatMatch + eatTime); it re-learns on the next eat.
	local eatLabel = p:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	eatLabel:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -12)
	eatLabel:SetPoint("RIGHT", p, "RIGHT", -10, 0)
	eatLabel:SetJustifyH("LEFT")
	local eatReset = QM.Config.button(p, "Reset eat learning",
		function() if p.id then QM.resetItemEat(p.id) end end)
	eatReset:SetWidth(130)
	eatReset:SetPoint("TOPLEFT", eatLabel, "BOTTOMLEFT", 0, -4)

	-- Food only: show what's been learned (eating aura + eat time); toggle the section by track.
	function p.refreshEat()
		local id = p.id; if not id then return end
		local meta = QM.itemMeta(id)
		if meta.track ~= "food" then eatLabel:Hide(); eatReset:Hide(); return end
		local aura = meta.eatMatch and "|cff66ff66learned|r" or "|cffaaaaaaunknown|r"
		local time = meta.eatTime and QM.fmtTime(meta.eatTime) or "|cffaaaaaa--|r"
		eatLabel:SetText("Eating buff: " .. aura .. "   eat time: " .. time)
		eatLabel:Show(); eatReset:Show()
	end

	-- Just the validation indicator (red/yellow/green) + HOW the effect is identified (which
	-- enchant id/name, or buff). Kept separate so the live auto-confirm signal can repaint it
	-- WITHOUT rewriting the edit boxes under the user.
	function p.refreshStatus()
		local id = p.id; if not id then return end
		local eff = QM.itemMatchEffective(id, p.apply)
		local st = QM.itemMatchStatus(id, p.apply)
		if st == "validated" then
			status:SetTextColor(0.4, 0.9, 0.4); p.setStatus("validated -- " .. describeMatch(eff))
		elseif st == "pending" then
			status:SetTextColor(1, 0.82, 0)
			-- A weapon enchant with no identity yet is pending-until-learned; everything else
			-- pending has a rule we're waiting to see.
			if eff then p.setStatus("waiting to see " .. describeMatch(eff))
			else p.setStatus("waiting to learn -- apply it once, or click Learn / type a name/id") end
		else
			status:SetTextColor(1, 0.4, 0.4); p.setStatus("no match set -- enter a name or id")
		end
	end

	-- Repaint every field from the (account-wide) item record (on open / after an edit).
	function p.refreshFields()
		local id = p.id; if not id then return end
		local meta = QM.itemMeta(id)
		local eff = QM.itemMatchEffective(id, p.apply)
		iconCheck:SetChecked(eff and eff.by == "icon" and true or false)
		-- show only an explicit name/id value (a derived icon default isn't shown as text)
		local m = meta.match
		if m and (m.by == "name" or m.by == "id" or m.by == "enchantname" or m.by == "enchantid") then
			nameBox:SetText(tostring(m.value or ""))
		else
			nameBox:SetText("")
		end
		durBox:SetText(tostring(meta.maxDuration or 0))
		-- When left on auto, show what the tooltip parse inferred so the user can see/confirm it.
		local auto = not meta.maxDuration and QM.tooltipDuration(id)
		durLabel:SetText("Duration (sec, 0 = auto" .. (auto and (": " .. QM.fmtTime(auto)) or "") .. ")")
		-- self items match a player buff (icon-matchable); weapon items match a temp-enchant
		-- identity instead, so they swap the icon check for the "learn from weapon" button.
		if isWeaponApply(p.apply) then
			nameLabel:SetText("Enchant name" .. (QM.caps.equippedItem and " / id" or ""))
			iconCheck:Hide(); learnBtn:Show()
		else
			nameLabel:SetText("Buff name" .. (QM.caps.superwow and " / id" or ""))
			iconCheck:Show(); learnBtn:Hide()
		end
		p.refreshStatus()
		p.refreshEat()
		p:SetHeight((meta.track == "food") and 214 or 166)
	end

	function p.bindTo(id, apply)
		p.id = id; p.apply = apply or "self"
		title:SetText((GetItemInfo("item:" .. id)) or ("item " .. id))
		p.refreshFields()
	end

	-- Auto-confirm flips the indicator live while the popup is open; only the status, so
	-- a passive validation elsewhere can't wipe a name the user is mid-typing.
	QM.subscribe("ITEM_META_CHANGED", function() if p:IsShown() then p.refreshStatus(); p.refreshEat() end end)

	return p
end

-- Lua 5.0 caps a function at 32 upvalues (every chunk-level local a nested closure
-- references counts as one for listEditor too), and listEditor -- one giant function
-- nesting makeRow/paintItemRow/paintDividerRow/refresh/etc. -- sits right at that edge.
-- Bundling the row-widget factories and paint-time tint tables here costs ONE upvalue
-- each (Widgets/Tint) instead of one per function/table; add new ones here rather than
-- referencing a fresh chunk-level local from inside listEditor or its nested closures.
local Widgets = {
	icon = iconButton, gear = gearButton, track = trackButton, apply = applyButton,
	state = stateButton, restock = restockButton, gearPopup = buildGearPopup,
	bankable = bankableButton, recipient = recipientButton,
}
local Tint = {
	moveOk = MOVE_OK, moveNone = MOVE_NONE,
	state = STATE_COLOR,
	restockOn = RESTOCK_ON, restockOff = RESTOCK_OFF,
	bankableOn = BANKABLE_ON, bankableOff = BANKABLE_OFF,
}

function QM.Config.listEditor(parent, spec)
	local kind     = spec.kind
	local hasWarn  = spec.warnText and true or false    -- show the low/warn column?
	local hasApply = spec.applyText and true or false   -- show the Use column?
	local hasTrack = spec.trackText and true or false   -- show the Track column + gear?
	local hasRestock = spec.restock and true or false   -- show the vendor-restock toggle?
	-- Transfer-tab-only columns. Neither ever appears alongside its Tracker-tab counterpart
	-- (restock/apply) on the same list, so each shares that column's width/gap/offset slot
	-- rather than adding a new one.
	local hasBankable  = spec.bankable and true or false      -- show the bankable toggle?
	local hasRecipient = spec.recipientText and true or false -- show the mail-recipient column?

	-- Optional title on its own line, spanning the page width so it can never run under the
	-- amount-column header.
	local title
	if spec.title and spec.title ~= "" then
		title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", 4, -4)
		title:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
		title:SetJustifyH("LEFT")
		title:SetText(spec.title)
	end

	-- Bordered list container, so the list reads as a distinct box rather than floating on
	-- the panel background (FearWardHelper's player-list style). Its TOP is pinned last (below
	-- the top controls + add row); RIGHT/height are fixed here since dependants anchor to them.
	local listH = VISIBLE * ROW_H + LIST_PAD * 2
	local listBox = CreateFrame("Frame", nil, parent)
	listBox:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
	listBox:SetHeight(listH)
	listBox:SetBackdrop(EDITBOX_BACKDROP)
	listBox:SetBackdropColor(0, 0, 0, 0.5)
	listBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	-- Drop target over the whole list: dragging an item onto the box (not just the add
	-- row) adds it directly. An overlay carries the hint and captures the drop; it is
	-- shown ONLY while an item is on the cursor, so it never blocks normal row
	-- interaction (hover tooltips, the reorder/amount/Use controls) the rest of the time.
	local function addCursorItem()
		if not CursorHasItem() then return end
		local link = QM.Config._cursorLink
		if link then QM.addDesired(kind, link) end
		ClearCursor()
		QM.Config._cursorLink = nil
	end

	local dropZone = CreateFrame("Frame", nil, listBox)
	dropZone:SetAllPoints(listBox)
	dropZone:SetFrameLevel(listBox:GetFrameLevel() + 20)   -- above the rows
	dropZone:EnableMouse(true)
	dropZone:Hide()
	local dzBg = dropZone:CreateTexture(nil, "ARTWORK")
	dzBg:SetAllPoints(dropZone)
	dzBg:SetTexture(0, 0, 0, 0.45)                          -- dims the items, leaves them visible
	local dzHint = dropZone:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	dzHint:SetPoint("CENTER", 0, 0)
	dzHint:SetText("Drop item here to add")
	dzHint:SetTextColor(1, 0.82, 0)
	dropZone:SetScript("OnReceiveDrag", addCursorItem)
	dropZone:SetScript("OnMouseDown", function() if CursorHasItem() then addCursorItem() end end)

	-- Drag-to-reorder state, shared by every row's drag handle and the tracker below.
	-- `from` is the dragged entry's list index (captured at drag start); `before` is the
	-- live insertion boundary (1..n+1, as QM.reorderDesired expects) recomputed each frame
	-- so it tracks the cursor even as the list scrolls under it -- auto-scroll just changes
	-- the offset and this keeps resolving correctly. `trackDrag` is filled in once `scroll`
	-- exists (it reads the scroll offset + geometry).
	local drag = { active = false, from = nil, before = nil }
	local trackDrag
	local endDrag   -- forward decl; the OnUpdate release-poll below needs it before its definition

	-- No cursor-change event on 1.12, so poll: the box's OnUpdate only runs while the tab
	-- (hence the list) is visible, and the check is cheap. The same tick drives both the
	-- item-add overlay and the live drag-reorder indicator/ghost.
	listBox:SetScript("OnUpdate", function()
		if CursorHasItem() then
			if not dropZone:IsShown() then dropZone:Show() end
		elseif dropZone:IsShown() then
			dropZone:Hide()
		end
		if drag.active and trackDrag then
			trackDrag(arg1)   -- arg1 = elapsed, drives auto-scroll
			-- Safety net: OnDragStop doesn't fire when the release lands on a divider's label
			-- editbox (its mouse handling swallows the drag-stop), stranding the drag until a
			-- reload. Poll the button and finish the drop ourselves.
			if not IsMouseButtonDown("LeftButton") then endDrag() end
		end
	end)

	-- Column right-edge offsets (from the row's right edge) -- the single source of
	-- truth that both the headers below and makeRow's controls anchor against.
	local rowR     = -(LIST_PAD + 18) - 4               -- row right edge, vs listBox right
	local upLeft   = -2 * (BTN_W + BTN_GAP) - BTN_W     -- left edge of the ^ button
	-- Restock/Bankable toggle sits between Target and the reorder arrows, in its own fixed
	-- slot (the two never appear on the same list, so they share it).
	local restockRight = upLeft - RESTOCK_GAP                        -- restock/bankable button right edge
	-- Amount order (right -> left): Target is the rightmost amount, Low sits to its left.
	local targetRight = (hasRestock or hasBankable) and (restockRight - RESTOCK_W - AMT_GAP) or (upLeft - AMT_GAP)
	local lowRight    = targetRight - AMT_W - AMT_GAP                -- low box right edge
	local leftAmtRight = hasWarn and lowRight or targetRight         -- right edge of the leftmost amount column
	local leftAmtLeft  = leftAmtRight - AMT_W                        -- its left edge
	-- Track column + its gear opener sit just left of the leftmost amount (the gear hugs
	-- Track's right). Both hold a fixed slot whether or not a given row shows them.
	local gearRight  = leftAmtLeft - GEAR_GAP
	local trackRight = (gearRight - GEAR_W) - TRACK_GAP
	-- Use/Mail-recipient column sits to the LEFT of the Track cluster / amounts (eating into
	-- the name's space, not the amount boxes -- so those columns never shift whether or not
	-- it shows). The two never appear on the same list, so Recipient shares Use's slot.
	local applyAnchorLeft = hasTrack and (trackRight - TRACK_W) or leftAmtLeft
	local applyRight = applyAnchorLeft - APPLY_GAP
	-- column LEFT edges relative to listBox's TOPRIGHT corner, so each header
	-- left-aligns with the column below it
	local targetLeft = rowR + targetRight - AMT_W
	local lowLeft    = rowR + lowRight    - AMT_W
	local trackLeft  = rowR + trackRight  - TRACK_W
	-- Recipient is wider than Use (a name, not a short mode label) though the two share
	-- this slot's right edge/gap -- the header label still needs the right width to align.
	local applyLeft  = rowR + applyRight  - (hasRecipient and RECIPIENT_W or APPLY_W)

	-- Column headers, sitting just above the list and left-aligned over their columns.
	-- Item header anchors over where the row icon begins (past the leftmost state chip).
	local itemHdr = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	itemHdr:SetPoint("BOTTOMLEFT", listBox, "TOPLEFT", LIST_PAD + 2 + STATE_W + STATE_GAP, 2)
	itemHdr:SetText("Item")

	local targetHdr = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	targetHdr:SetPoint("BOTTOMLEFT", listBox, "TOPRIGHT", targetLeft, 2)
	targetHdr:SetText(spec.targetText or "Target")
	if hasWarn then
		local lowHdr = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		lowHdr:SetPoint("BOTTOMLEFT", listBox, "TOPRIGHT", lowLeft, 2)
		lowHdr:SetText(spec.warnText)
	end
	if hasApply then
		local applyHdr = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		applyHdr:SetPoint("BOTTOMLEFT", listBox, "TOPRIGHT", applyLeft, 2)
		applyHdr:SetText(spec.applyText)
	elseif hasRecipient then
		local recipientHdr = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		recipientHdr:SetPoint("BOTTOMLEFT", listBox, "TOPRIGHT", applyLeft, 2)
		recipientHdr:SetText(spec.recipientText)
	end
	if hasTrack then
		local trackHdr = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		trackHdr:SetPoint("BOTTOMLEFT", listBox, "TOPRIGHT", trackLeft, 2)
		trackHdr:SetText(spec.trackText)
	end

	-- One per-item tracking popup for the whole list (only when the Track column shows),
	-- re-bound to whichever row's gear was clicked. Parented to the PANEL, not the list: the
	-- rows live inside the list's own FauxScrollFrame, which CLIPS its content, so a popup
	-- parented under the list gets cut off at the viewport edge. Anchored to the gear button
	-- regardless of parent; registered as a floater (above) so a tab switch or panel close
	-- closes it despite that parenting.
	local gearPopup = hasTrack and Widgets.gearPopup(getglobal("Quartermaster_Config") or UIParent) or nil
	local function openGearPopup(row)
		if not (gearPopup and row.id) then return end
		if gearPopup:IsShown() and gearPopup.id == row.id then
			gearPopup:Hide(); return
		end
		gearPopup.bindTo(row.id, row.applyMode or "self")
		gearPopup:ClearAllPoints()
		gearPopup:SetPoint("TOPRIGHT", row.gear, "BOTTOMRIGHT", 4, -2)
		gearPopup:Show()
	end

	local scroll = CreateFrame("ScrollFrame", "QuartermasterCfgScroll_" .. kind, listBox, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", LIST_PAD, -LIST_PAD)
	scroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -(LIST_PAD + 18), LIST_PAD)

	local rows = {}
	local refresh  -- forward decl (the row buttons call it)

	-- ---- Drag-to-reorder: indicator, ghost, and the per-frame tracker -------------
	-- Insertion line drawn in the gap the dragged row will land in. It lives on its own
	-- frame stacked above the rows (and above the item-add dropZone) so it is never
	-- occluded; that frame stays mouse-transparent so the row drag handles below still get
	-- the cursor. Positioned in scroll coordinates (dragLayer mirrors the scroll rect), so
	-- a boundary index maps straight to a Y without caring which rows are currently drawn.
	local INDICATOR_H = 3
	local dragLayer = CreateFrame("Frame", nil, listBox)
	dragLayer:SetAllPoints(scroll)
	dragLayer:SetFrameLevel(listBox:GetFrameLevel() + 25)
	local indicator = dragLayer:CreateTexture(nil, "OVERLAY")
	indicator:SetHeight(INDICATOR_H)
	indicator:SetTexture(0.95, 0.82, 0.2, 0.95)   -- gold insertion line
	indicator:Hide()

	-- Floating representation of the dragged row, trailing the cursor on the TOOLTIP
	-- strata so it floats over everything. Mouse-disabled so it never eats the drop.
	local ghost = CreateFrame("Frame", nil, UIParent)
	ghost:SetFrameStrata("TOOLTIP")
	ghost:SetWidth(180); ghost:SetHeight(ROW_H)
	ghost:EnableMouse(false)
	ghost:SetBackdrop(EDITBOX_BACKDROP)
	ghost:SetBackdropColor(0, 0, 0, 0.85)
	ghost:SetBackdropBorderColor(0.9, 0.8, 0.2, 0.9)
	ghost:Hide()
	local gIcon = ghost:CreateTexture(nil, "OVERLAY")
	gIcon:SetWidth(16); gIcon:SetHeight(16)
	gIcon:SetPoint("LEFT", 5, 0)
	gIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local gName = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	gName:SetPoint("LEFT", gIcon, "RIGHT", 4, 0)
	gName:SetPoint("RIGHT", ghost, "RIGHT", -6, 0)
	gName:SetJustifyH("LEFT")

	-- Auto-scroll tuning: a cursor inside the EDGE band at either end of the list scrolls
	-- it, at a rate that ramps from MIN to MAX rows/sec as the cursor goes from the inner
	-- to the outer edge of the band (or past it). Fractional rows bank in `scrollAccum`
	-- between whole-row steps so the speed is frame-rate independent.
	local AUTOSCROLL_EDGE    = ROW_H
	local AUTOSCROLL_MIN_RPS = 4
	local AUTOSCROLL_MAX_RPS = 20
	local scrollAccum = 0

	-- Recompute, from the live cursor position, which gap the drop targets; auto-scroll a
	-- long list while the cursor sits at an edge; place the indicator and trail the ghost.
	-- Runs every OnUpdate tick while a drag is active; `elapsed` is the frame delta (nil on
	-- the initial call from beginDrag, which only needs to place the indicator).
	trackDrag = function(elapsed)
		local scale  = scroll:GetEffectiveScale()
		local top    = scroll:GetTop() or 0
		local bottom = scroll:GetBottom() or 0
		local _, cyraw = GetCursorPosition()
		local cy = cyraw / scale

		-- Auto-scroll: nudge the FauxScrollFrame's scrollbar while the cursor is in the edge
		-- band. Stepping the bar fires its OnVerticalScroll, which redraws and updates the
		-- offset synchronously -- so the gap math below already sees the new offset, and the
		-- clamped indicator appears to hold at the edge while rows stream past it.
		if elapsed and elapsed > 0 then
			local dir, intensity = 0, 0
			if cy > top - AUTOSCROLL_EDGE then
				dir = -1; intensity = (cy - (top - AUTOSCROLL_EDGE)) / AUTOSCROLL_EDGE
			elseif cy < bottom + AUTOSCROLL_EDGE then
				dir = 1;  intensity = ((bottom + AUTOSCROLL_EDGE) - cy) / AUTOSCROLL_EDGE
			end
			if dir == 0 then
				scrollAccum = 0
			else
				if intensity > 1 then intensity = 1 end
				local rps = AUTOSCROLL_MIN_RPS + (AUTOSCROLL_MAX_RPS - AUTOSCROLL_MIN_RPS) * intensity
				scrollAccum = scrollAccum + dir * rps * elapsed
				local steps = (scrollAccum >= 0) and math.floor(scrollAccum) or math.ceil(scrollAccum)
				if steps ~= 0 then
					scrollAccum = scrollAccum - steps
					local bar = getglobal("QuartermasterCfgScroll_" .. kind .. "ScrollBar")
					if bar then
						local v = bar:GetValue() + steps * ROW_H
						local lo, hi = bar:GetMinMaxValues()
						if v < lo then v = lo elseif v > hi then v = hi end
						bar:SetValue(v)   -- triggers the scroll + refresh
					end
				end
			end
		end

		-- Gap index p in [0,count] from the (now-current) offset; cursor Y already in scroll
		-- coordinates (raw screen pixels / the frame's effective scale, the 1.12 idiom).
		local list = QM.desiredList(kind) or {}
		local n = table.getn(list)
		local offset = FauxScrollFrame_GetOffset(scroll)
		local count = n - offset
		if count > VISIBLE then count = VISIBLE end   -- gaps available in the drawn window

		local p = math.floor((top - cy) / ROW_H + 0.5)
		if p < 0 then p = 0 elseif p > count then p = count end

		-- p gaps below the top of the window == before original index offset+p+1.
		drag.before = offset + p + 1

		indicator:ClearAllPoints()
		indicator:SetPoint("TOPLEFT", dragLayer, "TOPLEFT", 0, -p * ROW_H + 1)
		indicator:SetPoint("TOPRIGHT", dragLayer, "TOPRIGHT", -4, -p * ROW_H + 1)
		indicator:Show()

		local gscale = ghost:GetEffectiveScale()
		local cx, gcy = GetCursorPosition()
		ghost:ClearAllPoints()
		ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / gscale + 14, gcy / gscale + 8)
	end

	-- A row's name/icon zone (its `hover` frame) starts a drag; release applies it. The
	-- dragged index is captured from the row at start; `before` is whatever trackDrag last
	-- resolved. Both are cleared so a stray release can't reorder.
	local function beginDrag(row)
		if not row.index then return end
		drag.active = true
		drag.from   = row.index
		drag.before = row.index
		scrollAccum = 0
		GameTooltip:Hide()
		if row.isDivider then
			gIcon:Hide()
			local lbl = row.divLabel:GetText()
			gName:SetText((lbl ~= "" and lbl) or "Separator")
		else
			gIcon:Show(); gIcon:SetTexture(row.icon:GetTexture())
			gName:SetText(row.name:GetText())
		end
		ghost:Show()
		trackDrag()
	end

	endDrag = function()
		if not drag.active then return end
		drag.active = false
		scrollAccum = 0
		indicator:Hide()
		ghost:Hide()
		if drag.from and drag.before then
			QM.reorderDesired(kind, drag.from, drag.before)
		end
		drag.from, drag.before = nil, nil
	end

	local function makeRow(i)
		local row = CreateFrame("Frame", nil, listBox)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * ROW_H)
		row:SetPoint("RIGHT", scroll, "RIGHT", -4, 0)

		row.del = Widgets.icon(row, ICON_DELETE, function() QM.removeDesired(kind, row.index) end)
		row.del:SetPoint("RIGHT", 0, 0)
		row.down = Widgets.icon(row, ICON_DOWN, function() QM.moveDesired(kind, row.index, 1) end)
		row.down:SetPoint("RIGHT", row.del, "LEFT", -BTN_GAP, 0)
		row.up = Widgets.icon(row, ICON_UP, function() QM.moveDesired(kind, row.index, -1) end)
		row.up:SetPoint("RIGHT", row.down, "LEFT", -BTN_GAP, 0)

		-- Restock toggle, right of Target, then Target (rightmost amount), then Low to its
		-- left, so the visual order is name | [Use] | low | target | [$] | ^ v X -- matching
		-- the headers above (the optional Use column is built just left of the leftmost
		-- amount, below).
		local targetAnchor = row.up
		if hasRestock then
			row.restock = Widgets.restock(row, function() QM.setRestock(kind, row.index) end)
			row.restock:SetPoint("RIGHT", row.up, "LEFT", -RESTOCK_GAP, 0)
			targetAnchor = row.restock
		elseif hasBankable then
			row.bankable = Widgets.bankable(row, function() QM.setBankable(kind, row.index) end)
			row.bankable:SetPoint("RIGHT", row.up, "LEFT", -RESTOCK_GAP, 0)
			targetAnchor = row.bankable
		end

		row.target = QM.Config.editbox(row, AMT_W, function(text) QM.setTarget(kind, row.index, text) end)
		row.target:SetPoint("RIGHT", targetAnchor, "LEFT", -AMT_GAP, 0)
		row.target:SetJustifyH("RIGHT")

		local leftOfAmounts = row.target
		if hasWarn then
			row.low = QM.Config.editbox(row, AMT_W, function(text) QM.setLow(kind, row.index, text) end)
			row.low:SetPoint("RIGHT", row.target, "LEFT", -AMT_GAP, 0)
			row.low:SetJustifyH("RIGHT")
			leftOfAmounts = row.low
		end

		local nameRight = leftOfAmounts

		-- Track column + gear opener (left of the amounts). Track writes the ACCOUNT-WIDE
		-- item record (QM.setItemTrack by row.id, read live so it survives row recycling),
		-- unlike Use which writes the per-row entry; the gear opens the per-item popup and
		-- is only shown on Buff rows (toggled in refresh).
		if hasTrack then
			row.gear = Widgets.gear(row, function() openGearPopup(row) end)
			row.gear:SetPoint("RIGHT", leftOfAmounts, "LEFT", -GEAR_GAP, 0)
			row.gear.tipExtra = function()
				local t = row.id and QM.itemTrack(row.id)
				if not (t == "buff" or t == "food") then return nil end
				local ms = QM.itemMatchStatus(row.id, row.applyMode)
				if ms == "validated" then return "|cff66ff66Validated|r: effect seen in game"
				elseif ms == "pending"  then return "|cffffd000Pending|r: waiting to see the buff" end
				return "|cffff6060No match set|r: enter a buff name or icon"
			end
			row.track = Widgets.track(row, function(t)
				if row.id then QM.setItemTrack(row.id, t) end
			end)
			row.track:SetPoint("RIGHT", row.gear, "LEFT", -TRACK_GAP, 0)
			nameRight = row.track
		end

		-- Use column, left of the Track cluster. The drop button picks the stored mode
		-- through QM.setApply; row.index is read live in the closure so it stays correct as
		-- rows are recycled by the FauxScrollFrame.
		if hasApply then
			row.apply = Widgets.apply(row, function(mode)
				QM.setApply(kind, row.index, mode)
			end)
			row.apply:SetPoint("RIGHT", nameRight, "LEFT", -APPLY_GAP, 0)
			nameRight = row.apply
		elseif hasRecipient then
			row.recipient = Widgets.recipient(row, function(v)
				QM.setMailRecipient(kind, row.index, v == "(default)" and nil or v)
			end)
			row.recipient:SetPoint("RIGHT", nameRight, "LEFT", -APPLY_GAP, 0)
			nameRight = row.recipient
		end

		-- Tristate state chip (leftmost column): cycles enabled -> hidden -> off.
		row.state = Widgets.state(row, function() QM.cycleState(kind, row.index) end)
		row.state:SetPoint("LEFT", 2, 0)

		-- Item icon (right of the state chip), then the name filling whatever width is left
		-- of the Use/amount columns, so it grows with the (resizable) panel instead of clipping.
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetWidth(16); row.icon:SetHeight(16)
		row.icon:SetPoint("LEFT", row.state, "RIGHT", STATE_GAP, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the default icon border

		row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", nameRight, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")

		-- Tooltip + drag handle over the icon+name zone (from the row's left up to the Want
		-- box), so hovering the amount boxes / reorder buttons / the gaps between them shows
		-- nothing and they stay independently clickable. A dedicated mouse frame captures just
		-- that region. The same zone is the drag-to-reorder handle: grabbing the name and
		-- dragging starts a reorder (the arrow buttons remain the single-step path). The
		-- tooltip is suppressed while a drag is in flight so hovering other rows mid-drag is
		-- quiet.
		local hover = CreateFrame("Frame", nil, row)
		hover:SetPoint("TOPLEFT", row, "TOPLEFT", STATE_W + 6, 0)   -- start past the state chip so it stays clickable
		hover:SetPoint("BOTTOMRIGHT", nameRight, "BOTTOMLEFT", -2, 0)
		hover:EnableMouse(true)
		hover:RegisterForDrag("LeftButton")
		hover:SetScript("OnEnter", function()
			if drag.active or not row.id then return end
			GameTooltip:SetOwner(hover, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink("item:" .. row.id .. ":0:0:0")
			GameTooltip:AddLine("Item ID: " .. row.id, 0.5, 0.5, 0.5)
			GameTooltip:Show()
		end)
		hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
		hover:SetScript("OnDragStart", function() beginDrag(row) end)
		hover:SetScript("OnDragStop", function() endDrag() end)
		row.hover = hover

		-- Divider rows reuse this row: a label editbox spanning the item icon+name column, shown
		-- by refresh in place of the icon/name + Use/Track/amount controls. The box itself is the
		-- drag-to-reorder handle (a plain click still focuses it for typing); the arrow buttons
		-- remain the single-step path. Hidden by default.
		row.divLabel = QM.Config.editbox(row, 100, function(text) QM.setDividerLabel(kind, row.index, text) end)
		row.divLabel:SetPoint("LEFT", row.state, "RIGHT", STATE_GAP, 0)
		row.divLabel:SetPoint("RIGHT", nameRight, "LEFT", -6, 0)   -- only the item icon+name column wide
		row.divLabel:RegisterForDrag("LeftButton")
		row.divLabel:SetScript("OnDragStart", function() this:ClearFocus(); beginDrag(row) end)
		row.divLabel:SetScript("OnDragStop", function() endDrag() end)
		row.divLabel:Hide()

		rows[i] = row
		return row
	end

	-- Shared row bits (state chip tint, reorder-arrow enable) -- both an item row and a
	-- divider row carry the state chip + up/down/delete, so they share these.
	local function paintState(row, e)
		local st = QM.itemState(e)
		row.state.state = st
		local sc = Tint.state[st] or Tint.state.enabled
		row.state.swatch:SetVertexColor(sc[1], sc[2], sc[3])
		return st
	end
	local function paintArrows(row, di, n)
		local canUp, canDown = di > 1, di < n
		local up   = canUp   and Tint.moveOk or Tint.moveNone
		local down = canDown and Tint.moveOk or Tint.moveNone
		row.up.icon:SetVertexColor(up[1], up[2], up[3])
		row.down.icon:SetVertexColor(down[1], down[2], down[3])
		if canUp then row.up:Enable() else row.up:Disable(); row.up:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end
		if canDown then row.down:Enable() else row.down:Disable(); row.down:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end
	end

	local function paintItemRow(row, e, di, n)
		row.id = e.id
		row.isDivider = false
		row.divLabel:Hide()
		row.icon:Show(); row.name:Show(); row.hover:Show(); row.target:Show()
		if row.low then row.low:Show() end
		if row.apply then row.apply:Show() end
		if row.recipient then row.recipient:Show() end
		if row.track then row.track:Show() end
		if row.restock then row.restock:Show() end
		if row.bankable then row.bankable:Show() end
		-- Re-derive name/icon/quality from the cache every draw (cheap on a cached item):
		-- backfills rows added before the client had the item, and self-heals stale values.
		-- Texture is the 9th return on this 1.12 client, not the 10th.
		if e.id then
			local nm, _, q, _, _, _, _, _, ic = GetItemInfo("item:" .. e.id)
			if nm then e.name = nm end
			if q then e.quality = q end
			if ic then e.icon = ic end
		end
		row.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		row.name:SetText(e.name or ("item " .. (e.id or "?")))
		-- State chip colour, and dim the row to match its level of involvement.
		local st = paintState(row, e)
		if st == "off" then
			row.name:SetTextColor(0.5, 0.5, 0.5); row.icon:SetAlpha(0.4)
		elseif st == "hidden" then
			row.name:SetTextColor(0.75, 0.75, 0.75); row.icon:SetAlpha(0.7)
		else
			row.name:SetTextColor(1, 1, 1); row.icon:SetAlpha(1)
		end
		-- Skip repainting a box the user is still typing in -- a refresh triggered by some
		-- other row/control (e.g. the restock toggle) would otherwise clobber an uncommitted
		-- edit with the last-saved value before OnEditFocusLost ever runs.
		if row.target ~= QM.Config._focusedEditBox then
			row.target:SetText(tostring(e.target or 0))
		end
		if row.low and row.low ~= QM.Config._focusedEditBox then
			row.low:SetText(tostring(e.low or 0))
		end
		if row.apply then row.apply.setValue(e.apply or "none") end
		if row.recipient then row.recipient.setValue(e.mailRecipient or "(default)") end
		-- Track is item-intrinsic (account-wide); the gear opens only for Buff items and
		-- its glyph carries the match-rule state: red = nothing to match on, yellow =
		-- configured but not yet seen in game, green = validated.
		row.applyMode = e.apply or "none"
		if row.track then row.track.setValue(QM.itemTrack(e.id) or "stock") end
		if row.gear then
			local gt = QM.itemTrack(e.id)
			if gt == "buff" or gt == "food" then
				row.gear:Show()
				local ms = QM.itemMatchStatus(e.id, e.apply or "none")
				if ms == "none" then row.gear.icon:SetVertexColor(1, 0.25, 0.25)
				elseif ms == "pending" then row.gear.icon:SetVertexColor(1, 0.82, 0)
				else row.gear.icon:SetVertexColor(0.3, 1, 0.3) end
			else
				row.gear:Hide()
			end
		end
		if row.restock then
			row.restock.on = e.restock and true or false
			row.restock.icon:SetDesaturated(not row.restock.on)   -- flat grey when off, not just a dark tint
			local c = row.restock.on and Tint.restockOn or Tint.restockOff
			row.restock.icon:SetVertexColor(c[1], c[2], c[3])
		end
		if row.bankable then
			row.bankable.on = e.bankable and true or false
			row.bankable.icon:SetDesaturated(not row.bankable.on)
			local c = row.bankable.on and Tint.bankableOn or Tint.bankableOff
			row.bankable.icon:SetVertexColor(c[1], c[2], c[3])
		end
		paintArrows(row, di, n)
	end

	-- A divider row: the label editbox in place of the item controls, plus the shared state
	-- chip + reorder/delete. The label tints by state (header gold when enabled, dimmer when
	-- hidden/off) to echo how it will read in the HUD.
	local function paintDividerRow(row, e, di, n)
		row.id = nil
		row.isDivider = true
		row.icon:Hide(); row.name:Hide(); row.hover:Hide(); row.target:Hide()
		if row.low then row.low:Hide() end
		if row.apply then row.apply:Hide() end
		if row.recipient then row.recipient:Hide() end
		if row.track then row.track:Hide() end
		if row.gear then row.gear:Hide() end
		if row.restock then row.restock:Hide() end
		if row.bankable then row.bankable:Hide() end
		row.divLabel:Show()
		if row.divLabel ~= QM.Config._focusedEditBox then
			row.divLabel:SetText(e.label or "")
		end
		local st = paintState(row, e)
		if st == "off" then row.divLabel:SetTextColor(0.5, 0.5, 0.5)
		elseif st == "hidden" then row.divLabel:SetTextColor(0.7, 0.7, 0.7)
		else row.divLabel:SetTextColor(1, 0.82, 0) end
		paintArrows(row, di, n)
	end

	refresh = function()
		local list = QM.desiredList(kind) or {}
		local n = table.getn(list)
		FauxScrollFrame_Update(scroll, n, VISIBLE, ROW_H)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for i = 1, VISIBLE do
			local row = rows[i] or makeRow(i)
			local di = i + offset
			if di <= n then
				local e = list[di]
				row.index = di
				if QM.isDivider(e) then paintDividerRow(row, e, di, n)
				else paintItemRow(row, e, di, n) end
				row:Show()
			else
				row:Hide()
			end
		end
	end

	scroll:SetScript("OnVerticalScroll", function()
		-- Rows recycle to different items as the list scrolls, so a popup pinned to one is
		-- no longer over its item -- close it.
		if gearPopup and gearPopup:IsShown() then gearPopup:Hide() end
		FauxScrollFrame_OnVerticalScroll(ROW_H, refresh)
	end)

	-- Mouse-wheel scrolls the list (the bar is otherwise the only way).
	local function wheel()
		local bar = getglobal("QuartermasterCfgScroll_" .. kind .. "ScrollBar")
		if bar then bar:SetValue(bar:GetValue() - arg1 * ROW_H) end
	end
	scroll:EnableMouseWheel(true);  scroll:SetScript("OnMouseWheel", wheel)
	listBox:EnableMouseWheel(true); listBox:SetScript("OnMouseWheel", wheel)

	-- Top controls: the caller's option header (if any), then the add row, then the list.
	-- The header hook anchors its widgets below `title` (or the page top when there's none)
	-- and returns its bottom-most widget so the add row stacks beneath it.
	local headerBottom = spec.header and spec.header(parent, title) or nil

	-- add row, stacked above the list (below the option header)
	local addLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	local addTop = headerBottom or title
	if addTop then addLabel:SetPoint("TOPLEFT", addTop, "BOTTOMLEFT", 0, -12)
	else addLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4) end
	addLabel:SetText("Add item:")

	local ADD_BTN_W, ADD_GAP, SEP_W = 50, 6, 96
	local addBox = QM.Config.editbox(parent, 200)
	local addBtn = QM.Config.button(parent, "Add")
	addBtn:SetWidth(ADD_BTN_W)

	-- The box stretches from the list's left edge to within the buttons' width of the page's
	-- right edge; the Add (and, when present, the Separator, and any afterAddRow widget) then
	-- hang off it in turn, landing flush with the list's right. The box's right anchors to the
	-- PAGE, not the list: the list's TOP now hangs off the add row, so a box<->list anchor would
	-- be a cycle (the page inset matches the list's own -4 right inset, so the edges still line up).
	local boxRightInset = ADD_BTN_W + ADD_GAP
	if spec.dividers then boxRightInset = boxRightInset + SEP_W + ADD_GAP end
	if spec.afterAddRowWidth then boxRightInset = boxRightInset + spec.afterAddRowWidth end
	addBox:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 0, -4)
	addBox:SetPoint("RIGHT", parent, "RIGHT", -(4 + boxRightInset), 0)
	addBtn:SetPoint("LEFT", addBox, "RIGHT", ADD_GAP, 0)  -- single anchor: centers on the box

	-- "+ Separator": inserts a divider for grouping the list, on the same row as the add box.
	-- Any text typed in the box (the literal string, not the autocomplete ghost) seeds the
	-- new divider's category name and is consumed.
	local sepBtn
	if spec.dividers then
		sepBtn = QM.Config.button(parent, "+ Separator", function()
			local label = QM.trim(addBox:GetText())
			QM.addDivider(kind, label)
			if label ~= "" then addBox:SetText(""); addBox:ClearFocus() end
		end)
		sepBtn:SetWidth(SEP_W)
		sepBtn:SetPoint("LEFT", addBtn, "RIGHT", ADD_GAP, 0)
	end

	-- Extra controls inline with the add row, hanging off its rightmost button (the
	-- separator button when present, else Add itself) -- e.g. Tracker's Row order drop.
	if spec.afterAddRow then spec.afterAddRow(parent, sepBtn or addBtn) end

	-- Inline aux-style completion. `ghost` is a greyed FontString drawn right after what
	-- you've typed, showing the current match's remaining (lowercase) letters -- it is NOT
	-- part of the edit box text, so typing and deleting behave normally (the reason aux
	-- only completes on Tab; the ghost sidesteps that entirely). `measure` is an invisible
	-- FontString in the box's font used only to size the typed text so the ghost lands at
	-- the caret. Tab cycles the candidates; Enter / Add takes the shown one and stores it
	-- by its proper (capitalized) name.
	local TEXT_INSET = 5   -- mirrors editbox()'s SetTextInsets left inset
	local ghost = addBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ghost:SetTextColor(0.5, 0.5, 0.5)
	ghost:SetJustifyH("LEFT")
	local measure = addBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	measure:SetPoint("LEFT", addBox, "LEFT", TEXT_INSET, 0)
	measure:SetAlpha(0)   -- invisible, but laid out so GetStringWidth is accurate

	local matches, matchIdx = {}, 1

	-- proper-case display name for an indexed (lowercase) match
	local function displayName(m)
		local id = m and QM.resolveName and QM.resolveName(m)
		return (id and GetItemInfo("item:" .. id)) or m
	end

	local function showGhost()
		local m = matches[matchIdx]
		local typed = addBox:GetText()
		if not m or typed == "" then ghost:SetText(""); return end
		measure:SetText(typed)
		ghost:ClearAllPoints()
		ghost:SetPoint("LEFT", addBox, "LEFT", TEXT_INSET + measure:GetStringWidth(), 0)
		ghost:SetPoint("RIGHT", addBox, "RIGHT", -TEXT_INSET, 0)
		ghost:SetText(string.sub(m, string.len(typed) + 1))   -- the tail Tab/Enter will add
	end

	local function commit()
		local m = matches[matchIdx]
		if m then
			local id = QM.resolveName and QM.resolveName(m)
			QM.addDesired(kind, id and tostring(id) or m)
		else
			QM.addDesired(kind, addBox:GetText())  -- an ID, or exact text
		end
		addBox:SetText(""); addBox:ClearFocus()
	end

	addBox:SetScript("OnTextChanged", function()
		matches = (QM.matchNames and QM.matchNames(this:GetText(), 50)) or {}
		matchIdx = 1
		showGhost()
	end)
	addBox:SetScript("OnTabPressed", function()
		local n = table.getn(matches)
		if n == 0 then return end
		if n == 1 then
			this:SetText(displayName(matches[1]))   -- only one: finish it (capitalized)
			return
		end
		matchIdx = math.mod(matchIdx, n) + 1         -- otherwise cycle the candidates
		showGhost()
	end)
	addBox:SetScript("OnEnterPressed", function() commit() end)
	addBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	addBox:SetScript("OnEditFocusGained", function() QM.Config._linkSink = this end)
	addBox:SetScript("OnEditFocusLost", function()
		if QM.Config._linkSink == this then QM.Config._linkSink = nil end
		ghost:SetText("")
	end)

	-- Drag an item from the bags and drop it on the box (or click the box while holding
	-- one) to fill it -- the item's link is captured at pickup (see QM.Config.dropCursorItem).
	addBox:EnableMouse(true)
	addBox:SetScript("OnReceiveDrag", function() QM.Config.dropCursorItem(this) end)
	addBox:SetScript("OnMouseDown", function() if CursorHasItem() then QM.Config.dropCursorItem(this) end end)
	addBtn:SetScript("OnClick", commit)

	-- Pin the list below the add row now that it exists, leaving HEADER_ROOM above the box
	-- for the column headers (which anchor to the list's top edge).
	local HEADER_ROOM = 20
	listBox:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", 0, -HEADER_ROOM)

	-- Optional controls below the (fixed-height) list, e.g. Transfer's mail action row --
	-- the counterpart of `header` above the add row.
	if spec.footer then spec.footer(parent, listBox) end

	QM.subscribe("DESIRED_CHANGED", refresh)
	QM.subscribe("CONFIG_SHOWN", refresh)
	QM.subscribe("ITEM_META_CHANGED", refresh)   -- repaint Track face + gear visibility
	refresh()
end

-- A vertical scroll region filling `page`, returning a fixed-height content frame
-- to lay widgets into. Lets a tab's controls exceed the (resizable, possibly
-- shrunk) panel height without clipping -- the whole element area scrolls. `name`
-- is needed so the scroll bar has a global handle for mouse-wheel forwarding;
-- `contentH` is the child's fixed height; its width tracks the scroll frame so
-- nothing runs off the side.
function QM.Config.scrollChild(page, name, contentH)
	local sf = CreateFrame("ScrollFrame", name, page, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 0, 0)
	sf:SetPoint("BOTTOMRIGHT", -26, 0)   -- leave room for the scroll bar

	local child = CreateFrame("Frame", nil, sf)
	child:SetWidth(280); child:SetHeight(contentH or 320)
	sf:SetScrollChild(child)

	-- GetWidth() is unreliable on this client for a frame sized purely by two opposing
	-- anchor points (unlike an explicitly SetWidth()'d frame, e.g. the panel itself) --
	-- it can under-report the frame's true rendered size. GetLeft()/GetRight() read the
	-- actual resolved edges and are accurate, so derive the width from those instead.
	local function fit()
		local l, r = sf:GetLeft(), sf:GetRight()
		if l and r and r > l then child:SetWidth(r - l) end
	end
	sf:SetScript("OnSizeChanged", fit); fit()

	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function()
		local bar = getglobal(name .. "ScrollBar")
		if bar then bar:SetValue(bar:GetValue() - arg1 * 20) end
	end)
	return child
end

-- ---------------------------------------------------------------------------
-- Panel + tab strip
-- ---------------------------------------------------------------------------

local panel
local contentBox          -- bordered region holding the active tab's controls
local tabButtons = {}
local pages = {}
local activeTab

-- The tab strip runs along the top. Buttons flow left -> right and wrap onto further
-- rows when they run out of panel width, so the strip is as tall as it needs to be --
-- recomputed on every resize by layoutTabs(), which also drops the content box below
-- the last row.
local TAB_X     = 12      -- tab strip left/right inset
local TAB_TOP   = -40     -- y of the first tab row (below the title)
local TAB_W     = 108     -- tab button width
local TAB_H     = 22      -- tab button height
local TAB_GAP_X = 4       -- horizontal gap between tabs in a row
local TAB_GAP_Y = 4       -- vertical gap between wrapped tab rows
local MIN_W = 660         -- panel minimum size (keeps the controls usable; wide enough for most item names beside the state + Use + Track columns, and the Tracker tab's 3-column notify row)
local MIN_H = 550         -- tall enough that the list editor's add row + footer never clip (the Tracker tab has no outer scrollbar, so its content must fit unscrolled)

-- Flow the tab buttons across the top, wrapping onto extra rows when the panel is too
-- narrow to hold them all in one line, then anchor the content box just below the last
-- row. Called on build and on every resize, so the strip reflows and the content box
-- gives back the rows' worth of height as the panel widens.
local function layoutTabs()
	if not panel or not contentBox then return end
	local n = table.getn(tabButtons)
	if n == 0 then return end

	-- How many tabs fit on one row at the current width (at least one).
	local avail = panel:GetWidth() - TAB_X * 2
	local perRow = math.floor((avail + TAB_GAP_X) / (TAB_W + TAB_GAP_X))
	if perRow < 1 then perRow = 1 end

	local rows = 1
	for i = 1, n do
		local col    = math.mod(i - 1, perRow)
		local rowIdx = math.floor((i - 1) / perRow)
		rows = rowIdx + 1
		tabButtons[i]:ClearAllPoints()
		tabButtons[i]:SetPoint("TOPLEFT", panel, "TOPLEFT",
			TAB_X + col * (TAB_W + TAB_GAP_X),
			TAB_TOP - rowIdx * (TAB_H + TAB_GAP_Y))
	end

	-- Content box starts below the last tab row (with a little breathing room) and
	-- fills to the panel's bottom-right.
	local stripBottom = TAB_TOP - rows * (TAB_H + TAB_GAP_Y) - 4
	contentBox:ClearAllPoints()
	contentBox:SetPoint("TOPLEFT", panel, "TOPLEFT", TAB_X, stripBottom)
	contentBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -12, 30)
end

local function sortedTabs()
	local t = {}
	for i = 1, table.getn(QM.configTabs) do t[i] = QM.configTabs[i] end
	table.sort(t, function(a, b) return (a.order or 100) < (b.order or 100) end)
	return t
end

local function selectTab(i)
	local tabs = QM.Config._tabs
	if not tabs or not tabs[i] then return end
	activeTab = i
	closeFloaters()
	for j = 1, table.getn(pages) do if pages[j] then pages[j]:Hide() end end
	if not pages[i] then
		-- Pages live INSIDE the bordered content box (so they sit in the box, not on
		-- the bare panel) and fill it; the box grows with the panel, so do they.
		local pg = CreateFrame("Frame", nil, contentBox)
		pg:SetPoint("TOPLEFT", contentBox, "TOPLEFT", 6, -6)
		pg:SetPoint("BOTTOMRIGHT", contentBox, "BOTTOMRIGHT", -6, 6)
		pages[i] = pg
		if tabs[i].build then tabs[i].build(pg) end
	end
	pages[i]:Show()
	for j = 1, table.getn(tabButtons) do
		if tabButtons[j] then tabButtons[j].setSelected(j == i) end
	end
end
QM.Config.selectTab = selectTab

local function build()
	if panel then return end
	local cfg = (QM.db and QM.db.frames.config) or {}
	panel = CreateFrame("Frame", "Quartermaster_Config", UIParent)
	-- Clamp up to the minimum so a size saved before the min was raised still loads usable.
	panel:SetWidth(math.max(cfg.width or 620, MIN_W)); panel:SetHeight(math.max(cfg.height or 500, MIN_H))
	panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	panel:SetFrameStrata("DIALOG")
	panel:SetBackdrop(PANEL_BACKDROP)
	panel:SetBackdropColor(0, 0, 0, 0.92)
	panel:SetMovable(true); panel:SetResizable(true); panel:EnableMouse(true)
	panel:SetMinResize(MIN_W, MIN_H)
	panel:SetMaxResize(1000, 800)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function() panel:StartMoving() end)
	panel:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
	-- Force-commit a still-focused edit box (e.g. Target/Low) when the panel is closed
	-- without pressing Enter or tabbing away first -- see QM.Config.editbox.
	panel:SetScript("OnHide", function()
		if QM.Config._focusedEditBox then QM.Config._focusedEditBox:ClearFocus() end
	end)

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14); title:SetText("Quartermaster")

	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Reflow the top tab strip (and reposition the content box below it) as the width
	-- changes, so wider panels collapse the strip to fewer rows and reclaim the height.
	panel:SetScript("OnSizeChanged", layoutTabs)

	-- Bordered content box BELOW the (wrapping) top tab strip. Its top border is the
	-- visual separator between the tabs and the active tab's controls, and the border +
	-- fill tell the controls apart from the bare panel background. layoutTabs() anchors
	-- it just under the last tab row and to the panel's right/bottom, so it -- and the
	-- pages inside it -- grow on resize while the strip reflows above it.
	contentBox = CreateFrame("Frame", nil, panel)
	contentBox:SetBackdrop(EDITBOX_BACKDROP)
	contentBox:SetBackdropColor(0, 0, 0, 0.4)
	contentBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)

	QM.Config._tabs = sortedTabs()
	for i = 1, table.getn(QM.Config._tabs) do
		local idx = i
		local b = QM.Config.toggleButton(panel, QM.Config._tabs[i].name, function() selectTab(idx) end)
		b:SetWidth(TAB_W); b:SetHeight(TAB_H)
		tabButtons[i] = b
	end
	layoutTabs()   -- position the strip + content box for the initial width

	-- Bottom-right resize grip: drags the panel's width AND height (the tab strip is
	-- pinned TOPLEFT at a fixed width, so only the content box stretches). Size is
	-- clamped by SetMinResize/SetMaxResize and persisted on release.
	local grip = CreateFrame("Button", nil, panel)
	grip:SetWidth(16); grip:SetHeight(16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\AddOns\\Quartermaster\\textures\\ResizeGrip")
	grip:SetHighlightTexture("Interface\\AddOns\\Quartermaster\\textures\\ResizeGrip", "ADD")
	grip:SetScript("OnMouseDown", function() panel:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		panel:StopMovingOrSizing()
		if QM.db then
			QM.db.frames.config.width  = panel:GetWidth()
			QM.db.frames.config.height = panel:GetHeight()
		end
	end)

	panel:Hide()
end

function QM.toggleConfig()
	build()
	if panel:IsShown() then
		closeFloaters()
		panel:Hide()
	else
		panel:Show()
		selectTab(activeTab or 1)
		QM.fire("CONFIG_SHOWN")
	end
end
