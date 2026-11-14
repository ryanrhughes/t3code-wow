-- The latest snapshot from the bridge, plus derived views of it.

local _, ns = ...

local Store = {
	data = { threads = {}, projects = {}, usage = {}, bridge = {} },
	byId = {},
	projectsById = {},
	applied = 0,
	-- Model lists by machine ("" for this one). The bridge sends them only when they
	-- change (we report modelsHash in the hello), so they outlive each snapshot.
	models = {},
	modelsHash = "",
	-- Each provider's slash commands and skills, by machine and instance: they ride
	-- with the model list and live as long as it does.
	commands = {},
	-- What the bridge last sent for the parts it may leave out of an update. We report
	-- them in the hello, so a snapshot that omits them is still complete for us.
	listKey = "",
	projectsKey = "",
	viewKey = "",
	familyKey = "",
}
ns.Store = Store

-- The parts a snapshot may leave out while we hold them, in the order the hello reports
-- their hashes (after listKey). `letter` names a part in the snapshot's `x` and `same`;
-- `key` is where we keep the hash we hold. The bridge's PARTS lists the same, in order.
Store.PARTS = {
	{ field = "projects", letter = "p", key = "projectsKey" },
	{ field = "view", letter = "v", key = "viewKey" },
	{ field = "fam", letter = "f", key = "familyKey" },
}

-- As T3 Code's sidebar: a thread that needs you (an answer, an approval, a plan to
-- review) is listed with Open at the top, and Working holds only what's running or
-- waiting on something else.
local GROUP_OF = {
	working = "working", waiting = "working",
	input = "open", plan = "open", open = "open", failed = "open",
	snoozed = "snoozed",
	settled = "settled",
}
Store.GROUP_OF = GROUP_OF

function Store:Apply(data)
	local prev = self.data
	-- A snapshot may leave out the transcript (60 KB), the project list and the open
	-- thread's family when the bridge knows, from our hello, that we already hold them.
	-- `same` names the parts it left out; a part that is neither sent nor named is empty
	-- now (no thread selected, no projects). Keeping the old table costs nothing: the
	-- next full snapshot replaces it.
	local same = type(data.same) == "string" and data.same or ""
	local sent = {}
	for _, part in ipairs(Store.PARTS) do
		sent[part.field] = data[part.field] ~= nil
		if not sent[part.field] and same:find(part.letter, 1, true) then data[part.field] = prev[part.field] end
	end
	data.threads = data.threads or {}
	data.projects = data.projects or {}
	data.usage = data.usage or {}
	data.bridge = data.bridge or {}
	local before = self.byId
	local byId, projectsById = {}, {}
	for _, t in ipairs(data.threads) do byId[t.id] = t end
	for _, p in ipairs(data.projects) do projectsById[p.id] = p end
	self.data, self.byId, self.projectsById = data, byId, projectsById
	self.applied = self.applied + 1
	if type(data.x) == "table" then
		-- Only record the hash of a part this snapshot actually carried: the bridge's
		-- hash describes what it sent, and a part it left out is still the old one.
		-- A part that was neither sent nor kept is gone, so claim nothing for it.
		self.listKey = data.x.l ~= nil and tostring(data.x.l) or self.listKey
		for _, part in ipairs(Store.PARTS) do
			if sent[part.field] then
				self[part.key] = tostring(data.x[part.letter] or "")
			elseif not same:find(part.letter, 1, true) then
				self[part.key] = ""
			end
		end
	else
		-- An older bridge sends everything in every snapshot, so a new one is a new
		-- version of every part.
		self.listKey = "gen:" .. self.applied
		for _, part in ipairs(Store.PARTS) do self[part.key] = "gen:" .. self.applied end
	end
	if type(data.models) == "table" and type(data.models.g) == "table" then
		-- Flattened per machine, in T3's order: { i, s, l, p = provider, r = levels }.
		local models, commands = {}, {}
		for _, g in ipairs(data.models.g) do
			local list, byInstance = {}, {}
			for _, p in ipairs(type(g.p) == "table" and g.p or {}) do
				for _, m in ipairs(type(p.m) == "table" and p.m or {}) do
					local levels = m.r and g.x and g.x[m.r]
					table.insert(list, { i = p.i, s = m.s, l = m.l, p = p.n or p.i, r = type(levels) == "table" and levels or nil })
				end
				if p.i and type(p.c) == "table" and #p.c > 0 then byInstance[p.i] = p.c end
			end
			models[g.e or ""] = list
			commands[g.e or ""] = byInstance
		end
		self.models, self.commands, self.modelsHash = models, commands, tostring(data.models.h or "")
	end

	if self.applied > 1 then
		for id, t in pairs(byId) do
			local old = before[id]
			if old and old.s ~= t.s then
				ns:Fire("ThreadTransition", t, old.s, t.s)
			elseif not old and (t.s == "working" or t.s == "input") then
				ns:Fire("ThreadTransition", t, nil, t.s)
			end
		end
	end
	ns:Fire("DataChanged")
	if data.view and data.view.id == ns.viewId then ns:Fire("ViewChanged") end
end

-- A thread's list row, else the open thread's own row, which the bridge sends with its
-- family when the list leaves it out (an idle subagent, say).
function Store:Thread(id)
	if not id then return nil end
	local fam = self.data.fam
	return self.byId[id] or (fam and fam.id == id and fam.me) or nil
end

-- The open thread's family: { id, me?, up?, kids? }, or nil when the bridge hasn't sent
-- one for the thread on screen.
function Store:Family()
	local fam = self.data.fam
	if fam and fam.id == ns.viewId then return fam end
end

-- A relative in the family we hold, { id, t, s?, k, env? }: what the header shows for
-- it right after it's opened, before its own snapshot arrives.
function Store:Relative(id)
	local fam = self.data.fam
	if not id or not fam then return nil end
	if fam.up and fam.up.id == id then return fam.up end
	for _, kid in ipairs(fam.kids or {}) do
		if kid.id == id then return kid end
	end
end

function Store:ProjectName(id)
	local p = id and self.projectsById[id]
	return p and p.name or ""
end

-- Threads grouped for the sidebar, filtered by project.
-- projectFilter: "all", a project id, or "m:<machine>" ("m:local" for this one).
function Store:Groups(projectFilter, query)
	local groups = { working = {}, open = {}, snoozed = {}, settled = {} }
	local machine = projectFilter and projectFilter:match("^m:(.+)$")
	for _, t in ipairs(self.data.threads) do
		local match
		if machine then
			match = (machine == "local" and not t.env) or t.env == machine
		else
			match = projectFilter == "all" or projectFilter == nil or t.p == projectFilter
		end
		if match and query and query ~= "" then
			match = t.title:lower():find(query, 1, true) or self:ProjectName(t.p):lower():find(query, 1, true)
		end
		if match then
			local g = GROUP_OF[t.s] or "open"
			table.insert(groups[g], t)
		end
	end
	return groups
end

function Store:Active()
	local list = {}
	for _, t in ipairs(self.data.threads) do
		if t.s == "working" or t.s == "input" or t.s == "plan" or t.s == "waiting" then table.insert(list, t) end
	end
	return list
end

---------------------------------------------------------------------------
-- Models

-- A model's key: instance and slug joined by a tab, as the bridge writes them.
function Store.ModelKey(instanceId, slug)
	if not instanceId or not slug then return nil end
	return instanceId .. "\t" .. slug
end

function Store.SplitModelKey(key)
	return (key or ""):match("^(.-)\t(.+)$")
end

-- The machine a thread or project id belongs to: the bridge prefixes other
-- machines' ids with their code and "~" ("" for this one).
function Store.EnvOf(id)
	return id and id:match("^([^~]+)~") or ""
end

local function Find(self, env, key)
	if not key then return nil end
	for _, m in ipairs(self.models[env or ""] or {}) do
		if Store.ModelKey(m.i, m.s) == key then return m end
	end
end

function Store:Offers(env, key)
	return Find(self, env, key) ~= nil
end

local DIM = "|cff9d9d9d"

-- "Name · Provider", with the provider dimmed when `dim` is set.
function Store:ModelLabel(env, key, dim)
	local m = Find(self, env, key)
	if not m then return select(2, Store.SplitModelKey(key)) end
	if dim then return m.l .. DIM .. " · " .. m.p .. "|r" end
	return m.l .. " · " .. m.p
end

-- Choices for a model picker on machine `env`, in groups under header rows: the
-- models its latest threads used first (a short reach on a controller), then each
-- provider's models in T3's order. `current` is listed even when it's no longer
-- offered (a legacy model, say). Rows inside a provider group show just the model;
-- the button always shows the provider too.
function Store:ModelOptions(env, current)
	local list = self.models[env or ""]
	if not list or #list == 0 then return nil end
	local options = {}
	local function item(m, group, withProvider)
		local key = Store.ModelKey(m.i, m.s)
		local text = m.l .. DIM .. " · " .. m.p .. "|r"
		table.insert(options, { value = key, label = withProvider and text or m.l, text = text, group = group })
	end
	local recent, seen = {}, {}
	if current and not Find(self, env, current) then
		local slug = select(2, Store.SplitModelKey(current))
		table.insert(recent, { value = current, label = slug, text = slug, group = "Recent" })
	end
	local byRecent = {}
	for _, t in ipairs(self.data.threads) do
		if t.mi and t.m and Store.EnvOf(t.id) == (env or "") then table.insert(byRecent, t) end
	end
	table.sort(byRecent, function(a, b) return (a.st or a.u or 0) > (b.st or b.u or 0) end)
	local recentModels = {}
	for _, t in ipairs(byRecent) do
		if #recentModels >= 4 then break end
		local key = Store.ModelKey(t.mi, t.m)
		local m = Find(self, env, key)
		if m and not seen[key] then
			seen[key] = true
			table.insert(recentModels, m)
		end
	end
	if #recent + #recentModels > 0 then
		table.insert(options, { header = true, label = "Recent" })
		for _, o in ipairs(recent) do table.insert(options, o) end
		for _, m in ipairs(recentModels) do item(m, "Recent", true) end
	end
	local provider
	for _, m in ipairs(list) do
		if m.p ~= provider then
			provider = m.p
			table.insert(options, { header = true, label = provider })
		end
		item(m, provider, false)
	end
	return options
end

-- A model's reasoning levels as picker choices, plus the one T3 uses by default.
-- nil when the model has none.
function Store:EffortOptions(env, key)
	local m = Find(self, env, key)
	local levels = m and m.r
	if not levels or type(levels.o) ~= "table" or #levels.o == 0 then return nil end
	local options = {}
	for _, o in ipairs(levels.o) do table.insert(options, { value = o.i, label = o.l or o.i }) end
	return options, levels.d
end

-- The level the latest active thread on machine `env` used with model `key`, which
-- the bridge carries over when that model is picked without a level (nil: the
-- model's own).
function Store:LastEffort(env, key)
	local best
	for _, t in ipairs(self.data.threads) do
		if Store.EnvOf(t.id) == (env or "") and Store.ModelKey(t.mi, t.m) == key
			and (not best or (t.st or t.u or 0) > (best.st or best.u or 0)) then
			best = t
		end
	end
	return best and best.re
end

-- A provider's slash commands and skills, { t = "/name" or "$name", d = description },
-- or nil when it has none.
function Store:Commands(env, instanceId)
	local machine = self.commands[env or ""]
	return machine and instanceId and machine[instanceId] or nil
end

function Store.HasOption(options, value)
	for _, o in ipairs(options or {}) do
		if not o.header and o.value == value then return true end
	end
	return false
end

function Store:View()
	local v = self.data.view
	if v and v.id == ns.viewId then return v end
end

---------------------------------------------------------------------------
-- Status words and colors

local STATUS_TEXT = {
	working = "Working", input = "Needs you", plan = "Plan ready", waiting = "Waiting",
	open = "Finished", failed = "Failed", snoozed = "Snoozed", settled = "Settled",
}
local STATUS_COLOR = {
	working = "blue", input = "orange", plan = "orange", waiting = "grey",
	open = "white", failed = "red", snoozed = "grey", settled = "grey",
}

function Store.StatusText(s)
	return STATUS_TEXT[s] or s or ""
end

function Store.StatusColor(s)
	return STATUS_COLOR[s] or "white"
end

---------------------------------------------------------------------------
-- Speech: the game's own voices when it has any, otherwise the desktop's.

function ns.StripMarkup(text)
	text = tostring(text or "")
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("||", "|")
	return text
end

local function GameVoices()
	if not C_VoiceChat or not C_VoiceChat.GetTtsVoices then return nil end
	local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
	return ok and voices and #voices > 0 and voices or nil
end

-- What is being read aloud, so a speaker button can stop it: nil, or { voice = "game"
-- or "system", key = the ReadingKey of what a button started, nil for anything else }.
local reading
-- The latest speak, say or hush sent to the bridge. A snapshot whose `speech` hasn't
-- acted on it yet was built before that click, so it says nothing about it.
local lastSpeechCmd = 0

-- Whether the bridge says when its voice is reading. One that doesn't can't say when a
-- reading ends, so the desktop voice's readings never show.
local function SpeechReported()
	return type(Store.data.speech) == "table"
end

local function SetReading(value)
	if value == reading then return end
	reading = value
	ns:Fire("ReadingChanged")
end

function ns.ReadingKey(threadId, messageIndex)
	if not threadId or threadId == "" then return nil end
	return threadId .. ":" .. tostring(messageIndex or "last")
end

-- Whether anything is being read aloud, or with a key, whether that is.
function ns.Reading(key)
	return reading ~= nil and (key == nil or reading.key == key)
end

function ns.SpeechEngine()
	local pref = ns.db and ns.db.settings.tts or "auto"
	if pref == "off" then return "off" end
	if pref == "game" then return GameVoices() and "game" or "off" end
	if pref == "system" then return "system" end
	-- auto: the desktop voice when the bridge has one (Wine rarely has game voices).
	if Store.data.bridge and Store.data.bridge.tts then return "system" end
	if GameVoices() then return "game" end
	return "off"
end

function ns.Speak(text, threadId, messageIndex)
	local engine = ns.SpeechEngine()
	local key = ns.ReadingKey(threadId, messageIndex)
	if engine == "system" then
		local id
		if key then
			id = ns.Transport:Send("speak", threadId, messageIndex or "last")
		else
			id = ns.Transport:Send("say", ns.StripMarkup(text):sub(1, 1200))
		end
		if id then
			lastSpeechCmd = id
			if SpeechReported() then SetReading({ voice = "system", key = key }) end
		end
		return true
	elseif engine == "game" then
		local voices = GameVoices()
		local voice = voices and voices[1].voiceID or 0
		if C_TTSSettings and C_TTSSettings.GetVoiceOptionID and Enum.TtsVoiceType then
			voice = C_TTSSettings.GetVoiceOptionID(Enum.TtsVoiceType.Standard) or voice
		end
		local rate = C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate() or 0
		local volume = C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume() or 100
		C_VoiceChat.StopSpeakingText()
		C_VoiceChat.SpeakText(voice, ns.StripMarkup(text):sub(1, 2000), rate, volume, false)
		SetReading({ voice = "game", key = key })
		return true
	end
	ns.Print("No text-to-speech voice is available. Pick one in T3 Code settings.")
	return false
end

function ns.Hush()
	if (reading and reading.voice or ns.SpeechEngine()) == "game" then
		C_VoiceChat.StopSpeakingText()
	else
		lastSpeechCmd = ns.Transport:Send("hush") or lastSpeechCmd
	end
	SetReading(nil)
end

-- The game's voice says when a reading ends, except one stopped with StopSpeakingText,
-- which is why Speak and Hush clear it themselves. As in the game's own chat reader,
-- any reading's end counts: one that started after ours was either queued behind it or
-- cut it off, and a reading cut off never says it ended.
local function GameReadingEnded()
	if reading and reading.voice == "game" then SetReading(nil) end
end
ns:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FINISHED", GameReadingEnded)
ns:RegisterEvent("VOICE_CHAT_TTS_PLAYBACK_FAILED", GameReadingEnded)

local function Queued(id)
	for _, cmd in ipairs(ns.Transport.queue) do
		if cmd.id == id then return true end
	end
	return false
end

-- The desktop voice is the bridge's, and each snapshot says whether it is reading.
-- A snapshot that doesn't acknowledge this window comes from a bridge that hasn't heard
-- it, one restarted since, say: a click that has already gone went to a bridge that has
-- stopped since, so that snapshot says all there is about it.
ns:On("DataChanged", function()
	if not SpeechReported() then
		if reading and reading.voice == "system" then SetReading(nil) end
		return
	end
	local speech = Store.data.speech
	local ack = Store.data.ack
	local heard = type(ack) == "table" and ack.ui == ns.ui
	if (tonumber(speech.cmd) or 0) < lastSpeechCmd and (heard or Queued(lastSpeechCmd)) then return end
	if speech.on then
		if not (reading and reading.voice == "system") then SetReading({ voice = "system" }) end
	elseif reading and reading.voice == "system" then
		SetReading(nil)
	end
end)
