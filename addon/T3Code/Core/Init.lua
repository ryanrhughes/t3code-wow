-- T3 Code for World of Warcraft: Forever.
-- Namespace, saved settings, small helpers and an internal event bus.

local addonName, ns = ...
T3Code = ns

ns.name = addonName
ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"
ns.media = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

ns.COLORS = {
	gold = "ffffd100",
	white = "ffffffff",
	grey = "ff9d9d9d",
	green = "ff1eff00",
	red = "ffff4040",
	blue = "ff71d5ff",
	agent = "ff4a9eff",
	orange = "ffff9b38",
}

-- Text in one of the colors above. In the modern window they are the theme's:
-- gold is the accent, white the foreground, grey the dim text, and so on.
function ns.Color(key, text)
	local hex = ns.COLORS[key] or key
	if ns.Theme and ns.Theme.Get() and ns.Theme.MARKUP[key] then hex = ns.Theme.MARKUP[key] end
	return "|c" .. hex .. tostring(text) .. "|r"
end

-- The same for the chat frame, which keeps the game's colors in either design.
function ns.ChatColor(key, text)
	return "|c" .. (ns.COLORS[key] or key) .. tostring(text) .. "|r"
end

---------------------------------------------------------------------------
-- Event bus

local listeners = {}

function ns:On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

-- Forever hides Lua errors by default, so keep our own: shown by /t3 errors and the
-- Settings tab, and saved with the addon's data (readable after /reload).
ns.errors = {}

function ns.RecordError(err)
	local msg = tostring(err)
	local stack = debugstack and debugstack(3, 6, 0) or ""
	local entry = { t = time(), msg = msg, stack = stack }
	table.insert(ns.errors, entry)
	if #ns.errors > 30 then table.remove(ns.errors, 1) end
	if ns.db then
		ns.db.errors = ns.db.errors or {}
		table.insert(ns.db.errors, entry)
		while #ns.db.errors > 30 do table.remove(ns.db.errors, 1) end
	end
	if not ns.errorNotified then
		ns.errorNotified = true
		if DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage("|cffffd100T3 Code|r: |cffff4040something went wrong|r — type /t3 errors for details.")
		end
	end
end

-- Wrap a script handler so a bug is recorded instead of silently breaking it.
function ns.Safe(fn, onErrorReturn)
	local function handler(e)
		ns.RecordError(e)
		return e
	end
	return function(...)
		local n, args = select("#", ...), { ... }
		local results = { xpcall(function() return fn(unpack(args, 1, n)) end, handler) }
		if results[1] then return unpack(results, 2) end
		return onErrorReturn
	end
end

function ns:Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok then ns.RecordError(event .. ": " .. tostring(err)) end
	end
end

---------------------------------------------------------------------------
-- Saved settings

local DEFAULTS = {
	settings = {
		tracker = true,
		toasts = true,
		sounds = true,
		tts = "auto", -- auto | game | system | off
		autoRead = false,
		project = "all",
		quickReplies = true,
		collapsed = { snoozed = true, settled = true },
		strip = true,
		trackerLocked = true,
		trackerAlways = true,
		gameMenu = true,
		minimapButton = true,
		dictateSend = false,
		steerFollowUps = true,
		newWorktree = false,
		subagentRows = true, -- a running subagent gets a row of its own in the list
		quietInstances = true,
		windowScale = "auto",
		padChord = "auto",
		theme = "classic", -- classic (the game's own look) | modern (Omarchy's UI kit)
		palette = "tokyo-night", -- modern window only: one of Omarchy's built-in themes (UI/Palettes.lua)
		accent = "class", -- modern window only: class (the player's class color) | theme (the theme's accent)
		windowClear = 6, -- modern window only: 0 is solid, 100 lets the world show through
		listWidth = 300, -- the thread list, dragged wider or narrower from its edge
	},
	drafts = {},
	models = {}, -- project id -> the model last picked for new threads there
	efforts = {}, -- project id -> the reasoning level last picked for new threads there
	cmdId = 0,
	sigNext = 1,
	gen = 0,
}

local function ApplyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			if type(v) == "table" then
				dst[k] = {}
				ApplyDefaults(dst[k], v)
			else
				dst[k] = v
			end
		elseif type(v) == "table" and type(dst[k]) == "table" then
			ApplyDefaults(dst[k], v)
		end
	end
end

-- Settings saved by an earlier version. The fixed accents (verdigris, ice, copper,
-- gold) gave way to the theme's own; a theme Omarchy no longer ships is Tokyo Night.
function ns.MigrateSettings(s)
	if s.accent ~= "class" and s.accent ~= "theme" then s.accent = "theme" end
	local known
	for _, p in ipairs(ns.PALETTES or {}) do
		if p.id == s.palette then known = true end
	end
	if not known then s.palette = DEFAULTS.settings.palette end
end

local function RandomToken(n)
	local chars = "abcdefghijkmnpqrstuvwxyz23456789"
	local out = {}
	for i = 1, n do
		local r = math.random(1, #chars)
		out[i] = chars:sub(r, r)
	end
	return table.concat(out)
end
ns.RandomToken = RandomToken

---------------------------------------------------------------------------
-- Time helpers

function ns.Now()
	return time()
end

function ns.Duration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds < 60 then return seconds .. "s" end
	local m = math.floor(seconds / 60)
	if m < 60 then return string.format("%dm %02ds", m, seconds % 60) end
	local h = math.floor(m / 60)
	return string.format("%dh %02dm", h, m % 60)
end

-- When a snoozed thread comes back: the time, with the day when it isn't today.
function ns.Until(epoch)
	if not epoch then return "" end
	local clock = (date("%I:%M %p", epoch):gsub("^0", ""))
	if date("%Y%j", epoch) == date("%Y%j") then return clock end
	return date("%a ", epoch) .. clock
end

function ns.Ago(epoch)
	if not epoch then return "" end
	local d = math.max(0, time() - epoch)
	if d < 60 then return "now" end
	if d < 3600 then return math.floor(d / 60) .. "m" end
	if d < 86400 then return math.floor(d / 3600) .. "h" end
	return math.floor(d / 86400) .. "d"
end

function ns.Print(...)
	local msg = strjoin(" ", tostringall(...))
	-- The chat frame stays on the game's gold, so a line from here matches the chat around it.
	DEFAULT_CHAT_FRAME:AddMessage("|c" .. ns.COLORS.gold .. "T3 Code|r: " .. msg)
end

function ns.InCombat()
	return InCombatLockdown() or false
end

-- The player just used the T3 Code window (see Transport: "attending").
function ns.Interacted()
	ns.lastInteraction = GetTime()
end

-- No pop-ups or read-aloud right now: in combat, or in a dungeon/raid/PvP instance
-- when the player asked for quiet there.
function ns.IsQuiet()
	if InCombatLockdown() then return true end
	if ns.db and ns.db.settings.quietInstances and IsInInstance then
		local inInstance, kind = IsInInstance()
		if inInstance and kind ~= "none" then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- Lifecycle

local frame = CreateFrame("Frame")
ns.eventFrame = frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", ns.Safe(function(_, event, arg1, ...)
	if event == "ADDON_LOADED" and arg1 == addonName then
		T3CodeDB = T3CodeDB or {}
		ApplyDefaults(T3CodeDB, DEFAULTS)
		ns.db = T3CodeDB
		ns.MigrateSettings(ns.db.settings)
		if not ns.db.session then ns.db.session = RandomToken(8) end
		-- One token per UI session: the bridge uses it to notice /reload.
		ns.ui = RandomToken(6)
		ns:Fire("Loaded")
	elseif event == "PLAYER_LOGIN" then
		ns:Fire("Login")
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns:Fire("EnteringWorld", arg1, ...)
	elseif event == "PLAYER_REGEN_DISABLED" then
		ns:Fire("Combat", true)
	elseif event == "PLAYER_REGEN_ENABLED" then
		ns:Fire("Combat", false)
	end
end))

function ns:RegisterEvent(event, fn)
	frame:RegisterEvent(event)
	ns:On("event:" .. event, fn)
end

frame:HookScript("OnEvent", function(_, event, ...)
	if listeners["event:" .. event] then ns:Fire("event:" .. event, ...) end
end)
