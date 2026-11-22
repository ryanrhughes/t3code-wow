-- Headless smoke test: load the addon against tools/wowstub.lua and drive it.
--   lua5.1 tools/smoke.lua <addon dir> <snapshot.lua> [viewId]
local addonDir, snapshot, viewId = arg[1], arg[2], arg[3]
package.path = "./tools/?.lua;" .. package.path
local Stub = dofile("tools/wowstub.lua")
Stub.slotData.default = snapshot

local function check(cond, msg)
	if not cond then for _, e in ipairs(T3Code and T3Code.errors or {}) do print("RECORDED ERROR: " .. e.msg) end error("CHECK FAILED: " .. msg, 2) end
	print("ok - " .. msg)
end

-- Load files in TOC order.
local ns = {}
for line in io.lines(addonDir .. "/T3Code.toc") do
	line = line:gsub("\r", "")
	if line ~= "" and not line:match("^#") and line:match("%.lua$") then
		local path = addonDir .. "/" .. line:gsub("\\", "/")
		local chunk = assert(loadfile(path))
		chunk("T3Code", ns)
	end
end
check(T3Code == ns, "namespace exported")

Stub.Fire("ADDON_LOADED", "T3Code")
check(ns.db and ns.db.session and #ns.db.session == 8, "saved variables initialised")
Stub.Fire("PLAYER_LOGIN")
check(ns.Transport.slotCount == 600, "found 600 slots by binary search")
check(ns.Store.applied == 1, "bootstrap slot applied")
check(#ns.Store.data.threads > 0, "threads loaded: " .. #ns.Store.data.threads)
check(ns.Transport.stripShown, "hello strip shown")
check(ns.Transport:Encrypted(), "link keys loaded from the bootstrap slot")
check(T3Code_Inbox == nil, "slot global cleared after loading")
do
	local drawn = WOWSTUB.StripCells()
	-- Header byte 3 (version) spans cells 6..8: bits 16..23 of the frame.
	local bits = {}
	for i = 1, 9 do local v = drawn[i] bits[#bits + 1] = math.floor(v / 4) % 2 bits[#bits + 1] = math.floor(v / 2) % 2 bits[#bits + 1] = v % 2 end
	local version = 0
	for i = 17, 24 do version = version * 2 + bits[i] end
	check(version == 2, "strip is drawn encrypted (frame version 2)")
end
local payload = ns.Transport:Payload()
check(payload:sub(1, 2) == "H\031", "payload starts with hello record")

-- Strip encodes within capacity and the cells are valid.
local cells = ns.Codec.Encode(ns.Transport.stripSeq, payload)
check(#cells > 0, "strip cells: " .. #cells)

-- Simulate the bridge acknowledging the hello via the next slot.
Stub.validSounds = {}
ns.Transport.signals = "ok"
local sig = ns.db.sigNext
-- Patch the snapshot's ack to this UI session.
local chunk = assert(loadfile(snapshot))
chunk()
local data = T3Code_Inbox
T3Code_Inbox = nil
data.ack = { ui = ns.ui, seq = ns.Transport.stripSeq }
-- The harness edits the snapshot in place, so its hashes (x) would no longer describe
-- what it carries. Without them every snapshot counts as complete, as an older bridge's
-- did; the test below drives the "this part is unchanged" path with its own hashes.
data.x = nil
data.gen = data.gen + 1
data.nextSig = sig + 1
ns.Transport:Apply(data)
check(not ns.Transport.stripShown, "strip hidden after ack")

-- Open the window, select a thread, render.
ns.Main:Open()
check(ns.windowOpen, "window open")
check(ns.Transport.stripShown, "window open bumps the strip")
local firstThread = ns.Store.data.threads[1]
ns.Main:SelectThread(viewId ~= "" and viewId or firstThread.id)
check(ns.viewId ~= nil, "thread selected")
ns.Store:Apply(data) -- view arrives
local rows = ns.Transcript.scrollBox._rows or {}
check(#rows > 0, "transcript rendered " .. #rows .. " elements")
local listRows = ns.ThreadList.scrollBox._rows or {}
check(#listRows > 0, "thread list rendered " .. #listRows .. " rows")

-- A snapshot may leave out the transcript and the project list when the bridge knows,
-- from the hello, that this addon already has them. It names them in `same`.
do
	local view = ns.Store.data.view
	local projects = ns.Store.data.projects
	data.gen = data.gen + 1
	ns.Transport:Apply({
		gen = data.gen, x = { l = "L1", p = "P1", v = "V1" },
		threads = ns.Store.data.threads, projects = projects, view = view,
		bridge = ns.Store.data.bridge, usage = ns.Store.data.usage,
		ack = { ui = ns.ui, seq = ns.Transport.stripSeq },
	})
	check(ns.Store.listKey == "L1" and ns.Store.projectsKey == "P1" and ns.Store.viewKey == "V1", "the addon records what it applied")
	rows = ns.Transcript.scrollBox._rows or {}
	local dpBefore = ns.Transcript.dp
	data.gen = data.gen + 1
	ns.Transport:Apply({
		gen = data.gen, same = "pv", x = { l = "L2", p = "P2", v = "V2" },
		threads = ns.Store.data.threads, bridge = ns.Store.data.bridge, usage = ns.Store.data.usage,
		ack = { ui = ns.ui, seq = ns.Transport.stripSeq },
	})
	check(ns.Store.data.view == view, "an omitted transcript is kept")
	check(ns.Store.data.projects == projects, "an omitted project list is kept")
	check(ns.Store.listKey == "L2" and ns.Store.projectsKey == "P1" and ns.Store.viewKey == "V1", "it only claims the parts it was sent")
	check(ns.Transport:Payload():find("\031L2\031P1\031V1", 1, true) ~= nil, "the hello reports what it holds")
	check(#(ns.Transcript.scrollBox._rows or {}) == #rows and ns.Transcript.dp == dpBefore, "the transcript isn't rebuilt for an unchanged one")

	-- Dropping the transcript must drop the hash too, and tell the bridge, or it would
	-- think the addon still has it and never send it again (Back, then the same thread).
	data.gen = data.gen + 1
	ns.Transport:Apply({
		gen = data.gen, x = { l = "L3", p = "P1", v = "" },
		threads = ns.Store.data.threads, projects = ns.Store.data.projects,
		bridge = ns.Store.data.bridge, usage = ns.Store.data.usage,
		ack = { ui = ns.ui, seq = ns.Transport.stripSeq },
	})
	check(ns.Store.data.view == nil and ns.Store.viewKey == "", "a dropped transcript is not claimed")

	-- Settling or reopening a thread changes the rows (quick replies) without the
	-- transcript changing, so its hash alone can't decide a redraw.
	ns.Store:Apply({
		x = { l = "L4", p = "P1", v = "V1" }, same = "v",
		threads = ns.Store.data.threads, projects = ns.Store.data.projects, bridge = ns.Store.data.bridge, usage = ns.Store.data.usage,
	})
	local dp = ns.Transcript.dp
	local thread = ns.Store:Thread(ns.viewId)
	local was = thread.s
	thread.s = was == "open" and "settled" or "open"
	ns.Store:Apply({
		x = { l = "L5", p = "P1", v = "V1" }, same = "v",
		threads = ns.Store.data.threads, projects = ns.Store.data.projects, bridge = ns.Store.data.bridge, usage = ns.Store.data.usage,
	})
	check(ns.Transcript.dp ~= dp, "a status change still redraws the transcript")
	thread.s = was
	-- Back to a complete snapshot for the rest of the checks.
	ns.Store:Apply(data)
end

-- Send a message: queued, echoed, and present in the strip payload.
-- A message too long for one frame would never go and would hold up the queue behind it.
do
	local queued = #ns.Transport.queue
	ns.Main.composer._text = string.rep("x", 2300)
	ns.Main:Send()
	check(#ns.Transport.queue == queued and #ns.Main.composer._text == 2300, "a message too long for the strip is refused, and the composer keeps it")
	ns.Main.composer._text = string.rep("x", 1900)
	ns.Main:Send()
	check(#ns.Transport.queue == queued + 1, "a long message that fits still goes")
	table.remove(ns.Transport.queue)
	ns.Transcript.echo[ns.viewId] = nil
end
ns.Main.composer._text = "Please run the tests"
ns.Main:Send()
check(#ns.Transport.queue >= 1, "command queued")
check(ns.Transport:Payload():find("Please run the tests", 1, true) ~= nil, "message in strip payload")
check(ns.Transport.queue[#ns.Transport.queue].args[3] == "steer", "follow-ups ask to steer by default")
ns.db.settings.steerFollowUps = false
ns.Main:Send("And the linter")
check(ns.Transport.queue[#ns.Transport.queue].args[3] == nil, "with steering off, a follow-up names no mode, so the bridge queues it")
ns.db.settings.steerFollowUps = true
check(ns.Transcript.echo[ns.viewId] ~= nil, "local echo shown")
-- The bridge reformats what you sent (markdown, escapes); the echo still goes when it arrives.
do
	local v = ns.Store.data.view
	if v and v.id == ns.viewId then
		local last = 0
		for _, m in ipairs(v.msgs or {}) do last = math.max(last, m.at or 0) end
		-- T3 Code renumbers its bounded window, so the new message can have a lower number.
		table.insert(v.msgs, { r = "u", t = "|cffa8c7fa  reformatted|r", at = last + 1, n = 1 })
		ns.Transcript:Refresh(true)
		check(ns.Transcript.echo[ns.viewId] == nil, "local echo dropped once the sent message arrives, reformatted")
		table.remove(v.msgs)
	end
end

-- Pages
ns.Main:ShowPage("usage")
ns.Main:ShowPage("settings")
ns.Main:ShowPage("threads")
check(true, "pages switch")

-- New thread flow
ns.Main:StartNewThread()
check(ns.Main.mode == "new" and ns.Main.newProject ~= nil, "new thread mode with project " .. tostring(ns.Main.newProject))
local hdr = ns.Main.frame.Pages.threads.Right.Header
check(ns.Transport:Payload():find(ns.Store.modelsHash, 1, true) ~= nil and ns.Store.modelsHash ~= "", "hello reports the model list it has: " .. ns.Store.modelsHash)
local function Choices(dd)
	local list = {}
	for _, o in ipairs(dd.options) do if not o.header then table.insert(list, o) end end
	return list
end
local groups = {}
for _, o in ipairs(hdr.Model.options) do if o.header then table.insert(groups, o.label) end end
check(hdr.Model:IsShown() and #Choices(hdr.Model) >= 1, "model picker shown for a new thread: " .. #Choices(hdr.Model) .. " models")
check(hdr.Model.options[1].header and #groups >= 2, "models grouped under headers: " .. table.concat(groups, ", "))
check(hdr.Model.Text:GetText():find(" · ", 1, true) ~= nil, "the button names the provider: " .. hdr.Model.Text:GetText())
do
	-- A search for a provider keeps its header and its models; headers aren't choices.
	local provider = groups[#groups]
	ns.UI.OpenList(hdr.Model)
	local l = ns.UI.ListOpen()
	l.Search:SetText(provider:lower())
	ns.UI.RefreshList()
	local at, others
	for n, o in ipairs(l.filtered) do
		if o.header and o.label == provider then at = n end
		-- Another provider's model may match on its own name ("GPT-5 Codex" under OpenCode, say).
		if not o.header and o.group ~= provider and o.group ~= "Recent" and not o.label:lower():find(provider:lower(), 1, true) then others = true end
	end
	check(at and l.filtered[at + 1] and not l.filtered[at + 1].header and not others, "searching a provider's name lists its models under its header")
	l:Hide()
end
do
	local seq = ns.Transport.stripSeq
	ns.Transport:Apply({ gen = data.gen + 1, threads = data.threads, projects = data.projects, bridge = data.bridge, usage = data.usage, models = { h = "00000000", g = {} } })
	check(ns.Transport.stripSeq ~= seq and ns.Transport:Payload():find("00000000", 1, true) ~= nil, "a new model list is announced straight away")
	check(ns.Store:ModelOptions("", nil) == nil, "an empty list clears the models")
	check(not hdr.Model:IsShown() and not hdr.Effort:IsShown(), "no models: neither picker is left on screen")
	data.gen = data.gen + 1
	ns.Transport:Apply({ gen = data.gen + 1, threads = data.threads, projects = data.projects, bridge = data.bridge, usage = data.usage, models = data.models })
	data.gen = data.gen + 1
	check(hdr.Model:IsShown(), "the list comes back")
end
check(ns.Main:ChosenNewModel() == nil and ns.Main:NewThreadModel() ~= nil, "no pick yet: the picker shows T3's default but sends none")
-- Pick the last model that has reasoning levels (any model when none has).
local pick
for _, o in ipairs(Choices(hdr.Model)) do
	if not pick or ns.Store:EffortOptions("", o.value) then pick = o end
end
ns.Main:PickModel(pick.value)
check(ns.db.models[ns.Main.newProject] == pick.value and ns.Main:NewThreadModel() == pick.value, "picked model remembered for the project: " .. pick.label)
local level
if hdr.Effort:IsShown() then
	local levels, default = ns.Store:EffortOptions("", pick.value)
	for _, o in ipairs(levels) do if o.value ~= default then level = o.value end end
	local proj = ns.Store.projectsById[ns.Main.newProject]
	local inherited = (proj.dm == pick.value and proj.de) or ns.Store:LastEffort("", pick.value) or default
	check(ns.Main:ChosenNewEffort() == nil and hdr.Effort.value == inherited, "no level picked: the picker shows the level the thread would get: " .. inherited)
	ns.Main:PickEffort(level)
	check(ns.db.efforts[ns.Main.newProject] == level and hdr.Effort.value == level, "picked level remembered for the project: " .. level)
else
	check(false, "the reasoning picker shows for " .. pick.label)
end
do
	local wt
	for _, cb in ipairs(ns.Settings.checks or {}) do if cb.key == "newWorktree" then wt = cb end end
	check(wt and not wt:GetChecked(), "worktree is a setting, off by default")
	wt:Click() -- a check button toggles itself, then the handler stores it
	check(ns.db.settings.newWorktree == true, "ticking the setting remembers worktree threads")
	ns.Main.composer._text = "Build a thing"
	ns.Main:Send()
	local pickI, pickS = ns.Store.SplitModelKey(pick.value)
	check(ns.Transport:Payload():find("Build a thing\031" .. pickI .. "\031" .. pickS .. "\031" .. (level or "") .. "\0311", 1, true) ~= nil, "the worktree setting rides along with the new thread")
	wt:Click()
	check(ns.db.settings.newWorktree == false, "unticking stops worktree threads")
end
ns.Transport:Apply({ gen = data.gen + 2, results = { { id = ns.Main.pendingNew, ok = true, open = firstThread.id } }, threads = data.threads, projects = data.projects, bridge = data.bridge, usage = data.usage, ack = { ui = ns.ui, seq = ns.Transport.stripSeq } })
check(ns.Main.mode == "thread" and ns.viewId == firstThread.id, "result opened the new thread")
check(#ns.Transport.queue == 0, "all commands acknowledged")
check(hdr.Model:IsShown(), "model picker shown for an open thread")
local cur = ns.Main:ThreadModel(ns.Store:Thread(ns.viewId))
local other
for _, o in ipairs(Choices(hdr.Model)) do if o.value ~= cur then other = o break end end
if other then
	ns.Main:PickModel(other.value)
	local oi, os_ = ns.Store.SplitModelKey(other.value)
	check(ns.Transport:Payload():find("\031model\031" .. ns.viewId .. "\031" .. oi .. "\031" .. os_, 1, true) ~= nil, "switching a thread's model sends model")
	check(hdr.Model.value == other.value, "the picker shows the new model straight away")
	ns.Transport:Apply({ gen = data.gen + 3, results = { { id = ns.Main.pendingModel.cmd, ok = false, msg = "Codex is switched off in T3 Code. Pick another model." } }, threads = data.threads, projects = data.projects, bridge = data.bridge, usage = data.usage, ack = { ui = ns.ui, seq = ns.Transport.stripSeq } })
	check(ns.Main.pendingModel == nil and hdr.Model.value == cur, "a refused switch puts the picker back")
end
do
	local t = ns.Store:Thread(ns.viewId)
	local levels = ns.Store:EffortOptions(ns.Store.EnvOf(t.id), ns.Store.ModelKey(t.mi, t.m))
	check(hdr.Effort:IsShown() == (levels ~= nil), "the reasoning picker shows when the thread's model has levels")
	if levels then
		local next
		for _, o in ipairs(levels) do if o.value ~= hdr.Effort.value then next = o.value break end end
		ns.Main:PickEffort(next)
		check(ns.Transport:Payload():find("\031model\031" .. ns.viewId .. "\031" .. t.mi .. "\031" .. t.m .. "\031" .. next, 1, true) ~= nil, "changing a thread's level sends model with it")
		check(hdr.Effort.value == next, "the picker shows the new level straight away")
		ns.Transport:Apply({ gen = data.gen + 4, results = { { id = ns.Main.pendingEffort.cmd, ok = false, msg = "That level is gone." } }, threads = data.threads, projects = data.projects, bridge = data.bridge, usage = data.usage, ack = { ui = ns.ui, seq = ns.Transport.stripSeq } })
		check(ns.Main.pendingEffort == nil and hdr.Effort.value ~= next, "a refused level puts the picker back")
	end
end

-- Question / approval rendering
data.gen = data.gen + 10
data.view = data.view or { id = ns.viewId }
data.view.id = ns.viewId
data.view.pending = { id = "req1", kind = "question", questions = { { id = "q1", h = "Mode", q = "Which mode?", opts = { { l = "Fast", d = "quick", v = "fast" }, { l = "Careful", d = "slow", v = "careful" } } } } }
ns.Transport:Apply(data)
local optionRows = 0
for _, r in ipairs(ns.Transcript.scrollBox._rows) do if r.ed.kind == "option" then optionRows = optionRows + 1 end end
check(optionRows >= 2, "question options rendered: " .. optionRows)
for _, r in ipairs(ns.Transcript.scrollBox._rows) do
	if r.ed.kind == "option" and r.ed.label == "Fast" then r.frame:Click() break end
end
check(ns.Transport:Payload():find("answer\031" .. ns.viewId .. "\031req1\031q1\031fast", 1, true) ~= nil, "answer command queued")

-- Dictation result from the bridge lands in the message box
ns.Main.composer._text = "Hello"
data.gen = data.gen + 1
data.dict = { n = os.time() * 1000, state = "done", text = "run the tests" }
ns.Transport:Apply(data)
check(ns.Main.composer._text == "Hello run the tests", "dictated text typed into the box: " .. tostring(ns.Main.composer._text))
data.gen = data.gen + 1
ns.Transport:Apply(data)
check(ns.Main.composer._text == "Hello run the tests", "same dictation not typed twice")
ns.Main.composer._text = "already pasted words"
data.gen = data.gen + 1
data.dict = { n = os.time() * 1000 + 5, state = "done", text = "pasted words" }
ns.Transport:Apply(data)
check(ns.Main.composer._text == "already pasted words", "text the backend already pasted isn't added again")
ns.Main.composer._text = ""

-- A desktop with no dictation backend (macOS today): the mic says why and sends nothing.
data.bridge.dictation = nil
data.bridge.dictationHint = "Dictation isn't available on macOS yet."
data.gen = data.gen + 1
ns.Transport:Apply(data)
Stub.printed = {}
local queued = #ns.Transport.queue
ns.Main.dictating = false
ns.Main.dictNoteAt = nil
ns.Main:ToggleDictation()
check(not ns.Main.dictating and #ns.Transport.queue == queued, "no dictation backend: nothing is sent")
check(Stub.printed[1] and Stub.printed[1]:find("macOS", 1, true) ~= nil, "the mic explains why: " .. tostring(Stub.printed[1]))
ns.Main:ToggleDictation()
check(#Stub.printed == 1, "a repeated press doesn't repeat the note")
ns.Main:Open()
ns.Main:Refresh()
check(not ns.Main.frame.Bar.Mic:IsEnabled(), "the mic is dimmed while there is no backend")
data.bridge.dictation = "test backend"
data.bridge.dictationHint = nil
data.gen = data.gen + 1
ns.Transport:Apply(data)
ns.Main:Refresh()
check(ns.Main.frame.Bar.Mic:IsEnabled(), "the mic is ready again once a backend is reported")

-- A refused dictate command doesn't leave the mic stuck on.
ns.Main.dictating = false
ns.Main:ToggleDictation()
check(ns.Main.dictating, "dictation starts when a backend is reported")
data.gen = data.gen + 1
ns.Transport:Apply({ gen = data.gen, results = { { id = ns.Main.dictCmd, ok = false, msg = "no microphone" } }, threads = data.threads, projects = data.projects, bridge = data.bridge, usage = data.usage, ack = { ui = ns.ui, seq = ns.Transport.stripSeq } })
check(not ns.Main.dictating, "a refused dictate command puts the mic back")

-- Read aloud: while something is being read, a speaker stops it instead of starting
-- over, and goes back by itself when the reading ends.
do
	local f = ns.Main.frame
	ns.Main:Open()
	ns.Main.mode = "thread"
	ns.Main:SelectThread(data.view.id)
	local function update(speech)
		data.gen = data.gen + 1
		data.speech = speech
		ns.Transport:Apply(data)
	end
	local function red(button)
		local _, g = button.Icon:GetVertexColor()
		return g < 1
	end
	local function replies()
		local list = {}
		for _, r in ipairs(ns.Transcript.scrollBox._rows or {}) do
			if r.ed.kind == "msg" and r.ed.msg.r == "a" then table.insert(list, r) end
		end
		return list
	end
	data.bridge.tts = "spd-say"
	ns.db.settings.tts = "system"
	update({})
	check(not ns.Reading() and not red(f.Bar.Speak), "nothing is read aloud to begin with")

	f.Bar.Speak:Click()
	local speak = ns.db.cmdId
	check(ns.Transport:Payload():find("\031speak\031" .. ns.viewId, 1, true) ~= nil, "the speaker asks the bridge to read the latest reply")
	check(ns.Reading() and red(f.Bar.Speak), "and turns red at once")
	check(ns.Main:StatusLine():find("reading aloud", 1, true) ~= nil, "the status line says something is being read")
	update({})
	check(ns.Reading(), "an update built before the bridge acted on the click leaves it red")
	update({ on = true, cmd = speak })
	f.Bar.Speak:Click()
	local hush = ns.db.cmdId
	check(hush == speak + 1 and ns.Transport:Payload():find("\031hush", 1, true) ~= nil, "a second click stops the reading instead of starting it over")
	check(not ns.Reading() and not red(f.Bar.Speak), "and the speaker is back at once")
	update({ on = true, cmd = speak })
	check(not ns.Reading(), "an update built before the stop doesn't bring it back")

	local list = replies()
	check(#list >= 2, "replies in the transcript have speakers: " .. #list)
	list[#list].frame.Speak:Click()
	local mine = ns.db.cmdId
	list = replies()
	check(red(list[#list].frame.Speak) and red(f.Bar.Speak) and not red(list[1].frame.Speak), "a reply's speaker turns red with the bar's, and the other replies' don't")
	update({ on = true, cmd = mine })
	update({ cmd = mine })
	list = replies()
	check(not ns.Reading() and not red(list[#list].frame.Speak) and not red(f.Bar.Speak), "when the bridge says the reading ended, every speaker goes back by itself")
	list[1].frame.Speak:Click()
	update({ cmd = ns.db.cmdId })
	check(not ns.Reading(), "a reading the bridge refused clears too")
	update({ on = true, cmd = ns.db.cmdId })
	check(ns.Reading() and red(f.Bar.Speak), "a reply the bridge reads by itself turns the bar's speaker red, so it can be stopped")
	f.Bar.Speak:Click()
	check(not ns.Reading() and ns.Transport:Payload():find("\031hush", 1, true) ~= nil, "and the speaker stops it")

	-- A bridge restarted during a reading has stopped it. Until it hears the window, its
	-- updates acknowledge nothing: once a click has gone, they say all there is about it.
	f.Bar.Speak:Click()
	update({ on = true, cmd = ns.db.cmdId })
	local ack = data.ack
	data.ack = nil
	update({})
	check(ns.Reading(), "an update from a bridge the click hasn't reached yet leaves it red")
	ns.Transport:Acknowledge(ns.Transport.stripSeq)
	update({})
	check(not ns.Reading() and not red(f.Bar.Speak), "once the click has gone, an update from a bridge that hasn't heard the window since clears it")
	data.ack = ack

	-- A bridge that doesn't send `speech` can't say when a reading ends, so the speaker
	-- reads as it did before it could stop a reading, and never turns red. That includes
	-- a reading shown before such a bridge took over.
	f.Bar.Speak:Click()
	update({ on = true, cmd = ns.db.cmdId })
	update(nil)
	check(not ns.Reading() and not red(f.Bar.Speak), "a bridge that stops saying when it reads takes the red away")
	ns.Transport:Acknowledge(ns.Transport.stripSeq)
	f.Bar.Speak:Click()
	check(ns.Transport:Payload():find("\031speak\031", 1, true) ~= nil and not ns.Reading() and not red(f.Bar.Speak), "with a bridge that doesn't report speech, the speaker reads without turning red")
	check(ns.Main:StatusLine():find("reading aloud", 1, true) == nil, "and the status line doesn't say it's reading")
	ns.Transport:Acknowledge(ns.Transport.stripSeq)

	local said, stopped = 0, 0
	C_VoiceChat.GetTtsVoices = function() return { { voiceID = 1, name = "Stub voice" } } end
	C_VoiceChat.SpeakText = function() said = said + 1 end
	C_VoiceChat.StopSpeakingText = function() stopped = stopped + 1 end
	ns.db.settings.tts = "game"
	local sent = ns.db.cmdId
	f.Bar.Speak:Click()
	check(said == 1 and ns.Reading() and red(f.Bar.Speak) and ns.db.cmdId == sent, "with the game's voice, the speaker reads in game and turns red")
	update({ cmd = sent })
	check(ns.Reading(), "the bridge's updates leave the game's voice alone")
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 1)
	check(not ns.Reading() and not red(f.Bar.Speak), "the game says when its voice is done, and the speaker goes back")
	f.Bar.Speak:Click()
	local before = stopped
	f.Bar.Speak:Click()
	check(said == 2 and stopped == before + 1 and not ns.Reading(), "a second click stops the game's voice")
	f.Bar.Speak:Click()
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_FAILED", 2, 13)
	check(not ns.Reading(), "so does a reading the game couldn't play")
	ns.Speak("First reply", ns.viewId, 1)
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_STARTED", 10)
	ns.Speak("Second reply", ns.viewId, 2)
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 10)
	check(ns.Reading(ns.ReadingKey(ns.viewId, 2)), "the end of a reading the next one cut off leaves the next one red")
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_STARTED", 11)
	check(ns.Reading(ns.ReadingKey(ns.viewId, 2)), "and so does the next one starting")
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_STARTED", 12)
	check(not ns.Reading(), "another utterance starting while ours goes on cut ours off")
	ns.Speak("Third reply", ns.viewId, 3)
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_STARTED", 13)
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 12)
	check(ns.Reading(), "only our utterance's end counts")
	Stub.Fire("VOICE_CHAT_TTS_PLAYBACK_FINISHED", 13)
	check(not ns.Reading(), "and it does")
	C_VoiceChat.GetTtsVoices = function() return {} end
	C_VoiceChat.SpeakText = function() end
	C_VoiceChat.StopSpeakingText = function() end
	ns.db.settings.tts = "auto"
	data.speech = {}
end

-- Plan, approval details, run summary, queued note
data.gen = data.gen + 1
for _, th in ipairs(data.threads) do if th.id == ns.viewId then th.s = "plan" end end
data.view = data.view or {}
data.view.id = ns.viewId
data.view.pending = nil
data.view.plan = "|cffffd100Plan|r\n• step one"
data.view.sum = "Last run: 2 commands · 4m 12s"
data.view.queued = 1
ns.Transport:Apply(data)
local found = {}
for _, r in ipairs(ns.Transcript.scrollBox._rows) do
	if r.ed.text then
		if r.ed.text:find("step one", 1, true) then found.plan = true end
		if r.ed.text:find("Last run", 1, true) then found.sum = true end
		if r.ed.text:find("queued", 1, true) then found.queued = true end
	end
	if r.ed.label == "Read the plan aloud" then found.readPlan = true end
end
check(found.plan and found.readPlan, "plan text shown with a read-aloud option")
check(found.sum and found.queued, "run summary and queued follow-ups shown")
data.gen = data.gen + 1
for _, th in ipairs(data.threads) do if th.id == ns.viewId then th.s = "input" end end
data.view.plan, data.view.queued = nil, nil
data.view.pending = { id = "ap1", kind = "approval", what = "Change files", detail = "", files = { { f = "a.lua", a = 12, d = 3 } }, always = true }
ns.Transport:Apply(data)
found = {}
for _, r in ipairs(ns.Transcript.scrollBox._rows) do
	if r.ed.text and r.ed.text:find("a.lua", 1, true) and r.ed.text:find("+12", 1, true) then found.files = true end
	if r.ed.label == "Always allow this" then found.always = r end
end
check(found.files, "approval lists the files with +/- counts")
found.always.frame:Click()
check(ns.Transport:Payload():find("approve\031" .. ns.viewId .. "\031ap1\031acceptAlways", 1, true) ~= nil, "Always allow sends acceptAlways")
data.gen = data.gen + 1
data.view.pending = nil
for _, th in ipairs(data.threads) do if th.id == ns.viewId then th.s = "waiting" th.run = true th.l = "Build bridge half" end end
ns.Transport:Apply(data)
check(ns.Main.frame.Bar.Stop:IsEnabled(), "a run waiting on its subagent can be stopped")
found = {}
for _, r in ipairs(ns.Transcript.scrollBox._rows) do
	if r.ed.live then found.live = r.ed.text end
	if r.ed.label == "Carry on" then found.option = true end
end
check(found.live and found.live:find("Build bridge half", 1, true) and not found.option, "the transcript shows what the run waits on, not quick replies")
data.gen = data.gen + 1
for _, th in ipairs(data.threads) do if th.id == ns.viewId then th.run = nil end end
ns.Transport:Apply(data)
check(not ns.Main.frame.Bar.Stop:IsEnabled(), "waiting between runs has nothing to stop")
data.gen = data.gen + 1
for _, th in ipairs(data.threads) do if th.id == ns.viewId then th.s = "open" th.l = nil end end
ns.Transport:Apply(data)

-- Notices wait during combat
_G.InCombatLockdown = function() return true end
local t1 = ns.Store.data.threads[2]
ns.Toasts.held = {}
ns:Fire("ThreadTransition", t1, "working", "open")
check(#ns.Toasts.held == 1, "notice held during combat")
_G.InCombatLockdown = function() return false end
ns:Fire("Combat", false)
check(#ns.Toasts.held == 0, "held notice shown after combat")

-- Search and machine filter
ns.ThreadList.query = "zzzz-no-match"
ns.ThreadList:Refresh(true)
local threadRows = 0
for _, r in ipairs(ns.ThreadList.scrollBox._rows) do if r.ed.thread then threadRows = threadRows + 1 end end
check(threadRows == 0, "search hides non-matching threads")
ns.ThreadList.query = nil
local groups = ns.Store:Groups("m:local")
check(#groups.working + #groups.open + #groups.settled > 0, "machine filter (this computer) keeps local threads")
groups = ns.Store:Groups("m:foundry")
check(#groups.working + #groups.open + #groups.settled == 0, "machine filter (foundry) excludes local threads")
ns.ThreadList:Refresh(true)

-- Report: diagnostics in the box + a screenshot request
ns.Main.composer._text = ""
ns.Main:Report("the list flickers")
check(ns.Main.composer._text:find("the list flickers", 1, true) and ns.Main.composer._text:find("diagnostics", 1, true), "report fills the message box")
check(ns.Transport:Payload():find("\031shot\031", 1, true) ~= nil, "report asks the bridge for a screenshot")
ns.Main.composer._text = ""

-- Suggestions above the message box: "/" lists the provider's slash commands, "$" its
-- skills. The checks bring their own list, so they don't depend on the snapshot's.
do
	local S, main = ns.Suggest, ns.Main
	local box = main.composer
	local eb = box:GetEditBox()
	for _, g in ipairs(data.models and data.models.g or {}) do
		for _, p in ipairs(g.p or {}) do
			if p.c then check(ns.Store:Commands(g.e or "", p.i) == p.c, "the snapshot's commands and skills are kept for " .. p.i .. ": " .. #p.c) end
		end
	end
	local env, instanceId = main:NextProvider()
	check(instanceId ~= nil, "the open thread's provider is known: " .. tostring(instanceId))
	local saved = ns.Store.commands
	local list = {
		{ t = "/pr-comments", d = "Get comments from a pull request" },
		{ t = "/compact", d = "Summarize the conversation" },
		{ t = "/review" },
		{ t = "/status", d = "Show || status" },
		{ t = "$deploy", d = "Ship it" },
		{ t = "$code-review", d = "Review the code" },
	}
	ns.Store.commands = { [env] = { [instanceId] = list } }
	local function typed(text, cursor)
		box._text, eb._cursor, box._focus = text, cursor, true
		Stub.Callback(box, "OnTextChanged", eb, true)
	end
	local function names()
		local out = {}
		for _, e in ipairs(S.state and S.state.matches or {}) do table.insert(out, e.t) end
		return table.concat(out, " ")
	end
	local queued = #ns.Transport.queue

	typed("/")
	check(S.state and S.frame:IsShown() and names() == "/pr-comments /compact /review /status", "a bare / lists every slash command: " .. names())
	local p = S.frame._points[1]
	check(p[1] == "BOTTOMLEFT" and p[2] == main.frame.Pages.threads.Right.ComposerInset and p[3] == "TOPLEFT", "the list sits on top of the message box")
	typed("$")
	check(names() == "$deploy $code-review", "$ lists the skills: " .. names())
	typed("/CO")
	check(names() == "/compact /pr-comments", "typing filters it, names that start with the text first: " .. names())
	typed("/zzz")
	check(S.state == nil and not S.frame:IsShown(), "nothing matches: no list")
	typed("path/to/file")
	check(S.state == nil, "a / inside a word is not a command")

	typed("/co")
	eb._scripts.OnKeyDown(eb, "DOWN")
	check(S.state.index == 2 and eb:GetCursorPosition() == 3, "Down moves the highlight and leaves the cursor where it was")
	eb._scripts.OnTabPressed(eb)
	check(box._text == "/pr-comments " and eb:GetCursorPosition() == #box._text and S.state == nil, "Tab puts the highlighted one in, with a space: " .. box._text)

	typed("fix this /re now", 12)
	check(names() == "/review", "a token mid-message is suggested too: " .. names())
	eb._scripts.OnTabPressed(eb)
	check(box._text == "fix this /review now" and eb:GetCursorPosition() == 17, "it replaces the token without doubling the space after it: " .. box._text)

	typed("/comp")
	Stub.Callback(box, "OnEnterPressed", eb)
	check(box._text == "/compact " and #ns.Transport.queue == queued and S.state == nil, "Enter with the list open puts the command in and sends nothing")
	local shift = IsShiftKeyDown
	_G.IsShiftKeyDown = function() return true end
	typed("/comp")
	Stub.Callback(box, "OnEnterPressed", eb)
	_G.IsShiftKeyDown = shift
	check(box._text == "/comp\n" and #ns.Transport.queue == queued, "Shift+Enter still starts a new line")

	local long = {}
	for i = 1, 20 do long[i] = { t = string.format("/cmd%02d", i) } end
	ns.Store.commands = { [env] = { [instanceId] = long } }
	typed("/")
	for _ = 1, 9 do eb._scripts.OnKeyDown(eb, "DOWN") end
	check(S.state.index == 10 and S.state.offset == 3 and S.frame.Rows[8].index == 10, "Down past the last row scrolls the list")
	S.frame._scripts.OnMouseWheel(S.frame, -1)
	check(S.state.offset == 6 and S.state.index == 10, "the wheel scrolls it")
	S.frame._scripts.OnMouseWheel(S.frame, 1)
	S.frame._scripts.OnMouseWheel(S.frame, 1)
	check(S.state.offset == 1 and S.state.index == 8, "and keeps the highlight among the rows on screen")
	ns.Store.commands = { [env] = { [instanceId] = list } }

	typed("/st")
	S.frame.Rows[1]:Click()
	check(box._text == "/status " and box._focus and S.state == nil, "a click picks it and keeps the message box focused")

	typed("/")
	Stub.Callback(box, "OnEscapePressed", eb)
	check(S.state == nil and not S.frame:IsShown() and box._focus, "Esc closes the list and keeps the message box")
	Stub.Callback(box, "OnEscapePressed", eb)
	check(not box._focus, "Esc again leaves the message box")

	typed("/compact please")
	check(S.state == nil, "past the token the list is closed")
	Stub.Callback(box, "OnEnterPressed", eb)
	check(#ns.Transport.queue == queued + 1 and ns.Transport:Payload():find("/compact please", 1, true) ~= nil, "Enter with the list closed sends the message as typed")
	table.remove(ns.Transport.queue)
	ns.Transcript.echo[ns.viewId] = nil

	box._focus, box._text = false, "/"
	Stub.Callback(box, "OnTextChanged", eb, true)
	check(S.state == nil, "no list while the message box isn't focused")
	typed("/")
	Stub.Callback(box, "OnTextChanged", eb, false)
	check(S.state == nil, "text the addon puts in the box closes the list")
	typed("/")
	main.frame:Hide()
	check(S.state == nil, "closing the window closes the list")
	main:Open()
	typed("/")
	main:StartNewThread()
	check(S.state == nil, "starting a new thread closes the list")
	main:Back()

	local insert = main.frame.Bar.Insert
	main:Refresh()
	check(insert:IsEnabled(), "the insert button is on when the provider has a list")
	box._text, eb._cursor = "run", nil
	insert:Click()
	local l = ns.UI.ListOpen()
	check(l and l.owner == insert and l._points[1][1] == "BOTTOMLEFT" and l._points[1][3] == "TOPLEFT", "it opens the shared list above itself")
	local headers, row = {}, nil
	for _, r in ipairs(l.Box._rows) do
		if r.ed.header then table.insert(headers, r.ed.label) end
		if r.ed.value == "$deploy" then row = r.frame end
	end
	check(table.concat(headers, ",") == "Commands,Skills", "commands and skills under their own headers: " .. table.concat(headers, ","))
	row:Click()
	check(ns.UI.ListOpen() == nil and box._text == "run $deploy " and box._focus, "a pick goes in at the cursor, after a space: " .. box._text)

	ns.Store.commands = {}
	main:Refresh()
	check(not insert:IsEnabled(), "the insert button is off when the provider has no list")
	typed("/")
	check(S.state == nil, "and typing / suggests nothing")

	ns.Store.commands = saved
	box:SetText("")
	box._focus = false
	ns.db.drafts[ns.viewId] = nil
	ns.db.drafts.__new = nil
	main:Refresh()
end

-- Attending flag: set while the window is in use, cleared after 90s idle
ns.Main:Open()
ns.Interacted()
Stub.Tick(0.1)
check(ns.Transport:Flags():find("a", 1, true) ~= nil, "attending while using the window")
Stub.now = Stub.now + 100
Stub.Tick(0.1)
check(ns.Transport:Flags():find("a", 1, true) == nil, "not attending after 90s idle")

-- Self-test runs
ns.SelfTest()
check(true, "self-test ran")

-- Window size
ns.db.settings.windowScale = "xlarge"
ns.Main:ApplyScale()
check(true, "window scale applied")
ns.db.settings.windowScale = "auto"

-- Transitions -> toast
local t = ns.Store.data.threads[1]
local before = t.s
data.gen = data.gen + 1
for _, th in ipairs(data.threads) do if th.id == t.id then th.s = "working" end end
ns.Transport:Apply(data)
data.gen = data.gen + 1
for _, th in ipairs(data.threads) do if th.id == t.id then th.s = "open" th.un = true end end
ns.Transport:Apply(data)
local toastShown = ns.Toasts.frames[1] and ns.Toasts.frames[1]._shown
check(toastShown or (ns.windowOpen and ns.viewId == t.id), "finish transition produced a toast")

-- Tracker and tickers run
ns.Tracker:Refresh()
for _ = 1, 5 do Stub.Tick(1) end
check(true, "tickers ran")

-- Gamepad mode: the window captures the controller itself.
Stub.gamepad = true
ns.Main.frame:Hide()
ns.Main:Open()
local f = ns.Main.frame
check(ns.Gamepad.capturing, "window captures the controller in gamepad mode")
local down = f._scripts.OnGamePadButtonDown
check(down ~= nil and f._scripts.OnGamePadStick ~= nil, "button and stick handlers installed")
ns.Gamepad:SelectDefault()
check(ns.Gamepad.selected ~= nil, "cursor starts on a control")
check(down(f, "PADDDOWN") == false, "D-pad consumed (character doesn't move)")
check(f._scripts.OnGamePadStick(f, "Left", 0, -1) == false, "left stick consumed")
check(down(f, "PADFORWARD") == false and f._shown == false and not ns.Gamepad.capturing, "Start closes the window and gives the controller back")
ns.Main:Open()
check(ns.Gamepad.capturing, "reopened window takes the controller again")
-- Commands and skills from the controller: the bar's insert button, then a row.
do
	local saved = ns.Store.commands
	local env, instanceId = ns.Main:NextProvider()
	ns.Store.commands = { [env] = { [instanceId] = { { t = "/compact" }, { t = "$deploy" } } } }
	ns.Main:Refresh()
	local insert, reachable = f.Bar.Insert, false
	for _, c in ipairs(ns.Gamepad:Candidates()) do if c.w == insert then reachable = true end end
	check(reachable, "the controller can reach the insert button")
	ns.Main.composer:SetText("")
	ns.Gamepad:Highlight(insert)
	down(f, "PAD1")
	check(ns.UI.ListOpen() and ns.UI.ListOpen().owner == insert, "A on it opens the list")
	down(f, "PAD1")
	check(ns.Main.composer._text == "/compact " and ns.Gamepad.selected == ns.Main.composer, "A on a row puts it in and lands on the message box")
	ns.Store.commands = saved
	ns.Main.composer:SetText("")
	ns.Main.composer._focus = false
	ns.Main:Refresh()
end
-- The model picker sits on the header row: D-pad to it, A opens its list, B closes it.
do
	local prevView = ns.viewId
	ns.Main:StartNewThread()
	ns.Gamepad:Highlight(hdr.Project)
	down(f, "PADDRIGHT")
	check(ns.Gamepad.selected == hdr.Model, "Right from the project goes to the model picker")
	down(f, "PAD1")
	local l = ns.UI.ListOpen()
	check(l ~= nil and l.owner == hdr.Model, "A opens the model list")
	local rows, onHeader = 0, false
	for _, c in ipairs(ns.Gamepad:Candidates()) do
		rows = rows + 1
		if c.ed and c.ed.header then onHeader = true end
	end
	check(rows > 0 and not onHeader, "the D-pad skips group headers in the list: " .. rows .. " rows")
	down(f, "PAD2")
	check(ns.UI.ListOpen() == nil and f._shown, "B closes the model list, not the window")
	if hdr.Effort:IsShown() then
		down(f, "PADDRIGHT")
		check(ns.Gamepad.selected == hdr.Effort, "Right from the model goes to the reasoning picker")
		down(f, "PAD1")
		local open = ns.UI.ListOpen()
		check(open ~= nil and open.owner == hdr.Effort, "A opens the reasoning list")
		down(f, "PAD2")
		down(f, "PADDLEFT")
		check(ns.Gamepad.selected == hdr.Model, "Left from the reasoning picker goes back to the model")
	end
	down(f, "PADDLEFT")
	check(ns.Gamepad.selected == hdr.Project, "Left goes back to the project")
	ns.Main:SelectThread(prevView)
end
check(down(f, "PADRSHOULDER") == false and ns.Main.page == "usage", "RB switched to usage")
down(f, "PADLSHOULDER")
check(ns.Main.page == "threads", "LB switched back")
down(f, "PAD4")
check(ns.Main.dictating, "Y starts dictation")
f._scripts.OnGamePadButtonUp(f, "PAD4")
check(not ns.Main.dictating, "Y release stops dictation")
-- X reads aloud like a speaker: on a thread that isn't open, that thread's latest
-- reply, and a second press stops it. The hint says what X does where the cursor is.
do
	local open, other
	for _, r in ipairs(ns.ThreadList.scrollBox._rows) do
		if r.ed.thread and r.ed.thread.id == ns.viewId then open = open or r
		elseif r.ed.thread then other = other or r end
	end
	local function hint(words) return (f.Pages.threads.Right.Hint:GetText() or ""):find(words, 1, true) ~= nil end
	local otherKey = ns.ReadingKey(other.ed.thread.id, "last")
	ns.Gamepad:Highlight(other.frame)
	down(f, "PAD3")
	check(ns.Reading(otherKey), "X on another thread reads its latest reply")
	check(hint("stop reading"), "the controller hint says X now stops it")
	down(f, "PAD3")
	check(not ns.Reading(), "X again stops it")
	ns.Gamepad:Highlight(open.frame)
	down(f, "PAD3")
	check(ns.Reading() and not ns.Reading(otherKey) and hint("stop reading"), "X on the open thread reads it as the speaker does, and the hint says X stops it")
	ns.Gamepad:Highlight(other.frame)
	check(hint("read aloud") and not hint("stop reading"), "on a thread that isn't being read, the hint says X reads it")
	down(f, "PAD3")
	check(ns.Reading(otherKey), "and X reads that one instead")
	down(f, "PAD3")
	check(not ns.Reading(), "and X again stops it")
end
-- A on a thread row opens it
for _, r in ipairs(ns.ThreadList.scrollBox._rows) do
	if r.ed.thread then ns.Gamepad:Highlight(r.frame) break end
end
ns.viewId = nil
down(f, "PAD1")
check(ns.viewId ~= nil, "A opened the highlighted thread")
-- D-pad routes between the list, the conversation and the message box
local function rowFor(id)
	for _, r in ipairs(ns.ThreadList.scrollBox._rows) do if r.ed.thread and r.ed.thread.id == id then return r.frame end end
end
data.gen = data.gen + 1
data.view = data.view or {}
data.view.id = ns.viewId
data.view.pending = nil
ns.Transport:Apply(data)
ns.Gamepad:Highlight(rowFor(ns.viewId) or ns.ThreadList.scrollBox._rows[2].frame)
down(f, "PADDRIGHT")
check(ns.Gamepad.selected == ns.Main.composer, "Right from the list goes to the message box")
down(f, "PADDDOWN")
check(ns.Gamepad.selected == f.Bar.Send, "Down from the message box goes to Send")
down(f, "PADDUP")
check(ns.Gamepad.selected == ns.Main.composer, "Up from Send goes back to the message box")
down(f, "PADDLEFT")
local sel = ns.Gamepad.selected
local onRow = false
for _, r in ipairs(ns.ThreadList.scrollBox._rows) do if r.frame == sel and r.ed.thread and r.ed.thread.id == ns.viewId then onRow = true end end
check(onRow, "Left from the conversation returns to the open thread's row")
data.gen = data.gen + 1
data.view.pending = { id = "req2", kind = "question", questions = { { id = "q", h = "Pick", q = "Which?", opts = { { l = "One", d = "", v = "1" }, { l = "Two", d = "", v = "2" } } } } }
ns.Transport:Apply(data)
down(f, "PADDRIGHT")
local selEd
for _, r in ipairs(ns.Transcript.scrollBox._rows) do if r.frame == ns.Gamepad.selected then selEd = r.ed end end
check(selEd and selEd.kind == "option" and selEd.label == "One", "Right goes straight to the first answer when the agent is asking")
down(f, "PADDDOWN")
for _, r in ipairs(ns.Transcript.scrollBox._rows) do if r.frame == ns.Gamepad.selected then selEd = r.ed end end
check(selEd and selEd.label == "Two", "Down steps to the next answer")
data.gen = data.gen + 1
data.view.pending = nil
ns.Transport:Apply(data)
-- A on the project dropdown opens a real list; the cursor moves inside it
ns.Gamepad:Highlight(ns.ThreadList.dropdown)
down(f, "PAD1")
local listFrame = ns.UI.ListOpen()
check(listFrame ~= nil, "A opens the project list")
local rows = listFrame.Box._rows or {}
check(#rows >= 2, "list shows the projects: " .. #rows)
local cands = ns.Gamepad:Candidates()
check(#cands == #rows, "cursor is confined to the list rows")
ns.Gamepad:SelectDefault()
check(ns.Gamepad.selected and ns.Gamepad.selected == rows[1].frame, "cursor starts on the current choice (All projects)")
ns.Gamepad:Highlight(rows[2].frame)
down(f, "PAD1")
check(ns.UI.ListOpen() == nil, "picking closes the list")
check(ns.db.settings.project == rows[2].ed.value, "picked project applied: " .. ns.db.settings.project)
ns.Gamepad:Highlight(ns.ThreadList.dropdown)
down(f, "PAD1")
down(f, "PAD2")
check(ns.UI.ListOpen() == nil and f._shown, "B closes the list, not the window")
ns.db.settings.project = "all"
-- Mouse: click opens, clicking a row picks
ns.ThreadList.dropdown._scripts.OnClick(ns.ThreadList.dropdown, "LeftButton")
check(ns.UI.ListOpen() ~= nil, "click opens the list")
ns.UI.ListOpen().Box._rows[2].frame:Click()
check(ns.db.settings.project ~= "all", "click on a row picks it")
ns.db.settings.project = "all"
-- B leaves the composer, then closes
ns.Main.composer._focus = true
down(f, "PAD2")
check(not ns.Main.composer._focus, "B leaves the message box")
down(f, "PAD2")
check(not f._shown, "B closes the window")
check(not ns.Gamepad.capturing, "controller released on close")

-- The open thread's family is a snapshot part of its own, like the transcript: kept
-- while `same` names it, recorded only when it was sent, and reported in the hello.
do
	local Store = ns.Store
	local savedView, savedFam = ns.viewId, data.fam
	ns.viewId = data.threads[1].id
	local fam = { id = ns.viewId, kids = { { id = "kid-1", t = "A child", s = "working", k = "sub" } } }
	local function apply(part)
		data.gen = data.gen + 1
		part.gen, part.threads, part.bridge, part.usage = data.gen, data.threads, data.bridge, data.usage
		part.ack = { ui = ns.ui, seq = ns.Transport.stripSeq }
		ns.Transport:Apply(part)
	end
	apply({ x = { l = "L1", p = "P1", v = "V1", f = "F1" }, projects = data.projects, view = data.view, fam = fam })
	check(Store.familyKey == "F1" and Store:Family() == fam, "the addon records the family it was sent")
	apply({ same = "pvf", x = { l = "L2", p = "P2", v = "V2", f = "F2" } })
	check(Store:Family() == fam and Store.familyKey == "F1", "an omitted family is kept, under the hash it came with")
	local tail = "\031V1\031F1"
	check(ns.Transport:Hello():sub(-#tail) == tail, "the hello ends with the family's hash, after the transcript's")
	apply({ same = "pv", x = { l = "L3", p = "P1", v = "V1", f = "" } })
	check(Store.data.fam == nil and Store.familyKey == "", "a family neither sent nor kept is gone, and its hash isn't claimed")
	ns.viewId, data.fam = savedView, savedFam
	data.gen = data.gen + 1
	ns.Transport:Apply(data)
end

-- A command the addon accepts must still fit beside the hello after the player opens a
-- subagent, whose id is about 125 characters, or it would never go.
do
	local T, Store = ns.Transport, ns.Store
	local savedView, savedQueue = ns.viewId, T.queue
	T.queue = {}
	local saved = { Store.listKey, Store.projectsKey, Store.viewKey, Store.familyKey }
	local hash = string.rep("a", 16)
	local project = Store.data.projects[1].id
	ns.viewId = nil
	Store.listKey, Store.projectsKey, Store.viewKey, Store.familyKey = hash, hash, "", ""
	local function accepted(n)
		local before = #T.queue
		T:Send("new", project, string.rep("x", n))
		if #T.queue == before then return false end
		table.remove(T.queue)
		return true
	end
	local lo, hi = 0, 3000
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if accepted(mid) then lo = mid else hi = mid end
	end
	check(lo >= 2000, "a new thread of 2,000 characters still goes: up to " .. lo)
	T:Send("new", project, string.rep("x", lo))
	ns.viewId = "e1~thread:delegated-task:" .. string.rep("s", 105)
	Store.viewKey, Store.familyKey = hash, hash
	check(T:Payload():find(string.rep("x", lo), 1, true) ~= nil, "the longest one accepted still fits once a subagent is open")
	-- A Claude subagent's id is longer still (about 210 characters): a command that no
	-- longer fits is dropped with a notice, so the commands behind it still go.
	ns.viewId = "e1~thread:delegated-task:" .. string.rep("s", 185)
	T:Send("read", "after-it")
	local payload = T:Payload()
	check(payload:find(string.rep("x", lo), 1, true) == nil and payload:find("after-it", 1, true) ~= nil and #T.queue == 1,
		"a command outgrown by a long thread id is dropped, and the queue behind it goes on")
	table.remove(T.queue)
	ns.viewId = "00000000-0000-0000-0000-000000000000"
	T:Send("send", ns.viewId, string.rep("x", 2000), "steer")
	check(#T.queue == 1, "a 2,000-character message to an open thread still goes")
	ns.viewId, T.queue = savedView, savedQueue
	Store.listKey, Store.projectsKey, Store.viewKey, Store.familyKey = saved[1], saved[2], saved[3], saved[4]
end

-- A subagent its provider started takes no messages (T3 Code refuses them): the window
-- says so and sends nothing.
do
	local savedFam, savedMode, wasShown = ns.Store.data.fam, ns.Main.mode, ns.Main.frame:IsShown()
	ns.Main.frame:Show()
	ns.Main.mode = "thread"
	ns.Store.data.fam = { id = ns.viewId, ro = true, up = { t = "Lead", k = "sub" } }
	ns.Main:Refresh()
	check(not ns.Main.frame.Bar.Send:IsEnabled(), "Send is off for a read-only subagent")
	local queued = #ns.Transport.queue
	ns.Main:Send("hello?")
	check(#ns.Transport.queue == queued, "and nothing is sent to it")
	ns.Store.data.fam, ns.Main.mode = savedFam, savedMode
	ns.Main:Refresh()
	check(ns.Main.frame.Bar.Send:IsEnabled(), "Send comes back for an ordinary thread")
	if not wasShown then ns.Main.frame:Hide() end
end

-- The family bar: the thread the open one came from, and the threads it started.
local FAMILY_PARENT = "thread:project:" .. string.rep("p", 36)
local function KidId(n) return "thread:delegated-task:" .. string.rep("c", 96) .. string.format("-%03d", n) end
local familyKids = {}
for n = 1, 31 do
	familyKids[n] = { id = KidId(n), t = "Child " .. n, s = n == 1 and "input" or (n <= 3 and "working" or "settled"), k = "sub", env = n == 4 and "laptop" or nil }
end
local function ParentFamily()
	local project = ns.Store.data.projects[1].id
	return { id = FAMILY_PARENT, me = { id = FAMILY_PARENT, title = "Refactor the slot writer", p = project, s = "working", l = "Working", st = time() - 600 }, kids = familyKids }
end
local function ChildFamily(n, up, kids)
	local project = ns.Store.data.projects[1].id
	return {
		id = KidId(n),
		me = { id = KidId(n), title = "Child " .. n, p = project, s = familyKids[n].s, l = "Settled", u = time() - 60 },
		up = up or { id = FAMILY_PARENT, t = "Refactor the slot writer", s = "working", k = "sub" },
		kids = kids,
	}
end
local function ShowFamily(fam)
	data.fam = fam
	data.view = { id = fam.id, msgs = {} }
	data.gen = data.gen + 1
	ns.Transport:Apply(data)
end
local savedFamily = { view = ns.viewId, fam = data.fam, data = data.view }
local bar = ns.Family.bar
local plain = ns.StripMarkup

do
	ns.Main:Open()
	ns.Main:SelectThread(FAMILY_PARENT)
	check(not f.Subtitle:GetText():find("No thread selected", 1, true), "a thread that isn't loaded yet is never shown as no thread selected")
	ShowFamily(ParentFamily())
	check(f.Subtitle:GetText() == "Refactor the slot writer" and hdr.Action:IsShown(), "a thread left out of the list gets its full header from the row sent with its family")
	check(bar:IsShown() and bar.Kids:IsShown() and not bar.Up:IsShown(), "a thread with children shows the Kids button, and no Up link without a parent")
	local insetTop
	for _, pt in ipairs(ns.Transcript.inset._points) do if pt[1] == "TOPLEFT" then insetTop = pt[2] end end
	check(insetTop == bar, "the conversation hangs under the bar")
	check(plain(bar.Kids:GetText()) == "Subagents (31) · 1 needs you", "Kids counts the children and how many need you: " .. plain(bar.Kids:GetText()))

	bar.Kids:Click()
	local l = ns.UI.ListOpen()
	check(l and l.owner == bar.Kids and #l.Box._rows == 31 and l.Search:IsShown(), "Kids opens the shared list with every child, and its search box")
	check(plain(l.Box._rows[1].ed.label) == "Needs you  Child 1" and plain(l.Box._rows[4].ed.label) == "Settled  Child 4  · laptop", "each row reads status first, then title, then another machine")
	l.Box._rows[5].frame:Click()
	check(ns.viewId == KidId(5) and not l:IsShown(), "clicking a child in the list opens it")
	check(f.Subtitle:GetText() == "Child 5" and hdr.Text:GetText():find("Loading…", 1, true) and not hdr.Action:IsShown(), "until its snapshot comes, the header shows the child from the family held, loading")
	check(not bar:IsShown(), "the bar waits for the child's own family")
	for _, pt in ipairs(ns.Transcript.inset._points) do if pt[1] == "TOPLEFT" then insetTop = pt[2] end end
	check(insetTop == hdr, "without the bar, the conversation hangs under the header")

	ShowFamily(ChildFamily(5))
	check(bar.Up:IsShown() and bar.Up:IsEnabled() and not bar.Kids:IsShown(), "a subagent's bar links to its parent")
	check(plain(bar.Up.Text:GetText()) == "Started by: Refactor the slot writer" and plain(bar.Up.Status:GetText()) == "Working", "Up names the parent and its status")
	check(f.Subtitle:GetText() == "Child 5" and hdr.Text:GetText():find("Settled", 1, true), "the child's header fills in from its own row")
	check(not hdr.Action:IsShown() and not hdr.Snooze:IsShown() and not hdr.Archive:IsShown() and not hdr.Model:IsShown() and not hdr.Effort:IsShown(), "a subagent's header has no Settle, Snooze or model picker: the thread that started it runs it")
	bar.Up:Click()
	check(ns.viewId == FAMILY_PARENT and f.Subtitle:GetText() == "Refactor the slot writer", "Up opens the parent, its title shown at once from the family held")
	check(plain(hdr.Text:GetText()) == "Working  ·  Loading…", "with its status, loading: " .. plain(hdr.Text:GetText()))

	for _, case in ipairs({
		{ up = { id = FAMILY_PARENT, t = "Base", s = "open", k = "fork" }, text = "Forked from: Base" },
		{ up = { id = FAMILY_PARENT, t = "Base", s = "open", k = "side" }, text = "Side chat of: Base" },
		{ up = { id = "e1~sender", t = "Base", s = "open", k = "sent", env = "laptop" }, text = "Sent from laptop: Base" },
		{ up = { t = "Base", k = "sent" }, text = "Sent from another computer: Base", off = true },
	}) do
		ns.Main:SelectThread(KidId(6))
		ShowFamily(ChildFamily(6, case.up))
		check(plain(bar.Up.Text:GetText()) == case.text and bar.Up:IsEnabled() == not case.off, "Up reads " .. case.text .. (case.off and ", and can't be opened" or ""))
	end

	local function label(kinds, statuses)
		local kids = {}
		for n, k in ipairs(kinds) do kids[n] = { k = k, s = statuses[n] } end
		return plain(ns.Family.KidsLabel(kids))
	end
	check(label({ "fork", "fork" }, { "open", "settled" }) == "Forks (2)", "Kids names forks")
	check(label({ "side" }, { "working" }) == "Side chats (1) · 1 working", "Kids names side chats, with how many are working")
	check(label({ "sent", "sent" }, { "input", "plan" }) == "Sent to other computers (2) · 2 need you", "Kids names threads sent away, with how many need you")
	check(label({ "sub", "fork", "sent" }, { "waiting", "working", "open" }) == "Started here (3) · 2 working", "mixed children are threads started here")
end

-- Controller: the bar is a row of its own in the conversation column.
do
	local G = ns.Gamepad
	check(G.capturing, "the controller drives the window")
	local grandkids = { { id = "thread:grandchild", t = "Grandchild", s = "open", k = "sub" } }
	ns.Main:SelectThread(KidId(7))
	ShowFamily(ChildFamily(7, { id = FAMILY_PARENT, t = "Refactor the slot writer", s = "working", k = "fork" }, grandkids))
	check(hdr.Action:IsShown(), "a fork keeps its own Settle")
	G:Highlight(hdr.Action)
	down(f, "PADDDOWN")
	check(G.selected == bar.Up, "Down from Settle goes to Up")
	down(f, "PADDRIGHT")
	check(G.selected == bar.Kids, "Right from Up goes to Kids")
	down(f, "PADDLEFT")
	check(G.selected == bar.Up, "Left from Kids goes back to Up")
	down(f, "PADDLEFT")
	local inList = false
	for _, r in ipairs(ns.ThreadList.scrollBox._rows) do if r.frame == G.selected and r.ed.thread then inList = true end end
	check(inList, "Left past Up goes to the thread list")
	G:Highlight(bar.Up)
	down(f, "PADDUP")
	check(G.selected == hdr.Action, "Up from the bar goes back to Settle")
	G:Highlight(ns.Main.composer)
	down(f, "PADDUP")
	check(G.selected == bar.Up, "Up from the message box goes to the bar")

	down(f, "PAD1")
	check(ns.viewId == FAMILY_PARENT and G.selected == ns.Main.composer, "A on Up opens the parent; the cursor waits on the message box")
	ShowFamily(ParentFamily())
	check(G.selected == bar.Kids, "once the parent's bar shows, the cursor is on Kids, the way back")

	down(f, "PAD1")
	local l = ns.UI.ListOpen()
	check(l and l.owner == bar.Kids, "A on Kids opens the list")
	local function onRow()
		for _, r in ipairs(l.Box._rows) do if r.frame == G.selected then return r.ed.value end end
	end
	check(onRow() == KidId(1), "the cursor starts on the first child")
	for _ = 1, 40 do down(f, "PADDDOWN") end
	check(onRow() == KidId(31), "Down walks the list by its order to the last of 31 children")
	down(f, "PADDUP")
	check(onRow() == KidId(30), "and Up steps back")
	down(f, "PADDDOWN")
	-- In game the list's close is handled a frame later; run the timers in that order.
	local queued, after = {}, C_Timer.After
	C_Timer.After = function(_, fn) table.insert(queued, fn) end
	down(f, "PAD1")
	C_Timer.After = after
	for _, fn in ipairs(queued) do fn() end
	check(ns.viewId == KidId(31) and G.selected == ns.Main.composer, "A opens that child, and the list closing doesn't pull the cursor off the message box")
	ShowFamily(ChildFamily(31))
	check(G.selected == bar.Up, "once the child's bar shows, the cursor is on Up, the way back")
	down(f, "PADDUP")
	check(G.selected == bar.Up, "on a subagent the bar is the top of the column")

	down(f, "PAD1")
	down(f, "PADDDOWN")
	ShowFamily(ParentFamily())
	check(ns.viewId == FAMILY_PARENT and G.selected == f.Bar.Send, "a cursor the player moved while it loaded stays where they put it")

	ns.Main:SelectThread(KidId(8))
	ShowFamily(ChildFamily(8, { t = "Elsewhere", k = "sent" }))
	local candidate = false
	for _, c in ipairs(G:Candidates()) do if c.w == bar.Up then candidate = true end end
	check(bar.Up:IsShown() and not candidate, "a link to a computer the bridge doesn't know is shown, but the cursor can't land on it")
	G:Highlight(hdr.Action)
	down(f, "PADDDOWN")
	check(G.selected == ns.Main.composer, "Down from Settle passes it by")
end

ns.Main:SelectThread(savedFamily.view)
data.fam, data.view = savedFamily.fam, savedFamily.data
data.gen = data.gen + 1
ns.Transport:Apply(data)
f:Hide()

-- Launching without a keyboard
check(ns.Launcher.chord == "PADLTRIGGER-PADRTRIGGER-PADBACK", "controller shortcut: both triggers + Back")
check(next(Stub.overrides) == nil, "no key bindings overridden (Forever's controller mode ignores them)")
GameMenuFrame:InitButtons()
local entry
for _, b in ipairs(GameMenuFrame.buttons) do if b.text == "T3 Code" then entry = b end end
check(entry and entry.layoutIndex == 4.5, "game menu entry sits above Log Out")
_G.HideUIPanel = function() end
entry.cb()
check(f._shown, "game menu entry opens the window")
T3Code_Binding("toggle")
check(not f._shown, "shortcut toggles it closed")
check(#(ns.db.errors or {}) == 0, "no errors recorded")

-- Slash command
SlashCmdList.T3CODE("status")
check(#Stub.printed > 0, "status printed: " .. Stub.printed[#Stub.printed])

-- Self-test: the long control plays, the empty one doesn't -> bells usable
Stub.validSounds = { ["Interface\\AddOns\\T3Code\\Signals\\03999.wav"] = true }
ns.Transport.signals = "untested"
ns.Transport.testing = nil
ns.Transport:SelfTest()
check(ns.Transport.signals == "ok", "self-test passes when the long control plays: " .. ns.Transport.signals)
Stub.validSounds = {}
ns.Transport.testing = nil
ns.Transport:SelfTest()
check(ns.Transport.signals == "muted", "self-test fails when nothing really plays (Forever says willPlay=true anyway)")
ns.Transport.signals = "ok"

-- A bell rung a couple of numbers ahead is still heard; bells map onto 8 rotating
-- files. Only a fresh snapshot moves the bell position (to the bridge's nextSig).
local function BellPath(k) return string.format("Interface\\AddOns\\T3Code\\Signals\\%05d.wav", 3991 + (k - 1) % 8) end
local freshFile = os.tmpname()
do
	local fh = assert(io.open(freshFile, "w"))
	fh:write(string.format("dofile(%q) T3Code_Inbox.gen = 9e15 T3Code_Inbox.nextSig = 503\n", snapshot))
	fh:close()
end
ns.Transport.exhausted = nil
ns.Transport.bellProbe = nil
ns.Transport.ringCooldownUntil = nil
ns.db.sigNext = 500
Stub.slotData[ns.Transport.slotCursor] = freshFile
Stub.validSounds = { [BellPath(502)] = true }
local loadsBefore = Stub.loadCount or 0
Stub.Tick(0.6) -- starts listening
Stub.Tick(0.2) -- checks which bell is really playing
check((Stub.loadCount or 0) > loadsBefore, "loaded a slot when bell 502 rang")
check(ns.db.sigNext == 503, "took the bridge's next bell from the fresh snapshot: " .. ns.db.sigNext)

-- A bell that leads to old data is a false alarm: no moving ahead (which would
-- alias still-rung bells and run away), a short cooldown, and a fresh strip.
Stub.validSounds = { [BellPath(504)] = true }
local loads1 = Stub.loadCount
ns.Transport.bellProbe = nil
Stub.Tick(0.6)
Stub.Tick(0.2)
check(Stub.loadCount == loads1 + 1 and ns.db.sigNext == 503, "false ring: one slot loaded, position kept at " .. ns.db.sigNext)
check(ns.Transport.falseRings == 1 and ns.Transport.stripShown, "false ring counted and the strip redrawn")
Stub.Tick(0.6)
Stub.Tick(0.2)
check(Stub.loadCount == loads1 + 1, "cooldown: no slot burned by the same false alarm")

-- An addon the bridge can't hear (one it didn't see reload, say) hears that bell again and
-- again, with nothing new behind it, and its strip goes unanswered. Each such load waits
-- longer than the last, up to two minutes, instead of spending a slot every few seconds.
do
	local loads0 = Stub.loadCount
	for _ = 1, 600 do Stub.Tick(0.2) end
	local spent = Stub.loadCount - loads0
	check(spent <= 6 and ns.db.sigNext == 503, "a bell that keeps leading to old data costs " .. spent .. " slots in two minutes")
	local waited = ns.Transport.ringCooldownUntil - Stub.now
	ns.Transport:Send("ping")
	Stub.Tick(0.6)
	Stub.Tick(0.2)
	check(waited > 30 and Stub.loadCount == loads0 + spent + 1, "the player sending something tries again at once")
	Stub.slotData[ns.Transport.slotCursor] = freshFile
	T3Code_Inbox = nil
	ns.db.gen = 0
	Stub.now = Stub.now + 4
	Stub.Tick(0.6)
	Stub.Tick(0.2)
	check(Stub.loadCount == loads0 + spent + 2 and not ns.Transport.ringCooldownUntil, "news ends the waiting")
	ns.Transport.queue = {}
	ns.Transport:HideStrip()
end

-- Once the bridge hears the addon again, it answers with an update and rings for it.
-- A ring fills one bell and empties the one four before it, so one of the four the
-- addon listens to changes either way: that is news to try at once, however long the
-- wait has grown. A bell that stays as it was waits as before.
do
	local function backOff()
		Stub.validSounds = { [BellPath(504)] = true }
		ns.Transport.bellProbe = nil
		for _ = 1, 600 do Stub.Tick(0.2) end
		return (ns.Transport.ringCooldownUntil or 0) - Stub.now
	end
	local function recovered(sounds)
		local loads0 = Stub.loadCount
		Stub.slotData[ns.Transport.slotCursor] = freshFile
		T3Code_Inbox = nil
		ns.db.gen = 0
		Stub.validSounds = sounds
		local t0 = Stub.now
		repeat Stub.Tick(0.2) until Stub.loadCount > loads0 or Stub.now - t0 > 30
		return Stub.now - t0, Stub.loadCount - loads0
	end
	local waited = backOff()
	local took, loaded = recovered({ [BellPath(504)] = true, [BellPath(505)] = true })
	check(waited > 30 and loaded == 1 and took < 2 and not ns.Transport.ringCooldownUntil and ns.db.gen > 0,
		string.format("a bell rung for fresh data during a %.0f s wait is loaded after %.1f s", waited, took))
	waited = backOff()
	ns.Transport:HideStrip()
	ns.Transport:Touch()
	took, loaded = recovered({ [BellPath(508)] = true })
	check(waited > 30 and loaded == 1 and took < 8 and not ns.Transport.ringCooldownUntil and ns.db.gen > 0,
		string.format("so is the update behind a ring that emptied the bell it waited on, through the strip, after %.1f s", took))
	ns.Transport.queue = {}
	ns.Transport:HideStrip()
end

-- A laggy client: even the empty control still "plays" at check time. Wait it out
-- instead of trusting the bells.
Stub.now = Stub.now + 5
ns.Transport:HideStrip() -- (as if the bridge acknowledged it; isolates the bell check)
ns.Transport.lastLoadAt = Stub.now
ns.Transport.bellProbe = nil
Stub.validSounds = { [BellPath(503)] = true, ["Interface\\AddOns\\T3Code\\Signals\\04000.wav"] = true }
local loads2 = Stub.loadCount
for _ = 1, 12 do Stub.Tick(0.2) end
check(Stub.loadCount == loads2, "no slot loaded while the client is too slow to tell bells apart")
Stub.validSounds = {}
ns.Transport.bellProbe = nil
local loads3 = Stub.loadCount
Stub.Tick(0.6)
Stub.Tick(0.2)
check(Stub.loadCount == loads3, "no slot spent while no bell rings")
os.remove(freshFile)

-- Controller shortcut: hold both triggers, press Back. Read from the controller's
-- state only: the watcher must never take gamepad input (that breaks LT + RT action bars).
do
	local L = ns.Launcher
	L:SetupChord()
	check(L.chordText and L.chordText:find("Left trigger", 1, true) and L.chordText:find("Gamepad_Ltr_View", 1, true), "shortcut shown as the player's buttons: " .. tostring(L.chordText))
	check(not L.chordText:find("RT", 1, true), "no hard-coded Xbox names")
	local w = L.watcher
	check(w._scripts.OnGamePadButtonDown == nil and not w._gamepadEnabled, "the watcher never takes controller input")
	local function frame() Stub.now = Stub.now + 0.06 w._scripts.OnUpdate(w, 0.06) end
	local wasOpen = ns.windowOpen
	WOWSTUB.padHeld = { PADLTRIGGER = true, PADRTRIGGER = true }
	frame()
	check(ns.windowOpen == wasOpen, "holding the triggers alone does nothing (LT + RT action bars stay the game's)")
	WOWSTUB.padHeld.PADBACK = true
	frame()
	check(ns.windowOpen ~= wasOpen, "triggers + Back toggles T3 Code")
	frame()
	frame()
	check(ns.windowOpen ~= wasOpen, "holding Back doesn't toggle it again")
	WOWSTUB.padHeld = { PADBACK = true }
	if ns.windowOpen ~= wasOpen then ns.Launcher:Open() end
	frame()
	WOWSTUB.padHeld = {}
	frame()
	WOWSTUB.padHeld = { PADBACK = true }
	frame()
	check(ns.windowOpen == wasOpen, "Back on its own is left to the game")
	WOWSTUB.padHeld = {}
	frame()

	-- Back a moment before the triggers: with a 20 Hz read the two can land on
	-- different frames, and the chord must still fire.
	WOWSTUB.padHeld = { PADBACK = true }
	frame()
	WOWSTUB.padHeld = { PADBACK = true, PADLTRIGGER = true, PADRTRIGGER = true }
	frame()
	check(ns.windowOpen ~= wasOpen, "Back a moment before the triggers still opens it")
	frame()
	frame()
	check(ns.windowOpen ~= wasOpen, "and holding all three doesn't toggle it again")
	if ns.windowOpen ~= wasOpen then ns.Launcher:Open() end
	WOWSTUB.padHeld = {}
	frame()
end

-- Tracker section follows the objective tracker, in the quest column.
do
	local f = ns.Tracker.frame
	local function anchoredTo(target)
		for _, pt in ipairs(f._points or {}) do if pt[2] == target then return true end end
		return false
	end
	WOWSTUB.Tick(0.3)
	check(ns.Tracker.attached == "below" and anchoredTo(ObjectiveTrackerFrame.NineSlice), "tracker section sits under the quests: " .. tostring(ns.Tracker.attached))
	check(f:GetWidth() == 280, "same width as the objective tracker")
	ObjectiveTrackerFrame.isCollapsed = true
	for _, t in ipairs(WOWSTUB.tickers) do t.fn() end
	check(ns.Tracker.attached == "header" and anchoredTo(ObjectiveTrackerFrame.Header), "under the header when All Objectives is collapsed")
	ObjectiveTrackerFrame.isCollapsed = nil
	ObjectiveTrackerFrame._shown = false
	for _, t in ipairs(WOWSTUB.tickers) do t.fn() end
	check(ns.Tracker.attached == "replace", "takes the tracker's place when it's empty")
	ObjectiveTrackerFrame._shown = true
	ns.db.settings.trackerPoint = { "CENTER", "CENTER", 10, 10 }
	for _, t in ipairs(WOWSTUB.tickers) do t.fn() end
	check(ns.Tracker.attached == "custom", "a dragged position is kept")
	ns.db.settings.trackerPoint = nil
	for _, t in ipairs(WOWSTUB.tickers) do t.fn() end
	check(ns.Tracker.attached == "below", "reset reattaches it")

	-- A link that goes stale on its own clock, with no update arriving to say so, still
	-- reaches the tracker: the once-a-second tick notices the state changed.
	-- The notice shows only beside a thread, and the snapshot may have none running.
	local savedThreads = ns.Store.data.threads
	ns.Store.data.threads = { { id = "w1", title = "Working", s = "working", st = time() - 60, p = "p" } }
	ns.Transport.bridgeNow = time() - 1000
	ns.Tracker:RefreshTimers()
	local found = false
	for _, b in ipairs(f.Lines) do
		if b._shown and b.Title:GetText():find("Connection lost", 1, true) then found = true end
	end
	check(found, "the tracker says the connection was lost")
	ns.Transport.bridgeNow = time()
	ns.Tracker:RefreshTimers()
	found = false
	for _, b in ipairs(f.Lines) do
		if b._shown and b.Title:GetText():find("Connection lost", 1, true) then found = true end
	end
	check(not found, "and that it is back")
	ns.Store.data.threads = savedThreads
	ns.Tracker:Refresh()
end

-- An update from the bridge that doesn't answer what the strip says now.
local function UpdateWithoutAnswer()
	local d = ns.Store.data
	ns.Transport:Apply({ gen = ns.db.gen + 1, now = time(), threads = d.threads, projects = d.projects, bridge = d.bridge, usage = d.usage, ack = { ui = ns.ui, seq = ns.Transport.ackedSeq } })
end

-- The bridge can't read the strip, so what the player clicks never arrives, although
-- updates still do. After a few seconds without an answer, and an update since that
-- shows the bridge is running, the status line says so, and it goes back once the
-- bridge answers.
do
	ns.Transport:Acknowledge(ns.Transport.stripSeq)
	ns.Transport.queue = {}
	check(ns.Transport:BridgeState() == "connected", "connected, nothing waiting")
	ns.Transport:Send("ping")
	Stub.now = Stub.now + 3
	check(ns.Transport:BridgeState() == "connected", "a few seconds without an answer is normal")
	Stub.now = Stub.now + 6
	check(ns.Transport:BridgeState() ~= "unheard" and ns.Main:StatusLine():find("can't hear", 1, true) == nil, "unanswered with no update since, the bridge may have stopped, so the strip isn't blamed")
	UpdateWithoutAnswer()
	check(ns.Transport:BridgeState() == "unheard" and ns.Main:StatusLine():find("can't hear the game", 1, true) ~= nil, "an update that arrives without the answer: the status line says T3 Code can't hear the game")
	ns.Transport:Acknowledge(ns.Transport.stripSeq)
	check(ns.Transport:BridgeState() == "connected" and ns.Main:StatusLine():find("can't hear", 1, true) == nil, "an answer clears it")
end

-- With T3 Code offline, that is what the player needs to know: an unanswered strip
-- doesn't replace it, in the window or in the tracker.
do
	local bridge, thread = ns.Store.data.bridge, ns.Store.data.threads[1]
	local t3, status, tracker = bridge.t3, thread.s, ns.db.settings.tracker
	bridge.t3, thread.s, ns.db.settings.tracker = "offline", "working", true
	ns.Transport:Send("ping")
	Stub.now = Stub.now + 9
	UpdateWithoutAnswer()
	ns.Tracker:Refresh()
	local lost = false
	for _, line in ipairs(ns.Tracker.frame.Lines) do
		if line:IsShown() and not line.thread and (line.Title:GetText() or ""):find("Connection lost", 1, true) then lost = true end
	end
	check(ns.Transport:BridgeState() == "t3offline" and lost and ns.Main:StatusLine():find("T3 Code is offline", 1, true) ~= nil,
		"with T3 Code offline, an unanswered strip leaves the tracker's Connection lost and the status line as they were")
	ns.Transport:Acknowledge(ns.Transport.stripSeq)
	bridge.t3, thread.s, ns.db.settings.tracker = t3, status, tracker
	ns.Tracker:Refresh()
end

-- Minimap button
do
	local mb = ns.MinimapButton.button
	check(mb ~= nil, "minimap button created")
	local wasOpen = ns.windowOpen
	mb._scripts.OnClick(mb, "LeftButton")
	check(ns.windowOpen ~= wasOpen, "minimap click toggles the window")
	mb._scripts.OnClick(mb, "LeftButton")
	mb._scripts.OnEnter(mb)
	mb._scripts.OnDragStart(mb)
	mb._scripts.OnDragStop(mb)
	check(type(ns.db.settings.minimapAngle) == "number", "minimap drag saves its position")
	ns.db.settings.minimapButton = false
	ns.MinimapButton:Refresh()
	check(mb._shown == false, "minimap button can be hidden")
	ns.db.settings.minimapButton = true
	ns.MinimapButton:Refresh()
	-- Waiting on a watched PR isn't "needs you": no badge for it, but there is for input.
	local saved = ns.Store.data.threads
	ns.Store.data.threads = { { id = "w1", title = "Waiting", s = "waiting", l = "Watching pull request #7", st = time() - 60, p = "p" } }
	ns.MinimapButton:Refresh()
	check(not mb.Badge:IsShown(), "a waiting thread doesn't badge the minimap button")
	mb._scripts.OnEnter(mb)
	ns.Tracker:Refresh()
	check(ns.Store.GROUP_OF.waiting == "working", "waiting threads are listed under Working")
	check(ns.Store.GROUP_OF.input == "open" and ns.Store.GROUP_OF.plan == "open", "threads that need you are listed under Open, as in T3 Code")
	ns.Store.data.threads[2] = { id = "i1", title = "Input", s = "input", l = "Needs your approval", p = "p" }
	ns.MinimapButton:Refresh()
	check(mb.Badge:IsShown(), "a thread that needs the player badges the minimap button")
	ns.Store.data.threads = saved
	ns.MinimapButton:Refresh()
	ns.Tracker:Refresh()
end

-- Design switch: the window rebuilds under the chosen design, keeping the open
-- page, the draft and the selection.
do
	ns.Main:Open()
	local rowThread
	for _, r in ipairs(ns.ThreadList.scrollBox._rows or {}) do
		if r.ed.thread then rowThread = r.ed.thread break end
	end
	if rowThread then ns.Main:SelectThread(rowThread.id) end
	local old = ns.Main.frame
	local page = ns.Main.page
	ns.Main.composer:SetText("a draft survives the switch")
	ns.db.settings.windowSize = { 820, 520 }
	local function rgba(c, token)
		return c and token and c[1] == token[1] and c[2] == token[2] and c[3] == token[3] and (c[4] or 1) == (token[4] or 1)
	end
	local function painted(widget, token)
		for _, r in ipairs(widget and widget._regions or {}) do
			if rgba(r._color, token) then return r end
		end
	end
	local function labelOf(button)
		for _, r in ipairs(button and button._regions or {}) do
			if r._kind == "FontString" then return r end
		end
	end
	check(ns.Settings.design.value == "classic", "the design dropdown starts on the game's look")
	ns.Settings.design:Step(1)
	local f = ns.Main.frame
	check(f ~= old and ns.db.settings.theme == "modern", "choosing modern in the design dropdown rebuilds the window")
	check(ns.db.settings.accent == "class" and ns.db.settings.palette == "tokyo-night" and ns.Theme.ACCENT_HEX == "ff7aa2f7", "the window starts on Tokyo Night with class color, and the theme's accent until the class is known")
	check(ns.Color("gold", "Start") == "|c" .. ns.Theme.ACCENT_HEX .. "Start|r", "a heading uses the accent instead of the game's gold")
	-- Every color text carries is the theme's, so a light theme stays readable.
	local mk = ns.Theme.MARKUP
	check(mk.white == "ffa9b1d6" and mk.grey == "ff565f89" and mk.red == "fff7768e" and mk.green == "ff9ece6a"
		and mk.orange == "ffeb927b" and mk.blue == "ff7aa2f7" and mk.agent == mk.blue, "the game's text colors map to Tokyo Night's")
	local mapped = true
	for key in pairs(ns.COLORS) do
		if ns.Color(key, "x") ~= "|c" .. mk[key] .. "x|r" or ns.ChatColor(key, "x") ~= "|c" .. ns.COLORS[key] .. "x|r" then mapped = false end
	end
	check(mapped, "every color key maps to the theme in the window, and stays the game's in chat")
	check(ns.Theme.Markup("|cffffd100Plan|r and |cffff4040no|r, |cFF9D9D9Dquiet|r |cff123456own|r") == "|c" .. mk.gold .. "Plan|r and |c" .. mk.red .. "no|r, |c" .. mk.grey .. "quiet|r |cff123456own|r", "a message's game colors become the theme's, and other colors stay")
	local printed = #Stub.printed
	ns.Print("still gold")
	check(Stub.printed[printed + 1]:find("|cffffd100T3 Code|r", 1, true) ~= nil, "chat keeps the game's gold while the window uses the accent")
	check(f:IsShown(), "the window stays open across the switch")
	check(ns.Main.page == page, "the open page survives the switch")
	check(ns.Main.composer:GetInputText() == "a draft survives the switch", "the draft survives the switch")
	check(f._w == 820 and f._h == 520, "a saved window size is applied to the rebuilt window")
	local theme = ns.Theme.MODERN
	local ground, accent, panel = theme.windowBg, theme.accent, theme.panel
	local hairline, muted, text, onAccent = theme.hairline, theme.muted, theme.text, theme.onAccent
	check(f.ModernBg._color[1] == ground[1] and f.ModernBg._color[2] == ground[2] and f.ModernBg._color[3] == ground[3], "the modern ground is painted")
	check(math.abs(f.ModernBg._color[4] - 0.94) < 0.001, "the window starts at the dusk transparency")
	do
		local savedView = ns.Store.data.view
		ns.Store.data.view = {
			id = ns.viewId,
			msgs = {
				{ r = "u", t = "hello", at = 1, n = 1 },
				{ r = "a", t = "hi", at = 2, n = 2, live = true },
			},
		}
		ns.Transcript:Refresh(true)
		local youLabel, agentLabel
		for _, r in ipairs(ns.Transcript.scrollBox._rows or {}) do
			if r.ed and r.ed.kind == "msg" and r.frame and r.frame.Label then
				if r.ed.msg.r == "u" then youLabel = r.frame.Label:GetText() else agentLabel = r.frame.Label:GetText() end
			end
		end
		check(youLabel == ns.Color("gold", "You"), "a player's line is labeled You")
		check(agentLabel == ns.Color("agent", "Agent") .. ns.Color("grey", "  writing…"), "a live reply is labeled Agent")
		ns.Store.data.view = savedView
		ns.Transcript:Refresh(true)
	end
	check(f.TopTileStreaks and f.TopTileStreaks._shown == false and f.TitleBg and f.TitleBg._shown == false, "the template's black streaks are hidden")
	check(not f.ModernRim, "the gold top trim is gone")
	local rules = 0
	for _, r in ipairs(f._regions or {}) do
		if rgba(r._color, theme.popupBorder) and (r._w == 1 or r._h == 1) then rules = rules + 1 end
	end
	check(rules >= 4 and rgba(theme.popupBorder, accent), "the window's edge is the accent, as Hyprland's active border")
	check(rgba(hairline, { 0xa9 / 255, 0xb1 / 255, 0xd6 / 255, 0.12 }) and rgba(theme.panel, { hairline[1], hairline[2], hairline[3], 0.04 })
		and theme.controlBorder[4] == 0.4 and theme.hover[4] == 0.08 and theme.selected[4] == 0.18 and theme.pressed[4] == 0.22, "the kit's glass: the foreground at its state alphas")
	-- No text in the modern window keeps a game font: its white would vanish on a light theme.
	local function under(frame, root)
		while frame do
			if frame == root then return true end
			frame = frame._parent
		end
	end
	local gameFonts = {}
	for _, fr in ipairs(Stub.frames) do
		if fr._kind == "FontString" and under(fr, f) and fr._fontObject and not tostring(fr._fontObject):find("^T3Modern") then
			table.insert(gameFonts, tostring(fr._fontObject))
		end
	end
	local kitCount = 0
	for _, fr in ipairs(Stub.frames) do if fr._kind == "FontString" and under(fr, f) and tostring(fr._fontObject):find("^T3Modern") then kitCount = kitCount + 1 end end
	check(kitCount > 50 and #gameFonts == 0, "every text in the modern window uses the kit's fonts: " .. table.concat(gameFonts, ", "))
	check(f.ModernTitle._fontObject == "T3ModernTitle" and _G.T3ModernTitle and _G.T3ModernTitle._font[2] == 14 and rgba(_G.T3ModernTitle._textColor, text), "the title uses the kit's title font, in the foreground")
	check(f.ModernBand._color[1] == ground[1] and f.ModernBand._color[4] == f.ModernBg._color[4], "the title is the same navy")
	local titleAt = f.Subtitle._points and f.Subtitle._points[1]
	local statusAt = f.Status._points and f.Status._points[1]
	check(titleAt and titleAt[1] == "LEFT" and titleAt[2] == f.ModernTitle, "the thread name sits in the title band")
	check(statusAt and statusAt[2] == f.SidebarToggle, "the link status sits beside the list toggle")
	check(f.SidebarToggle.Icon._texture:find("icons\\chevron-left", 1, true) ~= nil, "the list toggle is a line chevron")
	check(f.ModernClose and f.ModernClose.Text:GetText() == "×", "the modern close is a quiet ×")
	check(f.CloseButton == nil or f.CloseButton._shown == false, "the template's close button is hidden in modern")
	check(f.NineSlice and f.NineSlice._shown == false, "the game's ornate border is hidden")
	local function tabBar(tab)
		for _, r in ipairs(tab._regions or {}) do
			if r._w == 2 and rgba(r._color, accent) then return r end
		end
	end
	local function tabsMarked(pageName)
		for _, tab in ipairs(f.Tabs) do
			local on = tab.page == pageName
			local bar = tabBar(tab)
			if not bar or (bar._shown ~= false) ~= on or not rgba(tab.Icon._vertex, on and text or muted) then return false end
		end
		return true
	end
	check(tabsMarked(page), "the open page's side tab carries the accent")
	check(painted(f.Bar.Send, theme.hover) and painted(f.Bar.Send, accent) and rgba(labelOf(f.Bar.Send)._textColor, accent) and labelOf(f.Bar.Send)._fontObject == "T3ModernBodyBold", "Send is the kit's default button: a light wash, an accent border and a bold accent label")
	check(painted(f.Bar.Refresh, theme.panelAlt) and not painted(f.Bar.Refresh, accent), "the other buttons stay on the flat dark fill")
	check(f.Bar.Stop.Icon._texture:find("icons\\x", 1, true) and f.Bar.Stop.Background._color[4] == 0, "toolbar icons are line strokes on the ground")
	check(painted(f.Pages.threads.Right.ComposerInset, panel) and not painted(ns.Transcript.inset, panel), "the message box is a panel and the conversation sits on the window ground")
	check(painted(ns.Family.bar, hairline) and ns.Family.bar.Up.Icon._texture:find("icons\\chevron-left", 1, true), "the family bar closes with a hairline and a line chevron")
	local scroll = ns.ThreadList.scrollBar
	check(scroll._w == 6 and scroll.Line and rgba(scroll.Line._color, theme.track), "the thread list scrollbar is a thin line in the track color")
	local press = f._scripts.OnGamePadButtonDown
	check(ns.Gamepad.capturing and press, "the rebuilt window takes the controller")
	ns.Gamepad:Highlight(ns.Main.composer)
	check(press(f, "PADDDOWN") == false and ns.Gamepad.selected == f.Bar.Send, "Down from the message box still reaches Send")
	check(press(f, "PADRSHOULDER") == false and ns.Main.page ~= page and tabsMarked(ns.Main.page), "a bumper changes page and moves the accent")
	ns.Main:ShowPage(page)
	check(tabsMarked(page), "the accent returns with the page")
	local notice = ns.Toasts.frames[1]
	if not notice then
		ns.Toasts:Show({ id = "toast-modern", title = "Notice", p = ns.Store.data.projects[1].id, last = "done" }, "open")
		notice = ns.Toasts.frames[1]
	end
	check(notice.Bar and notice.Bar._shown ~= false and rgba(notice.Bar._color, accent), "a notice carries the accent bar")
	check(notice.Edge and notice.Edge[1]._shown ~= false and rgba(notice.Edge[1]._color, theme.popupBorder), "a notice has the accent around it")
	check(rgba(notice._backdropColor, theme.windowBg) and theme.windowBg[4] < 1, "a notice uses the window's translucent ground")
	check(rgba(notice.Title._textColor, text) and notice.Title._shadow[1] == 0, "a notice title is the foreground")
	check(notice.Text:GetText():find("Finished", 1, true) and not notice.Text:GetText():find("ff1eff00", 1, true), "a finished notice keeps the status quiet")
	check(ns.Settings.checks[1].Fill ~= nil and ns.Settings.checks[1].Sync ~= nil, "modern settings use a drawn switch")
	local search = ns.ThreadList.search
	check(search and search._insets and search._insets[1] >= 28, "the search text starts clear of the icon")
	local hintX
	for _, pt in ipairs(search.Instructions and search.Instructions._points or {}) do
		if pt[1] == "LEFT" and type(pt[2]) == "number" then hintX = pt[2] end
	end
	check(hintX and hintX >= 28, "the search hint starts clear of the icon")
	check(search.LineIcon and search.LineIcon._texture:find("icons\\search", 1, true) and search.searchIcon._shown == false and search.searchIcon._alpha == 0, "the search box uses the line magnifier")
	local savedTrackerThreads = ns.Store.data.threads
	ns.Store.data.threads = { { id = "fin", title = "Improve the window", s = "open", un = true, u = time(), p = "p" } }
	ns.Tracker:Refresh()
	local tf = ns.Tracker.frame
	check(tf.Modern and tf.Modern.Bg._color[1] == ground[1] and tf.Modern.Band._shown ~= false, "the tracker wears the dusk card")
	check(tf.Header._shown == false, "the objective tracker header steps aside")
	check(tf.Lines[1] and tf.Lines[1].Sub:GetText() == "Finished · now", "a finished thread reads as a quiet status")
	check(tf.Lines[1].Dot._shown == false and tf.Lines[1].Bar._shown == false, "a finished thread has no dot and no gold bar")
	ns.Store.data.threads = { { id = "need", title = "Approve", s = "input", l = "Needs you", p = "p" } }
	ns.Tracker:Refresh()
	check(tf.Lines[1].Bar._shown ~= false and rgba(tf.Lines[1].Bar._color, theme.orange), "a thread that needs you carries the theme's orange bar")
	check(rgba(tf.Lines[1].Title._textColor, theme.orange), "a thread that needs you is titled in orange")
	tf.Lines[1]._scripts.OnEnter(tf.Lines[1])
	check(tf.Lines[1].Hover._shown ~= false and rgba(tf.Lines[1].Hover._color, theme.hover), "a tracker row highlights under the pointer")
	tf.Lines[1]._scripts.OnLeave(tf.Lines[1])
	check(tf.Lines[1].Hover._shown == false, "the highlight leaves with the pointer")
	local bridgeNow = ns.Transport.bridgeNow
	ns.Store.data.threads = {
		{ id = "live", title = "Working now", s = "working", l = "Editing", st = time() - 125, p = "p" },
		{ id = "wait", title = "Watching", s = "waiting", l = "Watching pull request", st = time() - 30, p = "p" },
		{ id = "bad", title = "Broken", s = "failed", un = true, u = time(), p = "p" },
	}
	ns.Transport.bridgeNow = time() - 1000
	ns.Tracker:Refresh()
	check(tf.Lines[1].Sub:GetText():find("Editing · ", 1, true) and rgba(tf.Lines[1].Bar._color, theme.blue) and tf.Lines[1].Dot._shown == false, "a working thread names what it's doing, with a blue bar")
	check(tf.Lines[2].Sub:GetText():find("Watching pull request · ", 1, true) and tf.Lines[2].Bar._shown == false, "a waiting thread has no bar")
	check(tf.Lines[3].Sub:GetText() == "Failed" and rgba(tf.Lines[3].Bar._color, theme.red), "a failed thread carries a red bar")
	check(tf.Lines[4].Title:GetText() == "Connection lost" and tf.Lines[4].Bar._shown ~= false and rgba(tf.Lines[4].Bar._color, theme.orange), "a lost connection is an orange line on the card")
	local collapsed = ns.db.settings.trackerCollapsed
	ns.db.settings.trackerCollapsed = true
	ns.Tracker:Refresh()
	check(tf.Lines[1]._shown == false and tf:GetHeight() == 22 and tf.Modern.Chevron._texture:find("chevron-right", 1, true), "collapsing the card leaves the band and turns the chevron")
	ns.db.settings.trackerCollapsed = collapsed
	ns.Transport.bridgeNow = bridgeNow
	ns.Store.data.threads = {
		{ id = "parent", title = "Lead", s = "waiting", l = "Waiting on 1 subagent", st = time() - 20, p = "p" },
		{ id = "sub-work", title = "Helper", s = "working", l = "Running tests", st = time() - 10, p = "p", sub = true },
		{ id = "sub-wait", title = "Watcher", s = "waiting", l = "Waiting", st = time() - 10, p = "p", sub = true },
		{ id = "sub-need", title = "Approver", s = "input", l = "Needs your approval", p = "p", sub = true },
	}
	ns.Tracker:Refresh()
	local shownIds = {}
	for _, line in ipairs(tf.Lines) do
		if line:IsShown() and line.thread then table.insert(shownIds, line.thread.id) end
	end
	check(table.concat(shownIds, ",") == "parent,sub-need", "the tracker hides working and waiting subagents while keeping ones that need the player: " .. table.concat(shownIds, ","))
	ns.Store.data.threads = { { id = "need", title = "Approve", s = "input", l = "Needs you", p = "p" } }
	ns.Tracker:Refresh()
	local trackerOn = ns.db.settings.tracker
	local sw = ns.Settings.checks[1]
	check(sw:GetChecked() and sw.Fill._points[#sw.Fill._points][1] == "RIGHT" and rgba(sw.Switch.Track._color, theme.selected) and rgba(sw.Fill._color, accent), "a switch that is on is the selected glass, with the accent knob to the right")
	sw:SetChecked(true)
	sw:Click()
	check(ns.db.settings.tracker == false, "clicking a switch stores it")
	check(not sw:GetChecked() and sw.Fill._points[#sw.Fill._points][1] == "LEFT" and rgba(sw.Switch.Track._color, theme.switchOff) and rgba(sw.Fill._color, theme.knob), "a switch that is off is the normal glass, with a dim knob to the left")
	sw:Click()
	check(ns.db.settings.tracker == true, "clicking the switch again turns it back on")
	check(sw.Fill._points[#sw.Fill._points][1] == "RIGHT" and rgba(sw.Fill._color, accent), "the knob returns to the right when the switch is on")
	ns.db.settings.tracker = trackerOn
	check(ns.Settings.nav and #ns.Settings.nav == 7, "modern settings lists its sections")
	local modernTab = false
	for _, b in ipairs(ns.Settings.nav) do if b.id == "modern" and b.Text:GetText() == "Modern" then modernTab = true end end
	check(modernTab, "modern settings has a Modern page")
	check(ns.Settings.heading:GetText() == "Notices", "settings open on Notices")
	for _, b in ipairs(ns.Settings.nav) do if b.id == "voice" then b:Click() end end
	check(ns.Settings.heading:GetText() == "Voice", "a section opens its page")
	local voiceMarked, noticesMarked = false, false
	for _, b in ipairs(ns.Settings.nav) do
		local on = b.Wash._shown ~= false and b.Bar._shown ~= false and rgba(b.Text._textColor, text)
		if b.id == "voice" then voiceMarked = on end
		if b.id == "notices" and (b.Wash._shown ~= false or b.Bar._shown ~= false) then noticesMarked = true end
	end
	check(voiceMarked and not noticesMarked, "the open settings section carries the accent")
	ns.Settings.search:SetText("worktree")
	ns.Settings.search:GetScript("OnTextChanged")(ns.Settings.search)
	local shown = 0
	for _, row in ipairs(ns.Settings.rows) do if row:IsShown() then shown = shown + 1 end end
	check(ns.Settings.heading:GetText() == "Search" and shown == 1, "search shows only the matching setting")
	ns.Settings.search:SetText("")
	ns.Settings.section = "notices"
	ns.Settings:Layout()
	if rowThread then
		local selected
		for _, r in ipairs(ns.ThreadList.scrollBox._rows or {}) do
			if r.ed.thread and r.ed.thread.id == ns.viewId then selected = r.frame end
		end
		check(selected and selected.AccentBar and selected.AccentBar._shown == true
			and selected.AccentBar._color[1] == accent[1], "the selected thread carries the accent bar")
		check(selected.Selected._atlas == nil and selected.Selected._color[1] == ns.Theme.MODERN.selected[1], "selection is a flat wash, not the game's art")
		check(rgba(selected.Title._textColor, accent) and selected.Title._fontObject == "T3ModernBodyBold", "the selected thread's name is bold, in the accent")
	end
	-- Menus, suggestions, the conversation and the list. The tracker is holding a
	-- stand-in thread; these read the real ones, then the stand-in goes back.
	local needThreads = ns.Store.data.threads
	ns.Store.data.threads = savedTrackerThreads
	local env, instanceId = ns.Main:NextProvider()
	local model = f.Pages.threads.Right.Header.Model
	local options = env and ns.Store:ModelOptions(env, nil)
	check(options ~= nil, "the model menu has rows to open")
	local pick
	for _, o in ipairs(options) do if not o.header then pick = o.value break end end
	local savedValue, savedOptions = model.value, model.options
	model:SetOptions(options, pick)
	ns.UI.OpenList(model)
	local menu = ns.UI.ListOpen()
	local headerGrey, checked = false, false
	for _, r in ipairs(menu.Box._rows or {}) do
		if r.ed.header and rgba(r.frame.Text._textColor, muted) then headerGrey = true end
		if not r.ed.header and r.ed.value == pick and r.frame.Check and r.frame.Check._shown ~= false
			and r.frame.Check._texture and r.frame.Check._texture:find("icons\\check", 1, true) then checked = true end
	end
	check(menu and painted(menu, theme.overlay) and painted(menu, theme.popupBorder) and headerGrey and checked, "a menu is the popups surface with an accent edge, a dim group title and a check on the choice")
	menu:Hide()
	if savedOptions then model:SetOptions(savedOptions, savedValue) else model.value = savedValue end
	local savedCommands = ns.Store.commands
	ns.Store.commands = { [env] = { [instanceId] = { { t = "/compact", d = "Summarize" } } } }
	local box = ns.Main.composer
	local eb = box:GetEditBox()
	local draft = box:GetInputText()
	box._text, eb._cursor, box._focus = "/", 1, true
	ns.Suggest:OnTextChanged(true)
	local suggestions = ns.Suggest.frame
	check(suggestions and suggestions:IsShown() and painted(suggestions, theme.overlay), "suggestions sit on the overlay")
	check(suggestions.Rows[1].Selected._shown ~= false and rgba(suggestions.Rows[1].Selected._color, theme.selected), "the highlighted suggestion is a flat wash")
	ns.Suggest:Close()
	box:SetText(draft)
	box._focus = false
	ns.Store.commands = savedCommands
	local savedView = ns.Store.data.view
	ns.Transcript.answers = ns.Transcript.answers or {}
	local savedAnswer = ns.Transcript.answers.qModern
	ns.Transcript.answers.qModern = { q = { a = true } }
	ns.Store.data.view = {
		id = ns.viewId, msgs = { { r = "a", t = "|cffffd100Plan|r and |cffff4040no|r", at = time(), n = 1 } },
		pending = { id = "qModern", kind = "question", questions = {
			{ id = "q", q = "Ship it?", multi = true, opts = { { v = "a", l = "Yes" }, { v = "b", l = "No" } } },
		} },
	}
	ns.Transcript:Refresh(true)
	local yes, no, submit, note, msgRow
	for _, r in ipairs(ns.Transcript.scrollBox._rows or {}) do
		if r.ed.kind == "note" then note = r.frame
		elseif r.ed.kind == "msg" then msgRow = r.frame
		elseif r.ed.label == "Yes" then yes = r.frame
		elseif r.ed.label == "No" then no = r.frame
		elseif r.ed.primary then submit = r.frame end
	end
	check(msgRow and msgRow.Body:GetText() == "|c" .. ns.Theme.ACCENT_HEX .. "Plan|r and |c" .. mk.red .. "no|r", "a message's gold heading is drawn in the accent, and its red in the theme's")
	check(note and note.Icon._texture:find("icons\\arrow-right", 1, true) and rgba(note.Text._textColor, text), "a note uses a line icon and the title color")
	check(yes and rgba(yes.Bullet._color, accent) and yes.Bullet._w == 10, "a chosen answer is a gold square")
	check(no and rgba(no.Bullet._color, theme.controlBorder) and no.Bullet._w == 10 and rgba(labelOf(no)._textColor, muted), "an unchosen answer is a square in the control's border color, in the dim text")
	check(submit and rgba(labelOf(submit)._textColor, text) and labelOf(submit)._fontObject == "T3ModernBodyBold", "a primary answer is bold in the foreground")
	ns.Transcript.answers.qModern = savedAnswer
	ns.Store.data.view = savedView
	ns.Transcript:Refresh(true)
	local savedCollapsed = ns.db.settings.collapsed.settled
	ns.db.settings.collapsed.settled = false
	ns.Store.data.threads = {
		{ id = "live", title = "Working now", s = "working", l = "Editing", st = time() - 10, p = "p" },
		{ id = "old", title = "Done already", s = "settled", u = time() - 3600, p = "p" },
	}
	ns.ThreadList:Refresh(true)
	local group, settledRow
	for _, r in ipairs(ns.ThreadList.scrollBox._rows or {}) do
		if r.ed.header and not group then group = r.frame end
		if r.ed.thread and r.ed.thread.s == "settled" then settledRow = r.frame end
	end
	check(group and group.Icon._texture:find("icons\\", 1, true) and painted(group, hairline), "a group header is a hairline and a line icon")
	local liveRow
	for _, r in ipairs(ns.ThreadList.scrollBox._rows or {}) do
		if r.ed.thread and r.ed.thread.s == "working" then liveRow = r.frame end
	end
	check(liveRow and rgba(liveRow.Title._textColor, text), "a thread's name in the list is the foreground; the accent is for the selected one")
	check(settledRow and rgba(settledRow.Title._textColor, muted), "a settled thread's title is muted")
	ns.db.settings.collapsed.settled = savedCollapsed
	ns.Store.data.threads = needThreads
	local savedUsage = ns.Store.data.usage
	ns.Store.data.usage = { { name = "Codex", plan = "Pro", windows = {
		{ label = "Weekly", used = 18, resets = time() + 86400 },
		{ label = "Daily", used = 95, resets = time() + 3600 },
	} } }
	ns.Main:ShowPage("usage")
	local cool, hot = ns.Usage.pool.row[1], ns.Usage.pool.row[2]
	check(cool and rgba(cool.Bar.Bar._barColor, text), "a usage bar under 70% is the kit's foreground meter")
	check(hot and rgba(hot.Bar.Bar._barColor, theme.red), "a usage bar past 90% turns the theme's red")
	check(painted(ns.Usage.pool.header[1], hairline), "a usage plan is underlined with a hairline")
	ns.Store.data.usage = savedUsage
	ns.Main:ShowPage(page)
	-- Resize: the corner grip saves the size, clamped to the minimum.
	local grip = f.ResizeGrip
	check(grip ~= nil, "the window has a resize grip")
	local gripMark
	for _, r in ipairs(grip._regions or {}) do
		if r._texture and tostring(r._texture):find("icons\\grip", 1, true) then gripMark = r end
	end
	check(gripMark and rgba(gripMark._vertex, muted), "the resize grip is a muted line mark")
	grip._scripts.OnDragStart(grip)
	f:SetSize(600, 400)
	grip._scripts.OnDragStop(grip)
	check(ns.db.settings.windowSize[1] == 760 and ns.db.settings.windowSize[2] == 480, "a resize below the minimum is clamped")
	check(f._w == 760 and f._h == 480, "the window itself is clamped to the minimum")
	grip._scripts.OnDragStart(grip)
	f:SetSize(1100, 700)
	grip._scripts.OnDragStop(grip)
	check(ns.db.settings.windowSize[1] == 1100 and ns.db.settings.windowSize[2] == 700, "a resize is kept for next time")
	ns.Main:ApplyListWidth(40, true)
	check(ns.db.settings.listWidth == 180 and ns.Main.frame.Pages.threads.Left:GetWidth() == 180, "the thread list won't shrink past 180")
	ns.Main:ApplyListWidth(9000, true)
	local listMax = math.max(180, ns.Main.frame:GetWidth() - 420)
	check(ns.db.settings.listWidth == listMax, "the thread list leaves room for the conversation")
	-- A smaller window narrows the list for now, and keeps the width that was chosen.
	ns.Main:ApplyListWidth(500, true)
	local left = ns.Main.frame.Pages.threads.Left
	f:SetSize(760, 480)
	f._scripts.OnSizeChanged(f)
	check(left:GetWidth() == 340 and ns.db.settings.listWidth == 500, "shrinking the window narrows the list without forgetting its width")
	f:SetSize(1100, 700)
	f._scripts.OnSizeChanged(f)
	check(left:GetWidth() == 500, "the list gets its width back when the window grows")
	ns.Main:ApplyListWidth(300, true)
	local settingsScroll = ns.Settings.content and ns.Settings.content:GetParent()
	local settingsBar = settingsScroll and settingsScroll.ScrollBar
	check(settingsBar and settingsBar._shown == false, "the settings list has no black scrollbar")
	settingsBar:Show()
	check(settingsBar._shown == false, "the settings scrollbar stays hidden")
	settingsScroll._vrange = 200
	settingsScroll:GetScript("OnMouseWheel")(settingsScroll, -1)
	check(settingsScroll._vscroll == 48, "the wheel scrolls the settings list")
	settingsScroll:GetScript("OnMouseWheel")(settingsScroll, 1)
	check(settingsScroll._vscroll == 0, "the wheel won't scroll past the top")
	settingsScroll._vscroll = 190
	settingsScroll:GetScript("OnMouseWheel")(settingsScroll, -1)
	check(settingsScroll._vscroll == 200, "the wheel won't scroll past the end")
	ns.Toasts:Preview()
	local openThread = ns.viewId and ns.Store:Thread(ns.viewId)
	local expectLast = (openThread and openThread.last) or "This is how a notice looks."
	local sample
	for _, fr in ipairs(ns.Toasts.frames) do
		if fr.kind == "open" and fr.payload and fr.payload.last == expectLast then sample = fr end
	end
	check(sample and sample:IsShown() and sample.Text:GetText():find(expectLast, 1, true) and not sample.Text:GetText():find("|cff1eff00", 1, true) and rgba(sample.Bar._color, accent), "a test notice shows in the modern colors, on the accent bar")
	ns.Main:ShowPage("settings")
	for _, b in ipairs(ns.Settings.nav) do if b.id == "window" then b:Click() end end
	check(ns.Settings.heading:GetText() == "Window", "settings can open on Window")
	check(not ns.Settings.accent:GetParent():IsShown() and not ns.Settings.opacity:GetParent():IsShown(), "the window page leaves out accent and transparency")
	for _, b in ipairs(ns.Settings.nav) do if b.id == "modern" then b:Click() end end
	check(ns.Settings.heading:GetText() == "Modern" and ns.Settings.accent:GetParent():IsShown() and ns.Settings.opacity:GetParent():IsShown(), "accent and transparency are on the Modern page")
	check(ns.Settings.opacity:GetValue() == 6 and ns.Settings.opacity.Text:GetText() == "6%" and math.abs(ns.Main.frame.ModernBg._color[4] - 0.94) < 0.001, "transparency starts at the dusk ground")
	ns.Settings.opacity:SetValue(40)
	check(ns.db.settings.windowClear == 40 and ns.Settings.opacity.Text:GetText() == "40%" and math.abs(ns.Main.frame.ModernBg._color[4] - 0.6) < 0.001 and math.abs(ns.Main.frame.ModernBand._color[4] - 0.6) < 0.001, "the transparency slider lets the world through the modern window")
	ns.Settings.opacity:SetValue(0)
	check(ns.db.settings.windowClear == 0 and ns.Main.frame.ModernBg._color[4] == 1, "solid puts the window back")
	ns.db.settings.windowClear = 250
	ns.Main:ApplyOpacity()
	check(ns.Main.frame.ModernBg._color[4] == 0, "transparency stops at fully clear")
	ns.db.settings.windowClear = -5
	ns.Main:ApplyOpacity()
	check(ns.Main.frame.ModernBg._color[4] == 1, "transparency stops at solid")
	ns.db.settings.windowClear = nil
	ns.Main:ApplyOpacity()
	check(math.abs(ns.Main.frame.ModernBg._color[4] - 0.94) < 0.001, "a missing transparency uses the dusk ground")
	ns.Settings.opacity:SetValue(100)
	ns.Settings.opacity:GetScript("OnMouseWheel")(ns.Settings.opacity, 1)
	check(ns.Settings.opacity:GetValue() == 100 and ns.db.settings.windowClear == 100, "the wheel won't pass fully clear")
	ns.Settings.opacity:SetValue(0)
	ns.Settings.opacity:GetScript("OnMouseWheel")(ns.Settings.opacity, -1)
	check(ns.Settings.opacity:GetValue() == 0, "the wheel won't pass solid")
	ns.Settings.opacity:SetValue(6)
	check(ns.db.settings.windowClear == 6 and math.abs(ns.Main.frame.ModernBg._color[4] - 0.94) < 0.001, "the slider can return to the dusk ground")
	ns.Settings.search:SetText("transparency")
	ns.Settings.search:GetScript("OnTextChanged")(ns.Settings.search)
	check(ns.Settings.opacity:GetParent():IsShown() and not ns.Settings.design:GetParent():IsShown(), "searching transparency finds it, and not the design")
	ns.Settings.search:SetText("")
	ns.Settings.search:GetScript("OnTextChanged")(ns.Settings.search)
	check(ns.Settings.accent and ns.Settings.accent.value == "class" and ns.Settings.accent.Text:GetText() == "Class color", "settings lists the accent, starting on class color")
	check(#ns.Settings.accent.options == 2 and ns.Settings.accent.options[2].value == "theme", "the accent is the class color or the theme's")
	check(ns.Settings.palette and ns.Settings.palette.value == "tokyo-night" and ns.Settings.palette.Text:GetText() == "Tokyo Night", "settings lists the theme, starting on Tokyo Night")
	check(#ns.Settings.palette.options == #ns.PALETTES and ns.PALETTES[1].id == "tokyo-night" and #ns.PALETTES >= 20, "every Omarchy theme is offered, Tokyo Night first")
	-- A long list opens with its search, scrolls, and fits fourteen rows.
	ns.UI.OpenList(ns.Settings.palette)
	local plist = ns.UI.ListOpen()
	check(plist and plist.Search._shown ~= false and plist.Bar._shown ~= false and #plist.filtered == #ns.PALETTES and plist._h <= 14 * 22 + 44, "the theme list scrolls instead of running off the screen")
	plist:Hide()
	-- The class color, unless it reads too faintly on the theme.
	local beforeAccent = ns.Main.frame
	UnitClass = function() return "Mage", "MAGE" end
	ns.Main:ApplyTheme()
	check(ns.Main.frame ~= beforeAccent and ns.Theme.ACCENT_HEX == "ff40c7eb" and ns.Theme.accentWhy == "class" and ns.Settings.accent.Text:GetText() == "Class color (Mage)", "class color uses the player's class")
	RAID_CLASS_COLORS = { MAGE = { r = 0.4, g = 0.8, b = 0.6 } }
	check(ns.Theme.Get() and ns.Theme.ACCENT_HEX == "ff40c7eb", "the accent is worked out once, not on every use")
	ns.Theme.Invalidate()
	check(ns.Theme.Get() and ns.Theme.ACCENT_HEX == "ff66cc99", "a changed class color wins over the built-in one")
	RAID_CLASS_COLORS = nil
	ns.Theme.Invalidate()
	local beforeTheme = ns.Main.frame
	ns.Settings.accent:Step(1)
	check(ns.Main.frame ~= beforeTheme and ns.db.settings.accent == "theme" and ns.Theme.ACCENT_HEX == "ff7aa2f7" and painted(ns.Main.frame.Bar.Send, ns.Theme.MODERN.accent), "the theme's accent rebuilds the window in it")
	check(ns.Settings.section == "modern" and ns.Settings.heading:GetText() == "Modern", "picking an accent stays on the Modern page")
	check(sample.payload and rgba(sample.Bar._color, ns.Theme.MODERN.accent) and rgba(sample.Edge[1]._color, ns.Theme.MODERN.accent), "the open notice takes the new accent")
	ns.Settings.accent:Step(-1)
	local beforePalette = ns.Main.frame
	ns.Settings.palette:Step(1)
	local second = ns.PALETTES[2]
	check(ns.Main.frame ~= beforePalette and ns.db.settings.palette == second.id and ns.Theme.MARKUP.white == "ff" .. second.foreground:sub(2)
		and rgba(ns.Theme.MODERN.windowBg, { tonumber(second.background:sub(2, 3), 16) / 255, tonumber(second.background:sub(4, 5), 16) / 255, tonumber(second.background:sub(6, 7), 16) / 255, 0.94 }), "picking another theme repaints the window in it")
	check(ns.Settings.palette.Text:GetText() == second.label, "the theme dropdown names the new theme")
	local liveTitle = _G.T3ModernBody._textColor
	check(rgba(liveTitle, ns.Theme.MODERN.text), "the kit's fonts take the new theme's foreground")
	-- Priest white on the White theme is too faint: the theme's accent stands in, and says so.
	UnitClass = function() return "Priest", "PRIEST" end
	ns.db.settings.palette = "white"
	ns.Main:ApplyTheme()
	check(ns.Theme.accentWhy == "faint" and ns.Theme.ACCENT_HEX == "ff6e6e6e" and ns.Settings.accent.Text:GetText():find("too faint", 1, true)
		and ns.Theme.MODERN.mode == "light", "a class color too faint on the theme gives way to the theme's accent, and says so")
	check(ns.Theme.Contrast({ 1, 1, 1 }, { 0, 0, 0 }) > 20.9 and ns.Theme.Contrast({ 1, 1, 1 }, { 1, 1, 1 }) == 1, "contrast is WCAG's ratio")
	UnitClass = function() return "Shaman", "SHAMAN" end
	ns.Theme.Invalidate()
	ns.Theme.Get()
	check(ns.Theme.accentWhy == "class" and ns.Theme.ACCENT_HEX == "ff0070de", "a class color that reads on the light theme is kept")
	UnitClass = nil
	ns.db.settings.palette = "tokyo-night"
	ns.Main:ApplyTheme()
	check(_G.T3ModernBody._font[1]:find("JetBrainsMono-Regular.ttf", 1, true) and _G.T3ModernTitle._font[1]:find("JetBrainsMono-Bold.ttf", 1, true) and ns.Theme.fontOk, "the kit's fonts are JetBrains Mono, bold for titles")
	-- A missing font file leaves the game's font, never no text.
	local savedRegular, savedBold = ns.Theme.FONT_REGULAR, ns.Theme.FONT_BOLD
	ns.Theme.FONT_REGULAR, ns.Theme.FONT_BOLD = "Interface\\AddOns\\T3Code\\Media\\fonts\\Gone.ttf", "Interface\\AddOns\\T3Code\\Media\\fonts\\Gone.ttf"
	Stub.missingFonts = { [ns.Theme.FONT_REGULAR] = true }
	local savedFile = _G.T3ModernBody._font[1]
	ns.Theme.UpdateFonts()
	check(not ns.Theme.fontOk and _G.T3ModernBody._font[1] ~= ns.Theme.FONT_REGULAR and _G.T3ModernBody._font[1] ~= nil and _G.T3ModernBody._font[2] == 12, "a font file that won't load falls back to the game's font")
	Stub.missingFonts = nil
	ns.Theme.FONT_REGULAR, ns.Theme.FONT_BOLD = savedRegular, savedBold
	ns.Theme.UpdateFonts()
	check(_G.T3ModernBody._font[1] == savedFile, "the fonts are put back")
	ns.Main:ShowPage(page)
	ns.Settings.design:Step(-1)
	local f3 = ns.Main.frame
	check(f3 ~= f and not f3.ModernBg and ns.db.settings.theme == "classic", "choosing classic in the design dropdown rebuilds the game's window")
	check(ns.Settings.design and ns.Settings.size and not ns.Settings.accent and not ns.Settings.opacity, "classic settings keep design and size, and leave out accent and transparency")
	check(ns.Color("gold", "Start") == "|cffffd100Start|r" and ns.Theme.Markup("|cffffd100Plan|r") == "|cffffd100Plan|r", "classic headings stay the game's gold")
	check(f3._w == 1100 and f3._h == 700, "the resized size carries across the design switch")
	check(f3.ResizeGrip ~= nil, "the classic window resizes too")
	-- Nothing of the modern look is left on the game's window: no kit font, no text
	-- color of a theme, and chat and markup on the game's own colors.
	local function under(frame, root)
		while frame do
			if frame == root then return true end
			frame = frame._parent
		end
	end
	local kitFonts = 0
	for _, fr in ipairs(Stub.frames) do
		if fr._kind == "FontString" and under(fr, f3) and tostring(fr._fontObject):find("^T3Modern") then kitFonts = kitFonts + 1 end
	end
	check(kitFonts == 0, "the classic window uses only the game's fonts")
	check(ns.Color("white", "a") == "|cffffffffa|r" and ns.Color("grey", "a") == "|cff9d9d9da|r" and ns.Theme.Markup("|cffff4040no|r") == "|cffff4040no|r", "classic text keeps the game's colors")
	check(not ns.Settings.checks[1].Fill, "classic checkboxes keep the game's own look")
	check(tf.Header._shown ~= false and tf.Modern.Band._shown == false, "the classic tracker header returns")
	check(tf.Lines[1].Sub:GetText():find("^- ", 1) ~= nil, "classic status keeps the tracker dash")
	check(tf.Lines[1].Dot._shown ~= false, "the classic tracker dot is back")
	local tl = tf.Lines[1]
	check(tl.Title._font == nil and tl.Sub._font == nil and tl.Title._fontObject ~= nil and tl.Sub._fontObject ~= nil
		and not tostring(tl.Title._fontObject):find("^T3Modern") and not tostring(tl.Sub._fontObject):find("^T3Modern")
		and tl.Title._shadow and tl.Title._shadow[1] == 1 and tl.Sub._shadow and tl.Sub._shadow[1] == 1, "the classic tracker lines get their fonts and shadows back")
	check(notice.Bar._shown == false and notice._backdrop and notice._backdrop.edgeFile ~= nil, "a notice goes back to the gold border")
	check(rgba(notice.Title._textColor, { 1, 0.82, 0, 1 }), "a notice title goes back to the game's gold")
	local classicName
	for _, r in ipairs(ns.ThreadList.scrollBox._rows or {}) do
		if r.ed.thread and r.ed.thread.s ~= "settled" and r.ed.thread.s ~= "snoozed" then classicName = r.frame break end
	end
	check(classicName and rgba(classicName.Title._textColor, { 1, 0.82, 0, 1 }), "a thread name in the list goes back to the game's gold")
	ns.Store.data.threads = savedTrackerThreads
	ns.Tracker:Refresh()
	check(f3.NineSlice and f3.NineSlice._shown ~= false, "the game's ornate border is back")
	check(f3.TopTileStreaks and f3.TopTileStreaks._shown ~= false and f3.TitleBg._shown ~= false, "the classic frame keeps its title streaks")
	check(f3:IsShown() and ns.Main.page == page, "still open on the same page after switching back")
	ns.Main:ShowPage("settings")
	check(ns.Settings.design.value == "classic", "the design dropdown follows the setting")
	ns.Main:ShowPage("threads")
	ns.Main:Refresh()
	check(true, "the rebuilt window still refreshes")
end

-- Omarchy's palettes: what a theme leaves out is filled in as omarchy-ui does it, and
-- settings from before the themes move onto them.
do
	local Theme = ns.Theme
	local function same(c, r, g, b) return c and math.abs(c[1] - r / 255) < 1e-6 and math.abs(c[2] - g / 255) < 1e-6 and math.abs(c[3] - b / 255) < 1e-6 end
	local full = Theme.Resolve(ns.PALETTES[1])
	check(same(full.background, 0x1a, 0x1b, 0x26) and same(full.foreground, 0xa9, 0xb1, 0xd6) and same(full.textDim, 0x56, 0x5f, 0x89)
		and same(full.textFaint, 0x41, 0x48, 0x68) and same(full.accent, 0x7a, 0xa2, 0xf7) and full.mode == "dark", "Tokyo Night resolves to its own colors")
	local dark = Theme.Resolve({ color0 = "#000000", color7 = "#FFFFFF", color4 = "#0000ff", color1 = "#ff0000", color8 = "#333333" })
	check(same(dark.background, 0, 0, 0) and same(dark.foreground, 255, 255, 255) and same(dark.accent, 0, 0, 255) and same(dark.red, 255, 0, 0)
		and same(dark.textFaint, 0x33, 0x33, 0x33) and same(dark.blue, 0, 0, 255) and dark.mode == "dark", "missing keys fall back to color0..color8")
	check(same(dark.textDim, 170, 170, 170), "a dark theme without dark_foreground dims the foreground by 1.5")
	local bare = Theme.Resolve({ foreground = "#ffffff", background = "#000000" })
	check(same(bare.textFaint, 128, 128, 128) and same(bare.green, 0x7f, 0x9f, 0x6f) and same(bare.orange, 0xc0, 0xa0, 0x60), "without muted or color8 the faint text is darker 2; a missing color is the kit's default, and orange falls back to yellow")
	local light = Theme.Resolve({ mode = "light", foreground = "#000000", background = "#ffffff", dark_fg = "#123456" })
	check(same(light.textDim, 0x12, 0x34, 0x56) and same(light.textFaint, 128, 128, 128) and light.mode == "light", "a light theme mixes toward the background, and reads the legacy dark_fg")
	local lightBare = Theme.Resolve({ mode = "light", foreground = "#000000", background = "#ffffff" })
	check(same(lightBare.textDim, 85, 85, 85), "a light theme's dim text is a third of the way to the background")
	local empty = Theme.Resolve({})
	check(same(empty.background, 0x10, 0x13, 0x15) and same(empty.foreground, 0xca, 0xcc, 0xcc) and same(empty.accent, 0xca, 0xcc, 0xcc), "a theme with nothing uses the kit's defaults")
	local old = { accent = "verdigris" }
	ns.MigrateSettings(old)
	check(old.accent == "theme" and old.palette == "tokyo-night", "an old fixed accent becomes the theme's, and a missing theme Tokyo Night")
	local kept = { accent = "class", palette = "nord" }
	ns.MigrateSettings(kept)
	check(kept.accent == "class" and kept.palette == "nord", "current settings are kept")
	local gone = { accent = "theme", palette = "osaka-jade" }
	ns.MigrateSettings(gone)
	check(gone.palette == "tokyo-night", "a theme Omarchy no longer ships becomes Tokyo Night")
end

-- Thread titles are cut on whole characters, measured a few times, not once a byte.
do
	local function chars(str) local n = 0 for _ in str:gmatch("[^\128-\191][\128-\191]*") do n = n + 1 end return n end
	local calls = 0
	local fs = { SetText = function(self, t) self.t = t end, GetStringWidth = function(self) calls = calls + 1 return chars(self.t) * 10 end }
	local title = "Fix — the “bridge” crash 🙂 on Wine, then the ünit tests"
	local okAll, maxCalls = true, 0
	for w = 20, chars(title) * 10 - 10, 7 do
		calls = 0
		local out = ns.ThreadList.TrimTo(fs, title, w)
		maxCalls = math.max(maxCalls, calls)
		local body = out:sub(1, -4) -- without the ellipsis
		local whole = title:sub(1, #body) == body and (#body == #title or not title:byte(#body + 1) or title:byte(#body + 1) < 0x80 or title:byte(#body + 1) >= 0xC0)
		local longest = chars(out) * 10 <= w and chars(body) + 2 > w / 10
		if not (whole and longest and fs.t == out) then okAll = false print("  trim at " .. w .. ": " .. out) end
	end
	check(okAll, "a cut title keeps whole characters and as much as fits")
	check(maxCalls <= 8, "trimming a title measures it a handful of times: " .. maxCalls)
end

-- Exhaustion
Stub.now = Stub.now + 2
ns.Transport.slotCursor = ns.Transport.slotCount + 1
ns.Transport:LoadNextSlot("signal")
check(ns.Transport:BridgeState() == "exhausted", "slot exhaustion detected")
ns.Tracker:Refresh()

print("\nall smoke checks passed; slots loaded: " .. tostring(Stub.loadCount))
