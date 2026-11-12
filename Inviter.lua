-- EasyLFG Inviter: at most one invite in flight per role. A round invites, at the same time, one
-- player for each role that is still open and has no invite waiting: a tank, a healer and a DPS
-- at most. Each invite goes out together with its whisper ("... as tank ?"). A role gets its next
-- invite only once its player answered: joined, declined, already in a group, not found, or no
-- answer at all within the time limit.
--
-- In auto mode an answer is followed straight away by the next invite for the freed role;
-- otherwise each round is one click on "Invite" (or its key binding).
--
-- Someone who joined keeps their seat in `joining` until the roster shows them: the "joins the
-- party" message can come before the roster update, and in between the seat would look empty.

local _, ns = ...

local Inviter = {}
ns.Inviter = Inviter

Inviter.pending = {} -- role -> { name, key, role, class, level, sentAt, token, confirmed, whispered }
Inviter.joining = {} -- key -> { name, role, class, at }: joined, not in the roster yet
Inviter.auto = false
Inviter.inviteAfterSearch = false

local JOINING_HOLD = 10 -- seconds a joiner's seat is held without the roster showing them
Inviter.invitesSent = 0
Inviter.lastSystem = nil
Inviter.lastInviteError = nil
Inviter.lastWhisperError = nil
Inviter.announcedComplete = false

local inviteToken = 0

local OUTCOME_PRINT = {
	joined = "|cff60ff60joined|r",
	declined = "|cffff6060declined|r",
	busy = "is already in a group",
	noanswer = "did not answer in time",
	notfound = "could not be found",
	ignored = "is ignoring you",
	failed = "could not be invited",
}

Inviter.OUTCOME_LOG = {
	joined = "joined",
	declined = "declined",
	busy = "already in a group",
	noanswer = "no answer",
	notfound = "not found",
	ignored = "ignores you",
	failed = "failed",
}

local function addLog(text)
	ns.Log(text)
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

-- Invites in flight ----------------------------------------------------------------------------

function Inviter.PendingCount()
	local count = 0
	for _ in pairs(Inviter.pending) do
		count = count + 1
	end
	return count
end

-- The invite in flight for this name, if any.
function Inviter.FindPending(name)
	for _, invite in pairs(Inviter.pending) do
		if ns.SameName(invite.name, name) then
			return invite
		end
	end
	return nil
end

-- "Tank Fetto Vandike, Healer Garlick Naan"
function Inviter.PendingText()
	local parts = {}
	for _, role in ipairs(ns.ROLES) do
		local invite = Inviter.pending[role]
		if invite then
			parts[#parts + 1] = ns.ROLE_LABEL[role] .. " " .. invite.name
		end
	end
	return table.concat(parts, ", ")
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

function Inviter.FormatMessage(c, role)
	local text = ns.settings.message
	if type(text) ~= "string" or ns.Trim(text) == "" then
		text = ns.DEFAULT_MESSAGE
	end
	role = role or c.role
	local first = type(c.name) == "string" and (c.name:match("^[^%s%-]+") or c.name) or ""
	text = text:gsub("<[Dd]ungeon>", escapeReplacement(ns.settings.activityName or "a dungeon"))
	text = text:gsub("<[Rr]ole>", escapeReplacement(ns.ROLE_WORD[role] or "dps"))
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

-- The role for an invite by hand: the first role they fit, else the first role they listed that
-- is still open, else the first role they listed, else DPS.
function Inviter.RoleFor(c, state)
	-- A role they fit that has no invite waiting comes first.
	for _, role in ipairs(ns.ROLES) do
		if c.fits and c.fits[role] and not Inviter.pending[role] then
			return role
		end
	end
	if c.role then
		return c.role
	end
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

-- The + button on a player's row: can it invite them now, and for which role? Returns
-- ok, role, why-not. Only players who fit your rules get an active button; a role with an invite
-- waiting keeps the button off until that answer comes back.
function Inviter.RowInvite(c)
	if not c or not c.name or c.status == "hidden" then
		return false, nil, "Their details are hidden by the game."
	end
	if c.status == "invited" then
		return false, c.role, "Invited, waiting for their answer."
	end
	if c.status == "ingroup" then
		return false, nil, "Already in your group."
	end
	if not ns.settings.activityID then
		return false, nil, "Pick a dungeon first."
	end
	if not Inviter.CanInvite() then
		return false, nil, "Only the group leader can invite."
	end
	if c.status ~= "match" then
		return false, nil, (c.reason or "Does not fit your rules") .. ". Click the row to invite anyway."
	end
	for _, role in ipairs(ns.ROLES) do
		if c.fits[role] and not Inviter.pending[role] then
			return true, role, nil
		end
	end
	local waiting = Inviter.pending[c.role]
	return false, c.role, ("Waiting for %s's answer as %s first."):format(waiting and waiting.name or "?", ns.ROLE_LABEL[c.role] or "?")
end

-- A click on the + button: whisper and invite this player, then refresh the list (the click
-- allows the search).
function Inviter.InviteFromRow(c)
	local ok, role, why = Inviter.RowInvite(c)
	if not ok then
		return false, why
	end
	local sent, message = Inviter.InviteCandidate(c, role, "by hand")
	if sent then
		ns.Finder.Refresh(true)
	end
	return sent, message
end

-- Invites this candidate for this role now: the whisper and the invite go out together.
-- `source` says who asked, for the log ("by hand", "auto", "round"). Returns ok, message.
function Inviter.InviteCandidate(c, role, source)
	if not ns.settings.activityID then
		return false, "Pick a dungeon first."
	end
	if not Inviter.CanInvite() then
		return false, "Only the group leader can invite."
	end
	if not c or not c.name then
		return false, "That player's name cannot be read."
	end
	if Inviter.FindPending(c.name) then
		return false, ("%s is already invited."):format(c.name)
	end
	local state = ns.Finder.GroupState()
	if state.full then
		return false, "Your group is full."
	end
	role = role or Inviter.RoleFor(c, state)
	local waiting = Inviter.pending[role]
	if waiting then
		return false, ("Still waiting for %s to answer as %s."):format(waiting.name, ns.ROLE_LABEL[role])
	end

	local whispered = false
	local whisperNote = "no whisper (turned off)"
	if ns.settings.whisper then
		local text = Inviter.FormatMessage(c, role)
		local ok, err = sendWhisper(c.name, text)
		whispered = ok
		if ok then
			whisperNote = ('whispered "%s"'):format(text)
		else
			Inviter.lastWhisperError = err
			whisperNote = "whisper FAILED: " .. tostring(err)
		end
	end

	local ok, err = sendInvite(c.name)
	if not ok then
		Inviter.lastInviteError = err
		ns.asked[c.key] = { name = c.name, outcome = "failed", time = time(), role = role }
		addLog(("Invite to %s as %s FAILED: %s"):format(c.name, ns.ROLE_LABEL[role], err))
		ns.Finder.Evaluate()
		return false, "The invite failed: " .. err
	end

	inviteToken = inviteToken + 1
	local token = inviteToken
	Inviter.pending[role] = {
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
	ns.asked[c.key] = { name = c.name, outcome = "invited", time = time(), role = role }
	Inviter.invitesSent = Inviter.invitesSent + 1
	addLog(("Invited %s (%s %s) as %s (%s); %s"):format(c.name, ns.ClassName(c.class), tostring(c.level),
		ns.ROLE_LABEL[role], source or "by hand", whisperNote))
	ns.Print(("Invited %s as %s."):format(describe(c), ns.ROLE_LABEL[role]))

	local timeout = ns.Clamp(ns.settings.timeout, ns.MIN_TIMEOUT, ns.MAX_TIMEOUT)
	C_Timer.After(timeout, ns.Guard("invite timeout", function()
		local invite = Inviter.pending[role]
		if invite and invite.token == token then
			Inviter.Resolve(invite, "noanswer")
		end
	end))

	ns.Finder.Evaluate()
	return true, ("Invited %s as %s."):format(c.name, ns.ROLE_LABEL[role])
end

-- "Rules for Deadmines: Tank 1 (17+, Warrior/Druid/Paladin), Healer 1 (17+, any class), ...;
-- distinct classes off; you are DPS"
function Inviter.RulesText()
	local s = ns.settings
	local parts = {}
	for _, role in ipairs(ns.ROLES) do
		local rule = s.roles[role]
		local classes, count = {}, 0
		for _, class in ipairs(ns.CLASSES) do
			if rule.classes[class] then
				count = count + 1
				classes[#classes + 1] = ns.ClassName(class)
			end
		end
		local classText = count == #ns.CLASSES and "any class" or (count == 0 and "no class" or table.concat(classes, "/"))
		parts[#parts + 1] = ("%s %d (%d+, %s)"):format(ns.ROLE_LABEL[role], rule.need, rule.minLevel, classText)
	end
	return ("Rules for %s: %s; distinct classes %s; you are %s"):format(s.activityName or "?",
		table.concat(parts, ", "), s.distinctClasses and "on" or "off", ns.ROLE_LABEL[s.myRole] or "?")
end

-- The group is complete: say so once and stop auto mode.
function Inviter.Finish(state)
	-- A role check may still open a seat again; auto mode then picks up where it stopped.
	if Inviter.auto then
		Inviter.autoStoppedAt = GetTime()
		addLog(("Auto invite OFF (group %s)"):format(state.complete and "complete" or "full"))
	end
	Inviter.auto = false
	if state.complete and not Inviter.announcedComplete then
		Inviter.announcedComplete = true
		local members = {}
		for _, member in ipairs(state.members) do
			members[#members + 1] = ("%s %s"):format(ns.ROLE_LABEL[member.role], (tostring(member.name):gsub("%-", " ")))
		end
		addLog(("Group complete (%d players): you %s, %s"):format(state.size, ns.ROLE_LABEL[ns.settings.myRole] or "?",
			#members > 0 and table.concat(members, ", ") or "nobody else"))
		ns.Print("|cff60ff60Your group is complete!|r")
		if PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
			pcall(PlaySound, SOUNDKIT.READY_CHECK)
		end
	end
end

-- One round: one invite for each open role without an invite waiting, tank first, then healer,
-- then DPS. Each pick sees the ones before it (seats, distinct classes, the same player twice).
-- `fromClick` is true for a click or key press: then a round with nobody to invite may start a
-- fresh search, which the game only allows from such an action. Returns ok, message.
function Inviter.InviteRound(fromClick)
	if not ns.settings.activityID then
		return false, "Pick a dungeon first."
	end
	if not Inviter.CanInvite() then
		return false, "Only the group leader can invite."
	end
	local state = ns.Finder.Evaluate()
	if state.done and Inviter.PendingCount() == 0 then
		Inviter.Finish(state)
		return false, state.complete and "Your group is complete." or "Your group is full."
	end

	-- The rules in use, logged whenever they changed since the last round.
	local rules = Inviter.RulesText()
	if rules ~= Inviter.lastRulesLogged then
		Inviter.lastRulesLogged = rules
		addLog(rules)
	end

	local sent, failures, missing = {}, {}, {}
	for _, role in ipairs(ns.ROLES) do
		state = ns.Finder.Evaluate()
		if not Inviter.pending[role] and state.remaining[role] > 0 and not state.full then
			local c = ns.Finder.BestFor(role)
			if c then
				local ok, message = Inviter.InviteCandidate(c, role, Inviter.auto and "auto" or "round")
				if ok then
					sent[#sent + 1] = ("%s as %s"):format(c.name, ns.ROLE_LABEL[role])
				else
					failures[#failures + 1] = message
				end
			else
				missing[#missing + 1] = ns.ROLE_LABEL[role]
			end
		end
	end

	-- Who could not be found, logged when it changes (auto mode asks the same every few seconds).
	local missingText = #missing > 0
		and ("No match for %s among %d players listed alone"):format(table.concat(missing, " or "), #ns.Finder.candidates)
		or nil
	if missingText and missingText ~= Inviter.lastMissingLogged then
		addLog(missingText)
	end
	Inviter.lastMissingLogged = missingText

	if #sent > 0 then
		-- A fresh list for the next answers. From a click this is always allowed.
		ns.Finder.Refresh(fromClick)
		return true, "Invited " .. table.concat(sent, ", ") .. "."
	end
	if #failures > 0 then
		return false, failures[1]
	end
	if Inviter.PendingCount() > 0 then
		local text = "Waiting for " .. Inviter.PendingText() .. "."
		if #missing > 0 then
			text = text .. (" Nobody matches as %s yet."):format(table.concat(missing, " or "))
		end
		return false, text
	end
	local stale = not ns.Finder.lastResultsAt or GetTime() - ns.Finder.lastResultsAt > 15
	if fromClick and stale and not ns.Finder.searching then
		local ok, message = ns.Finder.Search()
		if ok then
			Inviter.inviteAfterSearch = true
		end
		return ok, message
	end
	return false, ("Nobody matches as %s right now. Search again in a moment."):format(table.concat(missing, " or "))
end

-- Kept for the key binding and slash command names.
Inviter.InviteNext = Inviter.InviteRound

-- Auto mode -----------------------------------------------------------------------------------

-- In auto mode, fills every free role right now. Only roles without an invite waiting get one,
-- so this is safe to call after any answer or roster change.
function Inviter.Continue()
	if not Inviter.auto then
		return
	end
	local _, message = Inviter.InviteRound(false)
	ns.SetStatus(message)
end

-- True when a role is open and has no invite waiting: new players would be useful.
function Inviter.HasOpenRole()
	local state = ns.Finder.GroupState()
	if state.full then
		return false
	end
	for _, role in ipairs(ns.ROLES) do
		if state.remaining[role] > 0 and not Inviter.pending[role] then
			return true
		end
	end
	return false
end

local tickerToken = 0

-- While auto mode runs, a fresh list every few seconds as long as a role waits for a player.
local function startRefreshTicker()
	tickerToken = tickerToken + 1
	local token = tickerToken
	local function tick()
		if token ~= tickerToken or not Inviter.auto then
			return
		end
		if Inviter.HasOpenRole() then
			ns.Finder.Refresh(false)
		end
		C_Timer.After(ns.Finder.AUTO_REFRESH, ns.Guard("auto refresh", tick))
	end
	C_Timer.After(ns.Finder.AUTO_REFRESH, ns.Guard("auto refresh", tick))
end

local function stopRefreshTicker()
	tickerToken = tickerToken + 1
end

Inviter.StartRefreshTicker = startRefreshTicker

-- Turns auto mode on. Called from a click, so it may search first.
function Inviter.Start()
	if not ns.settings.activityID then
		return false, "Pick a dungeon first."
	end
	if not Inviter.CanInvite() then
		return false, "Only the group leader can invite."
	end
	local state = ns.Finder.Evaluate()
	if state.done and Inviter.PendingCount() == 0 then
		return false, state.complete and "Your group is already complete." or "Your group is full."
	end
	Inviter.auto = true
	Inviter.announcedComplete = false
	addLog("Auto invite ON")
	startRefreshTicker()
	if not ns.Finder.lastResultsAt or GetTime() - ns.Finder.lastResultsAt > 30 then
		local ok, message = ns.Finder.Search()
		if ok then
			Inviter.inviteAfterSearch = true
			return true, message
		end
		Inviter.auto = false
		return false, message
	end
	local _, message = Inviter.InviteRound(true)
	return Inviter.auto, "Auto invite on. " .. message
end

function Inviter.Stop()
	if Inviter.auto then
		addLog("Auto invite OFF (stopped)")
	end
	Inviter.auto = false
	Inviter.autoStoppedAt = nil -- stopped by you: a role check does not turn it back on
	Inviter.inviteAfterSearch = false
	stopRefreshTicker()
	if Inviter.PendingCount() > 0 then
		return true, ("Auto invite off. Still waiting for %s."):format(Inviter.PendingText())
	end
	return true, "Auto invite off."
end

-- New search results: invites that waited for them go out now.
function Inviter.OnResults()
	if Inviter.inviteAfterSearch or Inviter.auto then
		Inviter.inviteAfterSearch = false
		local _, message = Inviter.InviteRound(false)
		ns.SetStatus(message)
	end
end

-- Answers ---------------------------------------------------------------------------------------

-- A joiner's seat, held until the roster shows them.
local function holdSeat(key, name, role, class)
	if key and role then
		Inviter.joining[key] = { name = name, role = role, class = class, at = GetTime() }
	end
end

-- Seats held by joiners who are still missing from the roster.
function Inviter.HeldSeats()
	local held = {}
	for key, seat in pairs(Inviter.joining) do
		if GetTime() - seat.at > JOINING_HOLD then
			Inviter.joining[key] = nil
		else
			held[#held + 1] = seat
		end
	end
	return held
end

-- Ends one invite with an outcome. In auto mode the freed role gets its next invite right away.
function Inviter.Resolve(invite, outcome)
	if not invite or Inviter.pending[invite.role] ~= invite then
		return
	end
	Inviter.pending[invite.role] = nil
	ns.asked[invite.key] = { name = invite.name, outcome = outcome, time = time(), role = invite.role }
	if outcome == "joined" then
		ns.db.memberRoles[invite.key] = { name = invite.name, role = invite.role, time = time() }
		holdSeat(invite.key, invite.name, invite.role, invite.class)
		if invite.role == "TANK" or invite.role == "HEALER" then
			Inviter.RequestRoleCheck()
		end
	end
	addLog(("%s (%s): %s after %d s%s"):format(invite.name, ns.ROLE_LABEL[invite.role],
		Inviter.OUTCOME_LOG[outcome] or outcome, math.floor(GetTime() - invite.sentAt),
		invite.confirmed and "" or " (server never confirmed the invite)"))
	ns.Print(("%s %s."):format(describe(invite), OUTCOME_PRINT[outcome] or outcome))

	local state = ns.Finder.Evaluate()
	if state.done and Inviter.PendingCount() == 0 then
		Inviter.Finish(state)
		ns.SetStatus(state.complete and "Your group is complete!" or "Your group is full.")
	elseif Inviter.auto then
		Inviter.Continue()
	else
		ns.SetStatus("Click Invite for the next round.")
	end
end

-- Someone joined: an invite in flight, or someone who accepted after EasyLFG gave up on them.
function Inviter.OnJoined(name)
	local invite = Inviter.FindPending(name)
	if invite then
		Inviter.Resolve(invite, "joined")
		return
	end
	local key = ns.MakeKey(name)
	local record = key and ns.asked[key]
	if record and record.role and record.outcome ~= "joined" then
		record.outcome = "joined"
		ns.db.memberRoles[key] = { name = name, role = record.role, time = time() }
		holdSeat(key, name, record.role, nil)
		addLog(("%s joined late (invited as %s, given up earlier)"):format(name, ns.ROLE_LABEL[record.role]))
		if record.role == "TANK" or record.role == "HEALER" then
			Inviter.RequestRoleCheck()
		end
		local state = ns.Finder.Evaluate()
		local need = ns.settings.roles[record.role].need
		if state.filled[record.role] > need then
			ns.Print(("|cffff6060%s joined late as %s: you now have more %s than you asked for.|r"):format(
				name, ns.ROLE_LABEL[record.role], ns.ROLE_LABEL[record.role]))
			addLog(("Too many %s: %d for %d wanted"):format(ns.ROLE_LABEL[record.role], state.filled[record.role], need))
		end
	end
end

-- Role checks ---------------------------------------------------------------------------------
-- When an invited tank or healer joins, EasyLFG starts a role check (InitiateRolePoll, open to
-- addons) so everyone confirms their role. Answers arrive as ROLE_CHANGED_INFORM and are also
-- what UnitGroupRolesAssigned shows; they count over the role someone was invited for. A player
-- who picks another role frees the seat they were invited for, and auto mode fills it again.

Inviter.roleCheck = { wanted = false, started = 0, answers = 0 }
local ROLE_CHECK_GAP = 5 -- seconds between two role checks
local ROLE_CHECK_FALLBACK = 3 -- start even if the roster never showed the joiner
local RESUME_WINDOW = 120 -- auto mode comes back on if a role check reopens a seat this soon

function Inviter.StartRoleCheck()
	local rc = Inviter.roleCheck
	rc.wanted = false
	if not InitiateRolePoll then
		rc.result = "this client has no InitiateRolePoll"
		return false, "This client cannot start a role check."
	end
	if not ns.Readable(IsInGroup()) then
		rc.result = "not in a group"
		return false, "You are not in a group."
	end
	if not Inviter.CanInvite() then
		rc.result = "not the leader"
		return false, "Only the group leader can start a role check."
	end
	local ok, result = pcall(InitiateRolePoll)
	rc.started = rc.started + 1
	rc.lastAt = GetTime()
	rc.result = ok and tostring(result) or ("error: " .. tostring(result))
	if not ok or result == false then
		addLog("Role check could not start: " .. rc.result)
		return false, "The role check could not start (" .. rc.result .. ")."
	end
	addLog("Role check started (" .. (rc.reason or "by hand") .. ")")
	rc.reason = nil
	return true, "Role check started: everyone confirms their role."
end

-- Starts the wanted role check once nobody who just joined is missing from the roster, and not
-- sooner than ROLE_CHECK_GAP after the previous one. `force` skips the roster wait.
function Inviter.TryRoleCheck(force)
	local rc = Inviter.roleCheck
	if not rc.wanted then
		return
	end
	if not force and #Inviter.HeldSeats() > 0 then
		return -- OnRoster tries again when the joiner shows up
	end
	local since = GetTime() - (rc.lastAt or -1000)
	if since < ROLE_CHECK_GAP then
		if not rc.queued then
			rc.queued = true
			C_Timer.After(ROLE_CHECK_GAP - since, ns.Guard("queued role check", function()
				rc.queued = false
				Inviter.TryRoleCheck(true)
			end))
		end
		return
	end
	local _, message = Inviter.StartRoleCheck()
	ns.SetStatus(message)
end

local lastUnknownSignature

-- On opening the window: if group members have no known role (not picked in a role check, not
-- invited by EasyLFG), ask them with a role check. Once per set of such members, so opening the
-- window again does not pester the group.
function Inviter.CheckUnknownRoles()
	if not ns.Readable(IsInGroup()) or not Inviter.CanInvite() then
		return
	end
	local state = ns.Finder.GroupState()
	local names = {}
	for _, member in ipairs(state.members) do
		if not member.known then
			names[#names + 1] = ns.MakeKey(member.name) or "?"
		end
	end
	if #names == 0 then
		return
	end
	table.sort(names)
	local signature = table.concat(names, ",")
	if signature == lastUnknownSignature then
		return
	end
	lastUnknownSignature = signature
	Inviter.roleCheck.wanted = true
	Inviter.roleCheck.reason = ("window opened, unknown role: %s"):format(signature)
	Inviter.TryRoleCheck(true)
end

function Inviter.RequestRoleCheck()
	Inviter.roleCheck.wanted = true
	Inviter.roleCheck.reason = "a tank or healer joined"
	C_Timer.After(ROLE_CHECK_FALLBACK, ns.Guard("role check fallback", function()
		Inviter.TryRoleCheck(true)
	end))
end

-- Roles changed (an answer, or the game's own update): count seats again and act on it.
function Inviter.AfterRoleChange()
	local state = ns.Finder.Evaluate()
	if state.done then
		if state.complete and Inviter.PendingCount() == 0 and not Inviter.announcedComplete and Inviter.invitesSent > 0 then
			Inviter.Finish(state)
		end
	else
		Inviter.announcedComplete = false
		local stoppedAt = Inviter.autoStoppedAt
		if not Inviter.auto and stoppedAt and GetTime() - stoppedAt <= RESUME_WINDOW then
			Inviter.autoStoppedAt = nil
			Inviter.auto = true
			Inviter.StartRefreshTicker()
			ns.Print("A seat opened again after the role check: auto invite is back on.")
			addLog("Auto invite ON again (a role check reopened a seat)")
		end
		Inviter.Continue()
	end
	ns.Refresh()
end

function Inviter.OnRoleChanged(_, changedName, _, _, newRole)
	changedName, newRole = ns.Readable(changedName), ns.Readable(newRole)
	if type(changedName) ~= "string" or not ns.ROLE_LABEL[newRole] then
		return
	end
	local rc = Inviter.roleCheck
	rc.answers = rc.answers + 1
	rc.lastAnswer = changedName .. ": " .. newRole

	local me = ns.ReadUnitName("player")
	if me and ns.SameName(changedName, me) then
		ns.settings.myRole = newRole
		addLog(("Role check: you picked %s"):format(ns.ROLE_LABEL[newRole]))
	else
		local record, key = ns.Finder.MemberRecord(changedName)
		if not record then
			key = ns.MakeKey(changedName)
			record = { name = changedName, time = time() }
			if key then
				ns.db.memberRoles[key] = record
			end
		end
		record.chosen = newRole
		local invitedFor = record.role
		if invitedFor and invitedFor ~= newRole then
			ns.Print(("|cffffd100%s picked %s in the role check (invited as %s): the %s seat is open again.|r"):format(
				changedName, ns.ROLE_LABEL[newRole], ns.ROLE_LABEL[invitedFor], ns.ROLE_LABEL[invitedFor]))
			addLog(("Role check: %s picked %s but was invited as %s; the %s seat is open again"):format(
				changedName, ns.ROLE_LABEL[newRole], ns.ROLE_LABEL[invitedFor], ns.ROLE_LABEL[invitedFor]))
		else
			addLog(("Role check: %s picked %s"):format(changedName, ns.ROLE_LABEL[newRole]))
		end
	end

	local state = ns.Finder.Evaluate()
	local need = ns.settings.roles[newRole].need
	if state.filled[newRole] > need then
		ns.Print(("|cffff6060You now have %d %s for %d wanted.|r"):format(state.filled[newRole], ns.ROLE_LABEL[newRole], need))
		addLog(("Too many %s: %d for %d wanted"):format(ns.ROLE_LABEL[newRole], state.filled[newRole], need))
	end
	Inviter.AfterRoleChange()
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
-- Messages without a name. With several invites in flight they cannot be tied to one, so they
-- only count when a single invite waits.
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
	for _, entry in ipairs(namedPatterns()) do
		local who = text:match(entry.pattern)
		if who then
			Inviter.lastSystem = entry.source .. ": " .. who
			if entry.outcome == "joined" then
				Inviter.OnJoined(who)
			else
				local invite = Inviter.FindPending(who)
				if invite then
					if entry.outcome == "sent" then
						invite.confirmed = true
					else
						Inviter.Resolve(invite, entry.outcome)
					end
				end
			end
			ns.Refresh()
			return
		end
	end
	if Inviter.PendingCount() == 1 then
		local _, invite = next(Inviter.pending)
		for _, entry in ipairs(PLAIN_MESSAGES) do
			if _G[entry[1]] and text == _G[entry[1]] then
				Inviter.lastSystem = entry[1]
				Inviter.Resolve(invite, entry[2])
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
			-- In the roster now: the held seat is a real one.
			for key, seat in pairs(Inviter.joining) do
				if ns.SameName(seat.name, name) then
					Inviter.joining[key] = nil
				end
			end
		end
	end
	-- A tank or healer who just joined is in the roster now: time for the role check.
	Inviter.TryRoleCheck()
	if Inviter.auto and not Inviter.CanInvite() then
		addLog("You are no longer the group leader")
		Inviter.Stop()
		ns.SetStatus("You are no longer the group leader; auto invite is off.")
	end
	local state = ns.Finder.Evaluate()
	if state.done and Inviter.PendingCount() == 0 then
		if Inviter.auto then
			Inviter.Finish(state)
		elseif state.complete and not Inviter.announcedComplete and ns.settings.activityID and Inviter.invitesSent > 0 then
			Inviter.Finish(state)
		end
	elseif not state.done then
		Inviter.announcedComplete = false
		-- Someone left while auto mode runs: fill the seat again.
		Inviter.Continue()
	end
	ns.Refresh()
end

-- The game blocked one of our calls: auto mode cannot work here, so it stops and says why.
function Inviter.OnBlocked(functionName)
	local fn = tostring(functionName)
	if fn:find("Search") then
		-- Only an automatic search can be refused; auto invites go on, the list needs a click.
		ns.Finder.SearchRefused("blocked: " .. fn)
		return
	end
	if fn:find("Invite") or fn:find("ChatMessage") then
		if Inviter.auto then
			Inviter.Stop()
		end
		if fn:find("Invite") then
			ns.SetStatus("The game wants a click for each invite: use Invite or its key binding.")
		else
			ns.SetStatus("The game blocked the whisper. Untick 'Whisper' or invite with a click.")
		end
	end
end

ns.On("CHAT_MSG_SYSTEM", "system message", Inviter.OnSystemMessage)
ns.On("GROUP_ROSTER_UPDATE", "roster", Inviter.OnRoster)
ns.On("ROLE_CHANGED_INFORM", "role changed", Inviter.OnRoleChanged)
ns.On("PLAYER_ROLES_ASSIGNED", "roles assigned", function()
	Inviter.AfterRoleChange()
end)
