-- Left side of the window: project filter and the grouped thread list.

local _, ns = ...
local UI = ns.UI

local L = {}
ns.ThreadList = L

local LIST_W_DEFAULT = 280

local GROUPS = {
	{ key = "open", label = "Open" },
	{ key = "working", label = "Working" },
	{ key = "snoozed", label = "Snoozed" },
	{ key = "settled", label = "Settled" },
}

-- The modern window's dots in the theme's own colors, by token.
local DOT_TOKENS = { working = "blue", waiting = "muted", input = "orange", plan = "orange", failed = "red", unread = "blue" }

local DOT_COLORS = {
	working = { 0.29, 0.62, 1 },
	waiting = { 0.55, 0.6, 0.7 },
	input = { 1, 0.6, 0.2 },
	plan = { 1, 0.6, 0.2 },
	failed = { 1, 0.25, 0.25 },
	unread = { 0.29, 0.62, 1 },
}

-- A row's title has the status words beside it; with wrapping off, text wider
-- than the box is drawn anyway, under those words. Cut it to fit instead.
local function TrimTo(fs, text, maxW)
	fs:SetText(text)
	if (fs:GetStringWidth() or 0) <= maxW or maxW <= 0 then return text end
	-- Where each character starts, so a cut never lands inside one.
	local starts = {}
	for i = 1, #text do
		local c = text:byte(i)
		if c < 0x80 or c >= 0xC0 then starts[#starts + 1] = i end
	end
	local function Prefix(n) return text:sub(1, (starts[n + 1] or #text + 1) - 1) end
	-- The longest run of whole characters that fits with the ellipsis; at least one.
	local lo, hi = 1, #starts - 1
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		fs:SetText(Prefix(mid) .. "…")
		if (fs:GetStringWidth() or 0) <= maxW then lo = mid else hi = mid - 1 end
	end
	text = Prefix(math.max(1, lo)) .. "…"
	fs:SetText(text)
	return text
end
L.TrimTo = TrimTo

local function InitHeader(button, ed)
	UI.InitGroupHeader(button)
	UI.SetGroupHeader(button, ed.label, ed.count, ed.collapsed)
	button:SetScript("OnClick", function()
		local c = ns.db.settings.collapsed
		c[ed.key] = not c[ed.key]
		PlaySound(c[ed.key] and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		L:Refresh(true)
	end)
end

local function CreateRow(button)
	button:SetHeight(46)
	button:RegisterForClicks("LeftButtonUp")

	local theme = ns.Theme.Get()
	local hover = button:CreateTexture(nil, "HIGHLIGHT")
	if theme then
		ns.Theme.Paint(hover, theme.hover)
	else
		hover:SetAtlas("Options_List_Hover")
		hover:SetAlpha(0.5)
	end
	hover:SetAllPoints()

	local sel = button:CreateTexture(nil, "BACKGROUND")
	if theme then
		-- The chosen thread: a quiet wash, with the accent down its left edge.
		ns.Theme.Paint(sel, theme.selected)
		local bar = button:CreateTexture(nil, "ARTWORK")
		ns.Theme.Paint(bar, theme.accent)
		bar:SetWidth(2)
		bar:SetPoint("TOPLEFT", -2, 2)
		bar:SetPoint("BOTTOMLEFT", -2, -2)
		button.AccentBar = bar
	else
		sel:SetAtlas("PetList-ButtonSelect")
	end
	sel:SetPoint("TOPLEFT", -2, 2)
	sel:SetPoint("BOTTOMRIGHT", 2, -2)
	button.Selected = sel

	local dot = button:CreateTexture(nil, "ARTWORK")
	dot:SetTexture("Interface\\Buttons\\WHITE8X8")
	dot:SetSize(7, 7)
	dot:SetPoint("TOPLEFT", 6, -12)
	dot:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
	button.Dot = dot

	-- GameFontNormal is the game's gold. In the modern window a thread title is the
	-- foreground, and the accent is reserved for the selected row.
	local title = button:CreateFontString(nil, "ARTWORK", theme and "T3ModernBody" or "GameFontNormal")
	title:SetPoint("TOPLEFT", 18, -7)
	title:SetPoint("RIGHT", -74, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)
	button.Title = title

	local status = button:CreateFontString(nil, "ARTWORK", ns.UI.Font("GameFontHighlightSmall"))
	status:SetPoint("TOPRIGHT", -6, -8)
	status:SetJustifyH("RIGHT")
	button.Status = status

	local sub = button:CreateFontString(nil, "ARTWORK", ns.UI.Font("GameFontDisableSmall"))
	sub:SetPoint("BOTTOMLEFT", 18, 8)
	sub:SetPoint("RIGHT", -60, 0)
	sub:SetJustifyH("LEFT")
	sub:SetWordWrap(false)
	button.Sub = sub

	local age = button:CreateFontString(nil, "ARTWORK", ns.UI.Font("GameFontDisableSmall"))
	age:SetPoint("BOTTOMRIGHT", -6, 8)
	age:SetJustifyH("RIGHT")
	button.Age = age

	button:SetScript("OnEnter", function(self)
		local t = self.thread
		if not t then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(t.title, 1, 0.82, 0, 1, true)
		GameTooltip:AddLine(ns.Store:ProjectName(t.p), 0.7, 0.7, 0.7)
		GameTooltip:AddLine(t.l or ns.Store.StatusText(t.s), 1, 1, 1, true)
		if t.br then GameTooltip:AddLine("Branch: " .. t.br, 0.6, 0.8, 1) end
		if t.m then
			local label = t.mi and ns.Store:ModelLabel(ns.Store.EnvOf(t.id), ns.Store.ModelKey(t.mi, t.m)) or t.m
			GameTooltip:AddLine(label, 0.6, 0.6, 0.6)
		end
		if t.last then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(t.last, 0.9, 0.9, 0.9, true)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	button.created = true
end

local function InitRow(button, ed)
	if not button.created then CreateRow(button) end
	local t = ed.thread
	button.thread = t
	local selected = t.id == ns.viewId and ns.Main.mode ~= "new"
	button.Selected:SetShown(selected)
	if button.AccentBar then button.AccentBar:SetShown(selected) end
	local theme = ns.Theme.Get()
	-- The selected thread is bold, the kit's one change of weight; set the face
	-- before measuring the title against the row.
	if theme then button.Title:SetFontObject(selected and "T3ModernBodyBold" or "T3ModernBody") end
	button.Title:SetText(t.title)
	local rowW = button:GetWidth() or 0
	TrimTo(button.Title, t.title, rowW - 18 - 78)
	if theme then
		local ink = selected and theme.accent or ((t.s == "settled" or t.s == "snoozed") and theme.muted or theme.text)
		ns.Theme.SetText(button.Title, ink)
	elseif t.s == "settled" or t.s == "snoozed" then
		button.Title:SetTextColor(0.75, 0.75, 0.75)
	else
		button.Title:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
	end
	local color = DOT_COLORS[t.s] or (t.un and DOT_COLORS.unread)
	if theme and color then color = theme[DOT_TOKENS[t.s] or "blue"] end
	button.Dot:SetShown(color ~= nil)
	if color then button.Dot:SetVertexColor(color[1], color[2], color[3]) end
	button.Status:SetText(ns.Color(ns.Store.StatusColor(t.s), ns.Store.StatusText(t.s)))
	local sub = ns.Store:ProjectName(t.p)
	if t.s == "working" or t.s == "input" or t.s == "waiting" then sub = t.l or sub end
	TrimTo(button.Sub, sub, rowW - 18 - 64)
	if (t.s == "working" or t.s == "waiting") and t.st then
		button.Age:SetText(ns.Duration(time() - t.st))
	elseif t.s == "snoozed" then
		button.Age:SetText(ns.Until(t.w))
	else
		button.Age:SetText(ns.Ago(t.u))
	end
	button:SetScript("OnClick", function()
		PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		ns.Main:SelectThread(t.id)
	end)
end

function L:Create(parent)
	local dd = UI.Dropdown(parent, LIST_W_DEFAULT, function(value)
		ns.db.settings.project = value
		L:Refresh(true)
		ns.Main:Refresh()
	end)
	dd:SetPoint("TOPLEFT", 8, -8)
	dd:SetPoint("TOPRIGHT", -10, -8)
	self.dropdown = dd

	local search = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
	search:SetHeight(20)
	search:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 6, -6)
	search:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", -2, -6)
	search:SetAutoFocus(false)
	local theme = ns.Theme.Get()
	if theme then
		-- A flat well over the template's art; its magnifier stays on top.
		local well = ns.Theme.Solid(search, theme.panel, "ARTWORK")
		well:SetAllPoints()
		ns.Theme.Edges(search, theme.controlBorder)
		ns.UI.UseLineSearch(search)
	end
	search:HookScript("OnTextChanged", function(box)
		L.query = strtrim(box:GetText() or ""):lower()
		L:Refresh(true)
	end)
	self.search = search

	local scrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", 4, -70)
	scrollBox:SetPoint("BOTTOMRIGHT", -18, 4)
	local scrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

	local view = CreateScrollBoxListLinearView(2, 2, 2, 2, 2)
	view:SetElementFactory(function(factory, ed)
		if ed.header then
			factory("T3CodeGroupHeaderTemplate", InitHeader)
		elseif ed.empty then
			factory("T3CodeEmptyRowTemplate", function(frame)
				if not frame.Text then
					frame.Text = frame:CreateFontString(nil, "ARTWORK", ns.UI.Font("GameFontDisable"))
					frame.Text:SetPoint("LEFT", 18, 0)
					frame.Text:SetPoint("RIGHT", -8, 0)
					frame.Text:SetJustifyH("LEFT")
				end
				frame.Text:SetText(ed.empty)
			end)
		else
			factory("T3CodeThreadRowTemplate", InitRow)
		end
	end)
	view:SetElementExtentCalculator(function(_, ed)
		if ed.header then return 28 end
		if ed.empty then return 24 end
		return 46
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	ns.UI.StyleScrollBar(scrollBar)
	self.scrollBox, self.scrollBar, self.view = scrollBox, scrollBar, view
end

-- Drop the list's frames: the window is being rebuilt under another design.
function L:Teardown()
	self.dropdown, self.search, self.scrollBox, self.scrollBar, self.view, self.key = nil, nil, nil, nil, nil, nil
end

function L:SetupDropdown()
	local options = { { value = "all", label = "All projects" } }
	-- With more than one machine, filters per machine come first.
	local machines = ns.Store.data.bridge and ns.Store.data.bridge.envs
	if machines then
		for _, e in ipairs(machines) do
			table.insert(options, { value = "m:" .. (e["local"] and "local" or e.label), label = "Everything on " .. e.label })
		end
	end
	for _, p in ipairs(ns.Store.data.projects) do
		if p.act then table.insert(options, { value = p.id, label = p.name }) end
	end
	self.dropdown:SetOptions(options, ns.db.settings.project)
end

function L:Refresh(force)
	if not self.scrollBox then return end
	local s = ns.db.settings
	-- Settings saved before there was a Snoozed group: start it folded, like Settled.
	if s.collapsed.snoozed == nil then s.collapsed.snoozed = true end
	if s.project ~= "all" and not s.project:find("^m:") and not ns.Store.projectsById[s.project] and ns.Store.applied > 0 then s.project = "all" end
	local key = table.concat({
		ns.Store.listKey or "", s.project, tostring(s.collapsed.working), tostring(s.collapsed.open),
		tostring(s.collapsed.snoozed), tostring(s.collapsed.settled), tostring(ns.viewId), ns.Main.mode, self.query or "",
	}, ":")
	if key == self.key and not force then
		-- Only timers changed: refresh the visible rows in place.
		self.scrollBox:ForEachFrame(function(frame, ed)
			if ed.thread then InitRow(frame, ed) end
		end)
		return
	end
	self.key = key
	self:SetupDropdown()

	local groups = ns.Store:Groups(s.project, self.query)
	local dp = CreateDataProvider()
	for _, g in ipairs(GROUPS) do
		local list = groups[g.key]
		local collapsed = s.collapsed[g.key]
		if #list > 0 or (g.key ~= "settled" and g.key ~= "snoozed") then
			dp:Insert({ header = true, key = g.key, label = g.label, count = #list, collapsed = collapsed })
			if not collapsed then
				for _, t in ipairs(list) do dp:Insert({ thread = t }) end
				if #list == 0 then
					dp:Insert({ empty = g.key == "working" and "Nothing running" or "Nothing here" })
				end
			end
		end
	end
	if ns.Store.applied == 0 then
		dp:Insert({ empty = "Waiting for the bridge…" })
	elseif (ns.Store.data.older or 0) > 0 and not s.collapsed.settled then
		dp:Insert({ empty = string.format("+%d older settled threads in T3 Code", ns.Store.data.older) })
	end
	self.scrollBox:SetDataProvider(dp, ScrollBoxConstants.RetainScrollPosition)
	ns:Fire("ListRebuilt")
end
