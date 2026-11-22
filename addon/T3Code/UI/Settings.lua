-- Settings tab (also reachable from the game's Options > AddOns list).
-- The modern look is a section list on the left,
-- and on the right a title, a one-line explanation, and each setting as a name,
-- a description, and a control at the right edge.

local _, ns = ...
local UI = ns.UI
local Theme = ns.Theme

local S = {}
ns.Settings = S

local function AccentChoices()
	local options = {}
	for _, a in ipairs(Theme.Accents()) do
		table.insert(options, { value = a.value, label = a.label })
	end
	return options
end

-- Each choice rebuilds the window, so picking the one already set does nothing.
local function ChooseDesign(value)
	if value == (ns.db.settings.theme or "classic") then return end
	ns.db.settings.theme = value
	ns.Main:ApplyTheme()
end

local function ChoosePalette(value)
	if value == ns.db.settings.palette then return end
	ns.db.settings.palette = value
	if ns.db.settings.theme == "modern" then ns.Main:ApplyTheme() end
end

local function ChooseAccent(value)
	if value == (ns.db.settings.accent or "class") then return end
	ns.db.settings.accent = value
	if ns.db.settings.theme == "modern" then ns.Main:ApplyTheme() end
end

local function ClearText(value)
	if not value or value <= 0 then return "Solid" end
	return value .. "%"
end

local function ChooseClear(value)
	ns.db.settings.windowClear = value
	if ns.db.settings.theme == "modern" then ns.Main:ApplyOpacity() end
end


local CHECKS = {
	{ section = "tracker", key = "tracker", label = "Show T3 Code in the tracker area", title = "Show in the tracker area", desc = "Lists what's running, what needs you, and what just finished.", after = function() ns.Tracker:Refresh() end },
	{ section = "tracker", key = "trackerAlways", label = "Keep its header when nothing is running", title = "Keep the header when idle", desc = "Leaves the section in place between threads.", after = function() ns.Tracker:Refresh() end },
	{ section = "tracker", key = "trackerLocked", label = "Lock the tracker in place", title = "Lock the tracker in place", desc = "The section stays where you put it. Click its header to open the window.", after = function() ns.Tracker:Refresh() end },
	{ section = "notices", key = "toasts", label = "Pop up a notice when a thread finishes or needs you", title = "Pop up a notice", desc = "When a thread finishes or needs you." },
	{ section = "notices", key = "sounds", label = "Play a sound with notices", title = "Play a sound", desc = "A short sound along with the notice." },
	{ section = "notices", key = "quietInstances", label = "Stay quiet in dungeons, raids and PvP", title = "Stay quiet in dungeons, raids and PvP", desc = "Notices and read-aloud wait until you're out. They always wait during combat.", tip = "Notices and read-aloud wait until you're out. They always wait during combat.", after = function() ns.Transport:Touch() end },
	{ section = "voice", key = "autoRead", label = "Read finished replies aloud", title = "Read finished replies aloud", desc = "Speak the reply when a thread finishes.", after = function() ns.Transport:Touch() end },
	{ section = "threads", key = "steerFollowUps", label = "Steer a working thread with follow-ups", title = "Steer a working thread", desc = "A message sent while a thread is working goes into its current run.", tip = "A message to a thread that's still working goes into its current run, as in T3 Code. Turn this off to queue it until the run finishes.", after = function() ns.Main:Refresh() end },
	{ section = "threads", key = "newWorktree", label = "Start new threads in a worktree", title = "Start new threads in a worktree", desc = "Each new thread gets its own git branch and checkout, named after the task.", tip = "Each new thread gets its own git branch and checkout, so it can't collide with the project folder. T3 Code names the branch after the task." },
	{ section = "threads", key = "subagentRows", label = "List running subagents on their own", title = "List running subagents on their own", desc = "Off: a subagent stays under its parent, which shows Waiting, unless it needs you.", tip = "A running subagent gets its own row in the thread list and tracker. Turn this off to leave it under the thread that started it, which shows Waiting until it's done. A subagent that needs your answer or approval is listed either way.", after = function() ns.ThreadList:Refresh(true); ns.Tracker:Refresh(); ns.MinimapButton:Refresh() end },
	{ section = "voice", key = "dictateSend", label = "Send dictated messages right away", title = "Send dictated messages right away", desc = "A finished dictation is sent as soon as you stop talking." },
	{ section = "threads", key = "quickReplies", label = "Show quick replies under finished threads", title = "Show quick replies", desc = "Suggested replies under a thread that just finished.", after = function() ns.Transcript:Refresh(true) end },
	{ section = "window", key = "gameMenu", label = "Add T3 Code to the game menu", title = "Add T3 Code to the game menu", desc = "An entry beside the other menu buttons." },
	{ section = "window", key = "minimapButton", label = "Show the minimap button", title = "Show the minimap button", desc = "Drag the button to move it around the minimap.", after = function() ns.MinimapButton:Refresh() end },
}

local SECTIONS = {
	{ id = "notices", label = "Notices", title = "Notices", blurb = "Popups, sounds, and when they stay quiet." },
	{ id = "tracker", label = "Tracker", title = "Tracker", blurb = "The T3 Code section under your quests." },
	{ id = "threads", label = "Threads", title = "Threads", blurb = "What a message does, where a new thread starts, and what the list shows." },
	{ id = "voice", label = "Voice", title = "Voice", blurb = "Reading replies aloud, and dictation." },
	{ id = "window", label = "Window", title = "Window", blurb = "Where the window shows up, and which design it uses." },
	{ id = "modern", label = "Modern", title = "Modern", blurb = "Omarchy's themes, the accent, and transparency." },
	{ id = "connection", label = "Connection", title = "Connection", blurb = "The link between the game and T3 Code." },
}

local SECTION_BY = {}
for _, s in ipairs(SECTIONS) do SECTION_BY[s.id] = s end

local VOICES = {
	{ "auto", "Automatic" },
	{ "system", "Desktop voice (via the bridge)" },
	{ "game", "Game voice" },
	{ "off", "Off" },
}

local NAV_W = 180

function S:Create(page)
	self.page = page
	if Theme.Get() then self:CreateModern(page) else self:CreateClassic(page) end
end

-- The game's own look, laid out like the game's option panels: two columns of gold
-- section headings, each checkbox with its label beside it, and the dropdowns lined
-- up under one another. The page is 554 tall at the default size, and the buttons
-- along the bottom start 516 down, so both columns end above that.
local CLASSIC_COLUMNS = {
	{ x = 16, width = 440, sections = { "notices", "tracker", "threads" } },
	{ x = 470, width = 420, sections = { "voice", "window" } },
}
local CLASSIC_ROW, CLASSIC_HEADING, CLASSIC_GAP, CLASSIC_CHOICE, CLASSIC_LABEL_W = 27, 22, 12, 30, 96

function S:CreateClassic(page)
	local title = UI.Text(page, "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 20, -16)
	title:SetText("Settings")

	self.checks = {}
	local extras = {}

	local function Heading(col, id)
		local h = UI.Text(page, "GameFontNormal")
		h:SetPoint("TOPLEFT", col.x + 4, col.y)
		h:SetText(SECTION_BY[id].title)
		col.y = col.y - CLASSIC_HEADING
	end

	-- A checkbox, its label beside it, and an optional button after the label.
	local function Check(col, c)
		local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
		cb:SetPoint("TOPLEFT", col.x, col.y)
		cb.Text:SetFontObject("GameFontHighlight")
		cb.Text:SetJustifyH("LEFT")
		cb.Text:SetWordWrap(false)
		cb.Text:SetText(c.label)
		cb.Text:SetWidth(col.width - 34)
		cb:SetScript("OnClick", function(self)
			local on = self:GetChecked() and true or false
			ns.db.settings[c.key] = on
			PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
			if c.after then c.after() end
		end)
		cb.key = c.key
		if c.tip then UI.Tooltip(cb, c.label, c.tip) end
		table.insert(self.checks, cb)
		col.y = col.y - CLASSIC_ROW
		return cb
	end

	local function After(cb, label, width, onClick, tipTitle, tip)
		local w = math.min(cb.Text:GetStringWidth() or 0, cb.Text:GetWidth() - width - 12)
		cb.Text:SetWidth(w)
		local b = UI.Button(page, label, width, onClick)
		b:SetPoint("LEFT", cb.Text, "RIGHT", 10, 0)
		UI.Tooltip(b, tipTitle, tip)
		return b
	end

	-- A label and its dropdown on one line; every dropdown starts at the same x.
	local function Choice(col, label, onChange, options, value)
		local mid = col.y - CLASSIC_CHOICE / 2
		local text = UI.Text(page, "GameFontHighlight")
		text:SetPoint("LEFT", page, "TOPLEFT", col.x + 4, mid)
		text:SetText(label)
		local dd = UI.Dropdown(page, 240, onChange)
		dd:SetPoint("LEFT", page, "TOPLEFT", col.x + CLASSIC_LABEL_W, mid)
		dd:SetOptions(options, value)
		col.y = col.y - CLASSIC_CHOICE
		return dd
	end

	local Extra = {
		toasts = function(cb)
			extras.testNotice = After(cb, "Test", 60, function() ns.Toasts:Preview() end, "Test notice", "Shows a sample of the popup.")
		end,
		autoRead = function(cb)
			extras.testVoice = After(cb, "Test voice", 100, function()
				ns.Speak("Hello from T3 Code. This is how replies will sound.", "", "test")
			end, "Test voice", "Reads a sample line in the voice chosen below.")
		end,
	}

	local Section = {
		voice = function(col)
			local options = {}
			for _, v in ipairs(VOICES) do table.insert(options, { value = v[1], label = v[2] }) end
			self.voice = Choice(col, "Voice", function(value)
				ns.db.settings.tts = value
				ns.Transport:Touch()
				S:Refresh()
			end, options, ns.db.settings.tts)
		end,
		window = function(col)
			self.design = Choice(col, "Design", ChooseDesign, {
				{ value = "classic", label = "Classic (the game's own look)" },
				{ value = "modern", label = "Modern (Omarchy)" },
			}, ns.db.settings.theme or "classic")
			self.size = Choice(col, "Window size", function(value)
				ns.db.settings.windowScale = value
				ns.Main:ApplyScale()
			end, {
				{ value = "auto", label = "Automatic (larger with a controller)" },
				{ value = "normal", label = "Normal" },
				{ value = "large", label = "Large" },
				{ value = "xlarge", label = "Extra large" },
			}, ns.db.settings.windowScale or "auto")
		end,
	}

	local right
	for _, col in ipairs(CLASSIC_COLUMNS) do
		col = { x = col.x, width = col.width, sections = col.sections, y = -48 }
		for i, id in ipairs(col.sections) do
			if i > 1 then col.y = col.y - CLASSIC_GAP end
			Heading(col, id)
			for _, c in ipairs(CHECKS) do
				if c.section == id then
					local cb = Check(col, c)
					if Extra[c.key] then Extra[c.key](cb) end
				end
			end
			if Section[id] then Section[id](col) end
		end
		right = col
	end

	-- What the link is doing, under the right-hand column.
	local infoTitle = UI.Text(page, "GameFontNormal")
	infoTitle:SetPoint("TOPLEFT", right.x + 4, right.y - CLASSIC_GAP)
	infoTitle:SetText(SECTION_BY.connection.title)
	self.info = UI.Text(page, "GameFontHighlightSmall")
	self.info:SetPoint("TOPLEFT", infoTitle, "BOTTOMLEFT", 0, -8)
	self.info:SetWidth(right.width)
	self.info:SetJustifyH("LEFT")
	self.info:SetJustifyV("TOP")
	self.info:SetSpacing(3)

	local reload = UI.Button(page, "Reload UI", 130, function() ReloadUI() end)
	reload:SetPoint("BOTTOMLEFT", 20, 16)
	UI.Tooltip(reload, "Reload UI", "Frees up a fresh set of live updates. Does the same as typing /reload.")
	local resetTracker = UI.Button(page, "Reset tracker", 130, function()
		ns.db.settings.trackerPoint = nil
		ns.Tracker:Refresh(true)
	end)
	resetTracker:SetPoint("LEFT", reload, "RIGHT", 10, 0)
	local selftest = UI.Button(page, "Run self-test", 130, function() ns.SelfTest() end)
	selftest:SetPoint("LEFT", resetTracker, "RIGHT", 10, 0)
	UI.Tooltip(selftest, "Run self-test", "Checks the link to your desktop step by step and prints what's wrong, if anything.")
	local report = UI.Button(page, "Report a problem", 150, function() ns.Main:ShowPage("threads") ns.Main:Report() end)
	report:SetPoint("LEFT", selftest, "RIGHT", 10, 0)
	UI.Tooltip(report, "Report a problem", "Puts diagnostics in the message box and attaches a screenshot, for the thread you have open (or a new one).")
	local all = { extras.testNotice, extras.testVoice, self.voice, self.design, self.size, reload, resetTracker, selftest, report }
	self.controls = {}
	for i = 1, 9 do
		if all[i] then table.insert(self.controls, all[i]) end
	end
end

-- One setting row: a name, the line under it, a hairline, and the control on the right.
local function Describe(row, title, desc, right, theme)
	-- The kit's setting row: the name in the body face, the line under it a dim caption.
	local name = row:CreateFontString(nil, "ARTWORK", "T3ModernBody")
	name:SetPoint("TOPLEFT", 12, -9)
	name:SetPoint("RIGHT", right, "LEFT", -12, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	name:SetText(title)
	Theme.SetText(name, theme.text)
	local about = row:CreateFontString(nil, "ARTWORK", "T3ModernCaption")
	about:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
	about:SetPoint("RIGHT", right, "LEFT", -12, 0)
	about:SetJustifyH("LEFT")
	about:SetJustifyV("TOP")
	about:SetWordWrap(true)
	about:SetMaxLines(2)
	about:SetText(desc)
	Theme.SetText(about, theme.muted)
	local rule = Theme.Solid(row, theme.hairline, "ARTWORK")
	rule:SetHeight(1)
	rule:SetPoint("BOTTOMLEFT", 12, 0)
	rule:SetPoint("BOTTOMRIGHT", -12, 0)
	row.Rule = rule
	row:SetHeight(54)
end

function S:CreateModern(page)
	local theme = Theme.Get()
	self.checks, self.rows, self.nav, self.controls = {}, {}, {}, {}
	self.section = "notices"

	local nav = CreateFrame("Frame", nil, page)
	nav:SetPoint("TOPLEFT")
	nav:SetPoint("BOTTOMLEFT")
	nav:SetWidth(NAV_W)
	local divider = Theme.Solid(page, theme.hairline, "ARTWORK")
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", nav, "TOPRIGHT", 0, 0)
	divider:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT", 0, 0)

	local search = CreateFrame("EditBox", nil, nav, "SearchBoxTemplate")
	search:SetHeight(22)
	search:SetPoint("TOPLEFT", 10, -12)
	search:SetPoint("TOPRIGHT", -10, -12)
	search:SetAutoFocus(false)
	local well = Theme.Solid(search, theme.panel, "ARTWORK")
	well:SetAllPoints()
	Theme.Edges(search, theme.controlBorder)
	UI.UseLineSearch(search)
	-- The template's own hint sits under the flat well. Ours reads "Search settings".
	if search.Instructions then search.Instructions:Hide() end
	local hint = search:CreateFontString(nil, "OVERLAY", "T3ModernSmallFaint")
	hint:SetPoint("LEFT", search.lineInset or 30, 0)
	hint:SetText("Search settings")
	Theme.SetText(hint, theme.faint)
	search.Hint = hint
	search:HookScript("OnTextChanged", function(box)
		if box.Instructions then box.Instructions:Hide() end
		hint:SetShown(strtrim(box:GetText() or "") == "")
		S:Layout()
	end)
	search:HookScript("OnEditFocusGained", function() hint:Hide() end)
	search:HookScript("OnEditFocusLost", function(box)
		hint:SetShown(strtrim(box:GetText() or "") == "")
	end)
	search:HookScript("OnEscapePressed", function(box) box:ClearFocus() end)
	self.search = search

	local y = -46
	for _, sec in ipairs(SECTIONS) do
		local b = CreateFrame("Button", nil, nav)
		b:SetHeight(28)
		b:SetPoint("TOPLEFT", 8, y)
		b:SetPoint("TOPRIGHT", -8, y)
		b.id = sec.id
		b.Wash = Theme.Solid(b, theme.selected, "BACKGROUND")
		b.Wash:SetAllPoints()
		b.Wash:Hide()
		b.Bar = Theme.Solid(b, theme.accent, "ARTWORK")
		b.Bar:SetWidth(2)
		b.Bar:SetPoint("TOPLEFT")
		b.Bar:SetPoint("BOTTOMLEFT")
		b.Bar:Hide()
		local hl = Theme.Solid(b, theme.hover, "HIGHLIGHT")
		hl:SetAllPoints()
		b.Text = b:CreateFontString(nil, "ARTWORK", "T3ModernBody")
		b.Text:SetPoint("LEFT", 12, 0)
		b.Text:SetText(sec.label)
		b:SetScript("OnClick", function()
			S.section = sec.id
			if S.search:GetText() ~= "" then S.search:SetText("") end
			S:Layout()
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		end)
		table.insert(self.nav, b)
		table.insert(self.controls, b)
		y = y - 30
	end

	local ver = UI.Text(nav, "GameFontDisableSmall")
	ver:SetPoint("BOTTOMLEFT", 12, 12)
	ver:SetText("Version " .. (ns.version or ""))
	Theme.SetText(ver, theme.muted)

	local body = CreateFrame("Frame", nil, page)
	body:SetPoint("TOPLEFT", nav, "TOPRIGHT", 1, 0)
	body:SetPoint("BOTTOMRIGHT")

	-- The kit's heading level: 16 bold, with a body-size dim line under it.
	self.heading = UI.Text(body, "T3ModernHeading")
	self.heading:SetPoint("TOPLEFT", 16, -12)
	Theme.SetText(self.heading, theme.text)
	self.subhead = UI.Text(body, "T3ModernBodyDim")
	self.subhead:SetPoint("TOPLEFT", self.heading, "BOTTOMLEFT", 0, -2)
	self.subhead:SetPoint("RIGHT", body, "RIGHT", -16, 0)
	self.subhead:SetWordWrap(false)
	Theme.SetText(self.subhead, theme.muted)

	local scroll = CreateFrame("ScrollFrame", nil, body, "ScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -50)
	scroll:SetPoint("BOTTOMRIGHT", -26, 46)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(400, 40)
	scroll:SetScrollChild(content)
	UI.PlaceScrollBar(scroll)
	local card = Theme.Solid(content, theme.panel)
	card:SetAllPoints()
	Theme.Edges(content, theme.hairline)
	self.content = content
	scroll:SetScript("OnSizeChanged", function(_, w)
		w = math.max(200, w or 0)
		if math.abs((content:GetWidth() or 0) - w) > 1 then
			content:SetWidth(w)
			S:Layout()
		end
	end)

	self.empty = UI.Text(content, "GameFontHighlightSmall")
	self.empty:SetPoint("TOPLEFT", 12, -16)
	self.empty:SetText("Nothing matches that.")
	Theme.SetText(self.empty, theme.muted)
	self.empty:Hide()

	for _, c in ipairs(CHECKS) do
		local b = CreateFrame("CheckButton", nil, content)
		UI.PaintSwitch(b)
		Describe(b, c.title, c.desc, b.Switch, theme)
		local hl = Theme.Solid(b, theme.hover, "HIGHLIGHT")
		hl:SetAllPoints()
		b.key = c.key
		b.section = c.section
		b.hay = (c.title .. " " .. c.desc .. " " .. c.label):lower()
		b:SetChecked(ns.db.settings[c.key] and true or false)
		b:Sync()
		b:SetScript("OnClick", function(self)
			-- A check button toggles itself before this runs, same as the game's template.
			-- Flipping again put the switch back where it started.
			self:Sync()
			local on = self:GetChecked() and true or false
			ns.db.settings[c.key] = on
			PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
			if c.after then c.after() end
		end)
		table.insert(self.checks, b)
		table.insert(self.rows, b)
	end

	local preview = CreateFrame("Frame", nil, content)
	local testNotice = UI.Button(preview, "Test notice", 110, function() ns.Toasts:Preview() end)
	testNotice:SetPoint("RIGHT", -8, 0)
	Describe(preview, "See a notice", "Shows a sample of the popup, in this design.", testNotice, theme)
	preview.section = "notices"
	preview.hay = "see a notice test popup"
	table.insert(self.rows, preview)
	table.insert(self.controls, testNotice)

	local function ChoiceRow(section, title, desc, hay, width, onChange)
		local row = CreateFrame("Frame", nil, content)
		local dd = UI.Dropdown(row, width, onChange)
		dd:SetPoint("RIGHT", -8, 0)
		Describe(row, title, desc, dd, theme)
		row.section = section
		row.hay = hay
		table.insert(self.rows, row)
		return dd
	end

	local voiceOptions = {}
	local voiceHay = "voice reading aloud"
	for _, v in ipairs(VOICES) do
		table.insert(voiceOptions, { value = v[1], label = v[2] })
		voiceHay = voiceHay .. " " .. v[2]:lower()
	end
	self.voice = ChoiceRow("voice", "Voice", "Automatic uses the desktop voice when the bridge has one.", voiceHay, 220, function(value)
		ns.db.settings.tts = value
		ns.Transport:Touch()
		S:Refresh()
	end)
	self.voice:SetOptions(voiceOptions, ns.db.settings.tts)

	local hear = CreateFrame("Frame", nil, content)
	local test = UI.Button(hear, "Test", 72, function()
		ns.Speak("Hello from T3 Code. This is how replies will sound.", "", "test")
	end)
	test:SetPoint("RIGHT", -8, 0)
	Describe(hear, "Hear it", "Plays a short line in the voice you picked.", test, theme)
	hear.section = "voice"
	hear.hay = "hear it test voice"
	table.insert(self.rows, hear)
	table.insert(self.controls, test)

	self.design = ChoiceRow("window", "Design", "Classic uses the game's own frames. Modern follows Omarchy's look and themes.", "design classic modern look", 220, ChooseDesign)
	self.design:SetOptions({
		{ value = "classic", label = "Classic (the game's own look)" },
		{ value = "modern", label = "Modern (Omarchy)" },
	}, ns.db.settings.theme or "classic")

	self.size = ChoiceRow("window", "Window size", "Automatic grows the window while a controller is in use.", "window size automatic normal large", 220, function(value)
		ns.db.settings.windowScale = value
		ns.Main:ApplyScale()
	end)
	self.size:SetOptions({
		{ value = "auto", label = "Automatic (larger with a controller)" },
		{ value = "normal", label = "Normal" },
		{ value = "large", label = "Large" },
		{ value = "xlarge", label = "Extra large" },
	}, ns.db.settings.windowScale or "auto")

	local paletteHay = "theme omarchy colors light dark modern"
	for _, p in ipairs(Theme.Palettes()) do paletteHay = paletteHay .. " " .. p.label:lower() end
	self.palette = ChoiceRow("modern", "Theme", "One of Omarchy's own themes.", paletteHay, 220, ChoosePalette)
	self.palette:SetOptions(Theme.Palettes(), ns.db.settings.palette)

	local accentDesc = "Marks what's chosen: the selected thread, checks, and switches that are on."
	if Theme.accentWhy == "faint" then
		accentDesc = "Your class color is too faint on this theme, so the theme's accent is used."
	end
	self.accent = ChoiceRow("modern", "Accent", accentDesc, "accent class color theme modern", 220, ChooseAccent)
	self.accent:SetOptions(AccentChoices(), ns.db.settings.accent or "class")

	local clearRow = CreateFrame("Frame", nil, content)
	local opacity = UI.Slider(clearRow, 200, 0, 100, 1, ChooseClear, ClearText)
	opacity:SetPoint("RIGHT", -8, 0)
	opacity:SetValue(ns.db.settings.windowClear or 6, true)
	Describe(clearRow, "Transparency", "How much of the world shows through this window and its notices.", opacity, theme)
	clearRow.section = "modern"
	clearRow.hay = "transparency opacity clear solid modern window"
	table.insert(self.rows, clearRow)
	table.insert(self.controls, opacity)
	self.opacity = opacity

	local infoRow = CreateFrame("Frame", nil, content)
	infoRow.section = "connection"
	infoRow.hay = "connection bridge machines live updates dictation speech errors version"
	self.info = UI.Text(infoRow, "GameFontHighlightSmall")
	self.info:SetPoint("TOPLEFT", 12, -10)
	self.info:SetWidth(360)
	self.info:SetJustifyH("LEFT")
	self.info:SetJustifyV("TOP")
	self.info:SetSpacing(3)
	self.info:SetWordWrap(true)
	infoRow:SetHeight(160)
	table.insert(self.rows, infoRow)
	self.infoRow = infoRow

	local reload = UI.Button(body, "Reload UI", 100, function() ReloadUI() end)
	reload:SetPoint("BOTTOMLEFT", 12, 12)
	UI.Tooltip(reload, "Reload UI", "Frees up a fresh set of live updates. Does the same as typing /reload.")
	local resetTracker = UI.Button(body, "Reset tracker", 116, function()
		ns.db.settings.trackerPoint = nil
		ns.Tracker:Refresh(true)
	end)
	resetTracker:SetPoint("LEFT", reload, "RIGHT", 6, 0)
	local selftest = UI.Button(body, "Run self-test", 118, function() ns.SelfTest() end)
	selftest:SetPoint("LEFT", resetTracker, "RIGHT", 6, 0)
	UI.Tooltip(selftest, "Run self-test", "Checks the link to your desktop step by step and prints what's wrong, if anything.")
	local report = UI.Button(body, "Report a problem", 150, function() ns.Main:ShowPage("threads") ns.Main:Report() end)
	report:SetPoint("LEFT", selftest, "RIGHT", 6, 0)
	UI.Tooltip(report, "Report a problem", "Puts diagnostics in the message box and attaches a screenshot, for the thread you have open (or a new one).")
	for _, w in ipairs({ self.voice, self.design, self.palette, self.accent, self.size, test, reload, resetTracker, selftest, report }) do
		table.insert(self.controls, w)
	end

	self:Layout()
end

-- Show the open section, or every row a search matches, and restack them.
function S:Layout()
	if not self.rows or not self.content or not self.heading then return end
	local theme = Theme.Get()
	if not theme then return end
	local q = strtrim(self.search and self.search:GetText() or ""):lower()
	if self.info and self.infoRow and self.content then
		self.info:SetWidth(math.max(180, self.content:GetWidth() - 28))
		local h = self.info:GetStringHeight() or 0
		if h < 20 then h = 140 end
		self.infoRow:SetHeight(h + 20)
	end
	local shown = {}
	for _, row in ipairs(self.rows) do
		local match = (q == "" and row.section == self.section) or (q ~= "" and row.hay and row.hay:find(q, 1, true))
		row:SetShown(match and true or false)
		if match then table.insert(shown, row) end
	end
	local y = -8
	for i, row in ipairs(shown) do
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 4, y)
		row:SetPoint("TOPRIGHT", -4, y)
		if row.Rule then row.Rule:SetShown(i ~= #shown) end
		y = y - (row:GetHeight() or 54)
	end
	self.content:SetHeight(math.max(44, -y + 8))
	self.empty:SetShown(#shown == 0)
	if q ~= "" then
		self.heading:SetText("Search")
		local n = #shown
		self.subhead:SetText(n == 0 and "" or string.format("%d %s", n, n == 1 and "setting" or "settings"))
	else
		local sec = SECTION_BY[self.section] or SECTIONS[1]
		self.heading:SetText(sec.title)
		self.subhead:SetText(sec.blurb)
	end
	for _, b in ipairs(self.nav) do
		local on = q == "" and b.id == self.section
		b.Wash:SetShown(on)
		b.Bar:SetShown(on)
		b.Text:SetFontObject(on and "T3ModernBodyBold" or "T3ModernBody")
		Theme.SetText(b.Text, on and theme.text or theme.muted)
	end
end

-- Drop the page's controls: the window is being rebuilt under another design.
function S:Teardown()
	self.page, self.checks, self.controls = nil, nil, nil
	self.voice, self.size, self.design, self.accent, self.opacity, self.info = nil, nil, nil, nil, nil, nil
	self.palette = nil
	self.rows, self.nav, self.search, self.heading, self.subhead = nil, nil, nil, nil, nil
	self.infoRow, self.content, self.empty, self.section = nil, nil, nil, nil
end

local SIGNAL_TEXT = {
	ok = "working",
	muted = "unavailable — game sound is off, so updates arrive more slowly",
	unreliable = "unreliable on this client — using slower polling",
	unavailable = "unavailable — using slower polling",
	untested = "starting",
}

function S:Refresh()
	if not self.page then return end
	for _, cb in ipairs(self.checks) do
		local on = ns.db.settings[cb.key] and true or false
		cb:SetChecked(on)
		if cb.Sync then cb:Sync() end
	end
	self.voice.value = ns.db.settings.tts
	self.voice:Update()
	self.size.value = ns.db.settings.windowScale or "auto"
	self.size:Update()
	self.design.value = ns.db.settings.theme or "classic"
	self.design:Update()
	if self.palette then
		self.palette.value = ns.db.settings.palette
		self.palette:Update()
	end
	if self.accent then
		self.accent.value = ns.db.settings.accent or "class"
		self.accent:Update()
	end
	if self.opacity then
		local clear = ns.db.settings.windowClear
		if type(clear) ~= "number" then clear = 6 end
		self.opacity:SetValue(clear, true)
	end
	local T = ns.Transport
	local b = ns.Store.data.bridge or {}
	local lines = {
		"Bridge: " .. (b.version and ns.Color("green", "t3code-wow " .. b.version) or ns.Color("red", "not heard from")),
		"T3 Code: " .. (b.t3 == "connected" and ns.Color("green", "connected" .. (b.server and (" (" .. b.server .. ")") or "")) or ns.Color("red", b.t3 or "unknown"))
			.. (b.t3err and ns.Color("grey", " — " .. b.t3err) or ""),
		(function()
			if not b.envs then return "Machines: this computer only " .. ns.Color("grey", "(add more with t3code-wow env add <host>)") end
			local parts = {}
			for _, e in ipairs(b.envs) do
				local ok = e.state == "connected"
				table.insert(parts, ns.Color(ok and "green" or "red", e.label) .. ns.Color("grey", string.format(" (%s)", ok and (e.n .. " threads") or e.state)))
			end
			return "Machines: " .. table.concat(parts, ", ")
		end)(),
		string.format("Live updates left this session: %s of %d (/reload frees more)", ns.Color("white", T:SlotsLeft()), T.slotCount),
		"Update signals: " .. (SIGNAL_TEXT[T.signals] or T.signals),
		"Desktop speech: " .. (b.tts or ns.Color("grey", "none found")) .. "    Dictation: " .. (b.dictation or ns.Color("grey", "none found")),
		"Speaking with: " .. ({ system = "desktop voice", game = "game voice", off = "nothing (off)" })[ns.SpeechEngine()],
		"Controller shortcut: " .. (ns.Launcher.chordText and ns.Color("white", "hold " .. ns.Launcher.KeyText("PADLTRIGGER") .. " + " .. ns.Launcher.KeyText("PADRTRIGGER") .. ", press " .. ns.Launcher.KeyText("PADBACK")) or ns.Color("grey", "off (use the minimap button or the game menu)"))
			.. ns.Color("grey", "  (also in the game menu)"),
		"Errors: " .. ((ns.db.errors and #ns.db.errors > 0) and ns.Color("red", #ns.db.errors .. " recorded — /t3 errors") or ns.Color("green", "none")),
		"Addon " .. ns.version .. ns.Color("grey", "  ·  session " .. (ns.db.session or "?")),
	}
	self.info:SetText(table.concat(lines, "\n"))
	-- Restack only when the connection blurb changes height. A snapshot arrives
	-- often, and restacking would jump the list back to the top.
	if self.infoRow then
		local h = self.info:GetStringHeight() or 0
		if h < 20 then h = 140 end
		local nextH = h + 20
		if math.abs((self.infoRow:GetHeight() or 0) - nextH) > 1 then
			self.infoRow:SetHeight(nextH)
			self:Layout()
		end
	end
end

ns:On("DataChanged", function()
	if ns.Main.page == "settings" and ns.Main.frame and ns.Main.frame:IsShown() then S:Refresh() end
end)

-- Options > AddOns entry that opens the real settings tab.
ns:On("Login", function()
	if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
	local panel = CreateFrame("Frame")
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("T3 Code")
	local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	text:SetText("Watch and run your T3 Code agents from inside the game. Type /t3 to open the window.")
	local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	open:SetSize(200, 24)
	open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -16)
	open:SetText("Open T3 Code settings")
	open:SetScript("OnClick", function()
		if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
		ns.Main:Open()
		ns.Main:ShowPage("settings")
	end)
	local category = Settings.RegisterCanvasLayoutCategory(panel, "T3 Code")
	Settings.RegisterAddOnCategory(category)
	ns.settingsCategory = category
end)
