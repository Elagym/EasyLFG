-- EasyLFG Inviter: invites one player at a time. Each invite gets an optional whisper first, then
-- waits for an answer (joined, declined, already grouped, not found) or the time limit, and only
-- then goes on to the next player. In auto mode the next invite follows by itself after a pause;
-- otherwise every invite is one click on "Invite next" (or its key binding).

local _, ns = ...

local Inviter = {}
ns.Inviter = Inviter

Inviter.pending = nil -- { name, key, role, class, level, sentAt, token, confirmed, whispered }
Inviter.auto = false
Inviter.nextAt = nil -- when auto mode sends the next invite
Inviter.inviteAfterSearch = false
Inviter.log = {}
Inviter.invitesSent = 0
Inviter.lastSystem = nil
Inviter.lastInviteError = nil
Inviter.lastWhisperError = nil
Inviter.announcedComplete = false

local inviteToken = 0
local nextToken = 0

local OUTCOME_PRINT = {
	joined = "|cff60ff60joined|r",
	declined = "|cffff6060declined|r",
	busy = "is already in a group",
	noanswer = "did not answer in time",
	notfound = "could not be found",
	ignored = "is ignoring you",
	failed = "could not be invited",
}

local function addLog(text)
	table.insert(Inviter.log, 1, { at = date("%H:%M:%S"), text = text })
	while #Inviter.log > 30 do
		table.remove(Inviter.log)
	end
end

local function describe(c)
	local parts = {}
	if c.class then
		parts[#parts + 1] = ns.ClassName(c.class)
	end
	if c.level then
		parts[#parts + 1] = tostring(c.level)
	end
	local name = c.class and ns.Colored(c.name, c.class) or c.name
	return #parts > 0 and ("%s (%s)"):format(name, table.concat(parts, " ")) or name
end

-- Permission ---------------------------------------------------------------------------------

function Inviter.CanInvite()
	if not ns.Readable(IsInGroup()) then
		return true
	end
	if ns.Readable(UnitIsGroupLeader("player")) then
		return true
	end
	return ns.Readable(IsInRaid()) and ns.Readable(UnitIsGroupAssistant("player")) or false
end

-- Sending ------------------------------------------------------------------------------------

local function escapeReplacement(text)
	return (tostring(text):gsub("%%", "%%%%"))
end

function Inviter.FormatMessage(c)
	local text = ns.settings.message
	if type(text) ~= "string" or ns.Trim(text) == "" then
		text = ns.DEFAULT_MESSAGE
	end
	local first = type(c.name) == "string" and (c.name:match("^[^%s%-]+") or c.name) or ""
	text = text:gsub("<[Dd]ungeon>", escapeReplacement(ns.settings.activityName or "a dungeon"))
	text = text:gsub("<[Rr]ole>", escapeReplacement(ns.ROLE_LABEL[c.role] or "DPS"))
	text = text:gsub("<[Nn]ame>", escapeReplacement(first))
	return ns.Trim(text)
end

local function sendWhisper(name, text)
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if not send then
		return false, "no chat function"
	end
	if text == "" then
		return false, "empty message"
	end
	local ok, err = pcall(send, text, "WHISPER", nil, name)
	if not ok then
		return false, tostring(err)
	end
	return true
end

local function sendInvite(name)
	local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit or InviteToGroup
	if not invite then
		return false, "no invite function"
	end
	local ok, err = pcall(invite, name)
	if not ok then
		return false, tostring(err)
	end
	return true
end

-- The role to use when you invite someone by hand who does not fit the rules: the first role they
-- listed that is still open, else the first role they listed, else DPS.
local function fallbackRole(c, state)
	for _, role in ipairs(ns.ROLES) do
		if c.roles and c.roles[role] and state.remaining[role] > 0 then
			return role
		end
	end
	for _, role in ipairs(ns.ROLES) do
		if c.roles and c.roles[role] then
			return role
		end
	end
	return "DAMAGER"
end

-- Invites this candidate now. Returns ok, message.
function Inviter.InviteCandidate(c)
	if Inviter.pending then
		return false, ("Still waiting for %s to answer."):format(Inviter.pending.name)
	end
	if not Inviter.CanInvite() then
		return false, "Only the group leader can invite."
	end
	if not c or not c.name then
		return false, "That player's name cannot be read."
	end
	local state = ns.Finder.GroupState()
	if state.full then
		return false, "Your group is full."
	end
	local role = c.role or fallbackRole(c, state)
	c.role = role

	local whispered = false
	if ns.settings.whisper then
		local ok, err = sendWhisper(c.name, Inviter.FormatMessage(c))
		whispered = ok
		if not ok then
			Inviter.lastWhisperError = err
		end
	end

	local ok, err = sendInvite(c.name)
	if not ok then
		Inviter.lastInviteError = err
		ns.db.asked[c.key] = { name = c.name, outcome = "failed", time = time(), role = role }
		addLog(c.name .. ": invite failed (" .. err .. ")")
		ns.Finder.Evaluate()
		return false, "The invite failed: " .. err
	end

	inviteToken = inviteToken + 1
	local token = inviteToken
	Inviter.pending = {
		name = c.name,
		key = c.key,
		role = role,
		class = c.class,
		level = c.level,
		sentAt = GetTime(),
		token = token,
		confirmed = false,
		whispered = whispered,
	}
	ns.db.asked[c.key] = { name = c.name, outcome = "invited", time = time(), role = role }
	Inviter.invitesSent = Inviter.invitesSent + 1
	addLog(("%s: invited as %s"):format(c.name, ns.ROLE_LABEL[role]))
	ns.Print(("Invited %s as %s."):format(describe(c), ns.ROLE_LABEL[role]))

	local timeout = ns.Clamp(ns.settings.timeout, 10, 120)
	C_Timer.After(timeout, ns.Guard("invite timeout", function()
		if Inviter.pending and Inviter.pending.token == token then
			Inviter.Resolve("noanswer")
		end
	end))

	ns.Finder.Evaluate()
	return true, ("Invited %s. Waiting for an answer..."):format(c.name)
end

-- The group is complete: say so once and stop auto mode.
function Inviter.Finish(state)
	Inviter.auto = false
	Inviter.nextAt = nil
	nextToken = nextToken + 1
	if state.complete and not Inviter.announcedComplete then
		Inviter.announcedComplete = true
		ns.Print("|cff60ff60Your group is complete!|r")
		if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
			pcall(PlaySound, SOUNDKIT.READY_CHECK)
		end
	end
end

-- Invites the best match. `fromClick` is true for a click or key press: then an empty list may
-- start a fresh search, which the game only allows from such an action.
function Inviter.InviteNext(fromClick)
	if Inviter.pending then
		return false, ("Still waiting for %s to answer."):format(Inviter.pending.name)
	end
	if not ns.settings.activityID then
		return false, "Pick a dungeon first."
	end
	if not Inviter.CanInvite() then
		return false, "Only the group leader can invite."
	end
	local state = ns.Finder.Evaluate()
	if state.done then
		Inviter.Finish(state)
		return false, state.complete and "Your group is complete." or "Your group is full."
	end
	local c = ns.Finder.Next()
	if not c then
		local stale = not ns.Finder.lastResultsAt or GetTime() - ns.Finder.lastResultsAt > 15
		if fromClick and stale and not ns.Finder.searching then
			local ok, message = ns.Finder.Search()
			if ok then
				Inviter.inviteAfterSearch = true
			end
			return ok, message
		end
		return false, "Nobody else matches right now. Search again in a moment."
	end
	return Inviter.InviteCandidate(c)
end

-- Auto mode -----------------------------------------------------------------------------------

function Inviter.ScheduleNext()
	if not Inviter.auto or Inviter.pending then
		return
	end
	nextToken = nextToken + 1
	local token = nextToken
	local delay = ns.Clamp(ns.settings.delay, 1, 60)
	Inviter.nextAt = GetTime() + delay
	C_Timer.After(delay, ns.Guard("auto invite", function()
		if token ~= nextToken or not Inviter.auto then
			return
		end
		Inviter.nextAt = nil
		local _, message = Inviter.InviteNext(false)
		ns.SetStatus(message)
	end))
end

-- Turns auto mode on. Called from a click, so it may search first.
function Inviter.Start()
	if not ns.settings.activityID then
		return false, "Pick a dungeon first."
	end
	if not Inviter.CanInvite() then
		return false, "Only the group leader can invite."
	end
	local state = ns.Finder.Evaluate()
	if state.done then
		return false, state.complete and "Your group is already complete." or "Your group is full."
	end
	Inviter.auto = true
	Inviter.announcedComplete = false
	if Inviter.pending then
		return true, ("Auto invite on. Waiting for %s first."):format(Inviter.pending.name)
	end
	if not ns.Finder.lastResultsAt or GetTime() - ns.Finder.lastResultsAt > 30 then
		local ok, message = ns.Finder.Search()
		if ok then
			Inviter.inviteAfterSearch = true
			return true, message
		end
		Inviter.auto = false
		return false, message
	end
	local ok, message = Inviter.InviteNext(true)
	if not ok and not Inviter.pending and not ns.Finder.searching then
		-- Nothing to invite: stay on, the next search result will be used.
		message = message .. " Auto invite stays on for the next search."
	end
	return Inviter.auto, message
end

function Inviter.Stop()
	Inviter.auto = false
	Inviter.nextAt = nil
	Inviter.inviteAfterSearch = false
	nextToken = nextToken + 1
	if Inviter.pending then
		return true, ("Auto invite off. Still waiting for %s's answer."):format(Inviter.pending.name)
	end
	return true, "Auto invite off."
end

-- New search results: an invite that waited for them goes out now.
function Inviter.OnResults()
	if Inviter.pending or Inviter.nextAt then
		return
	end
	if Inviter.inviteAfterSearch or Inviter.auto then
		Inviter.inviteAfterSearch = false
		local ok, message = Inviter.InviteNext(false)
		if not ok and Inviter.auto then
			message = message .. " Auto invite stays on."
		end
		ns.SetStatus(message)
	end
end

-- Answers ---------------------------------------------------------------------------------------

-- Ends the invite in flight with an outcome and goes on.
function Inviter.Resolve(outcome)
	local p = Inviter.pending
	if not p then
		return
	end
	Inviter.pending = nil
	ns.db.asked[p.key] = { name = p.name, outcome = outcome, time = time(), role = p.role }
	if outcome == "joined" then
		ns.db.memberRoles[p.key] = { name = p.name, role = p.role, time = time() }
	end
	addLog(("%s: %s"):format(p.name, Inviter.OUTCOME_LOG[outcome] or outcome))
	ns.Print(("%s %s."):format(describe(p), OUTCOME_PRINT[outcome] or outcome))

	local state = ns.Finder.Evaluate()
	if state.done then
		Inviter.Finish(state)
		ns.SetStatus(state.complete and "Your group is complete!" or "Your group is full.")
	elseif Inviter.auto then
		Inviter.ScheduleNext()
		ns.SetStatus(("Next invite in %d s."):format(ns.Clamp(ns.settings.delay, 1, 60)))
	else
		ns.SetStatus("Ready: click Invite next.")
	end
end

Inviter.OUTCOME_LOG = {
	joined = "joined",
	declined = "declined",
	busy = "already in a group",
	noanswer = "no answer",
	notfound = "not found",
	ignored = "ignores you",
	failed = "failed",
}

-- Someone joined: the invite in flight, or one who timed out and accepted late.
function Inviter.OnJoined(name)
	local p = Inviter.pending
	if p and ns.SameName(name, p.name) then
		Inviter.Resolve("joined")
		return
	end
	local key = ns.MakeKey(name)
	local record = key and ns.db.asked[key]
	if record and record.role and record.outcome ~= "joined" then
		record.outcome = "joined"
		ns.db.memberRoles[key] = { name = name, role = record.role, time = time() }
		addLog(("%s: joined late"):format(name))
	end
end

-- System messages -------------------------------------------------------------------------------

-- "%s declines your group invitation." -> "^(.+) declines your group invitation%.$"
function Inviter.ToPattern(format)
	if type(format) ~= "string" or format == "" then
		return nil
	end
	format = format:gsub("%%%d%$s", "%%s")
	local pattern = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
	pattern = pattern:gsub("%%%%s", "(.+)")
	return "^" .. pattern .. "$"
end

local NAMED_MESSAGES = {
	{ "ERR_JOINED_GROUP_S", "joined" },
	{ "ERR_RAID_MEMBER_ADDED_S", "joined" },
	{ "ERR_DECLINE_GROUP_S", "declined" },
	{ "ERR_ALREADY_IN_GROUP_S", "busy" },
	{ "ERR_BAD_PLAYER_NAME_S", "notfound" },
	{ "ERR_IGNORING_YOU_S", "ignored" },
	{ "ERR_INVITE_PLAYER_S", "sent" },
}
-- Messages without a name that answer the invite in flight.
local PLAIN_MESSAGES = {
	{ "ERR_GROUP_FULL", "failed" },
	{ "ERR_PLAYER_WRONG_FACTION", "failed" },
	{ "ERR_INVITE_RESTRICTED", "failed" },
	{ "ERR_NOT_LEADER", "failed" },
}

local patterns
local function namedPatterns()
	if not patterns then
		patterns = {}
		for _, entry in ipairs(NAMED_MESSAGES) do
			local pattern = Inviter.ToPattern(_G[entry[1]])
			if pattern then
				patterns[#patterns + 1] = { pattern = pattern, outcome = entry[2], source = entry[1] }
			end
		end
	end
	return patterns
end

function Inviter.OnSystemMessage(_, message)
	message = ns.Readable(message)
	if type(message) ~= "string" then
		return
	end
	local text = ns.StripCodes(message)
	local p = Inviter.pending
	for _, entry in ipairs(namedPatterns()) do
		local who = text:match(entry.pattern)
		if who then
			Inviter.lastSystem = entry.source .. ": " .. who
			if entry.outcome == "joined" then
				Inviter.OnJoined(who)
			elseif p and ns.SameName(who, p.name) then
				if entry.outcome == "sent" then
					p.confirmed = true
				else
					Inviter.Resolve(entry.outcome)
				end
			end
			ns.Refresh()
			return
		end
	end
	if p then
		for _, entry in ipairs(PLAIN_MESSAGES) do
			if _G[entry[1]] and text == _G[entry[1]] then
				Inviter.lastSystem = entry[1]
				Inviter.Resolve(entry[2])
				ns.Refresh()
				return
			end
		end
	end
end

-- The roster changed: someone joined or left, or you lost the lead.
function Inviter.OnRoster()
	for _, unit in ipairs(ns.Finder.GroupUnits()) do
		local name = ns.ReadUnitName(unit)
		if name then
			Inviter.OnJoined(name)
		end
	end
	if (Inviter.auto or Inviter.pending) and not Inviter.CanInvite() then
		Inviter.Stop()
		ns.SetStatus("You are no longer the group leader; auto invite is off.")
	end
	local state = ns.Finder.Evaluate()
	if state.done then
		if Inviter.auto then
			Inviter.Finish(state)
		elseif state.complete and not Inviter.announcedComplete and ns.settings.activityID and Inviter.invitesSent > 0 then
			Inviter.Finish(state)
		end
	else
		Inviter.announcedComplete = false
		-- Someone left while auto mode runs: keep filling the seat.
		if Inviter.auto and not Inviter.pending and not Inviter.nextAt then
			Inviter.ScheduleNext()
		end
	end
	ns.Refresh()
end

-- The game blocked one of our calls: auto mode cannot work here, so it stops and says why.
function Inviter.OnBlocked(functionName)
	local fn = tostring(functionName)
	if fn:find("Invite") or fn:find("ChatMessage") then
		if Inviter.auto then
			Inviter.Stop()
		end
		if fn:find("Invite") then
			ns.SetStatus("The game wants a click for each invite: use Invite next or its key binding.")
		else
			ns.SetStatus("The game blocked the whisper. Untick 'Whisper first' or invite with a click.")
		end
	end
end

ns.On("CHAT_MSG_SYSTEM", "system message", Inviter.OnSystemMessage)
ns.On("GROUP_ROSTER_UPDATE", "roster", Inviter.OnRoster)
