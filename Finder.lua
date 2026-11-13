-- EasyLFG Finder: reads the Group Finder. It lists the dungeons, runs a search for the chosen one,
-- reads the players who listed themselves alone, and judges each against your rules: which role
-- they would fill, or why they do not fit.
--
-- Blizzard's own Vanilla-style Group Finder (Blizzard_GroupFinder_VanillaStyle) reads the same
-- data: GetSearchResultInfo for the listing, GetSearchResultPlayerInfo(id, 1) for a solo player's
-- class, level and the roles (lfgRoles) they ticked. Its Invite button invites leaderName.

local _, ns = ...

local Finder = {}
ns.Finder = Finder

Finder.candidates = {} -- one per solo player listed for the chosen dungeon, best first
Finder.skipped = {} -- keys you skipped by hand, for this session
Finder.stats = {}
Finder.searching = false
Finder.lastSearchAt = nil
Finder.lastResultsAt = nil
Finder.lastSearchError = nil
Finder.searchCount = 0
Finder.resultEvents = 0

local OUTCOME_TEXT = {
	invited = "invited earlier, no answer",
	declined = "declined",
	busy = "already in a group",
	noanswer = "did not answer",
	notfound = "could not be found",
	ignored = "ignores you",
	failed = "invite failed",
}
Finder.OUTCOME_TEXT = OUTCOME_TEXT

-- Order of the list: who gets invited first, then the rest.
local STATUS_ORDER = { invited = 1, match = 2, nofit = 3, asked = 4, skipped = 5, delisted = 6, ingroup = 7, hidden = 8 }

-- Activities -------------------------------------------------------------------------------

function Finder.ActivityInfo(activityID)
	if not activityID or not C_LFGList or not C_LFGList.GetActivityInfoTable then
		return nil
	end
	local ok, info = pcall(C_LFGList.GetActivityInfoTable, activityID)
	if ok and type(info) == "table" then
		return info
	end
	return nil
end

function Finder.ActivityName(info)
	if not info then
		return nil
	end
	local short, full = ns.Readable(info.shortName), ns.Readable(info.fullName)
	if type(short) == "string" and short ~= "" then
		return short
	end
	if type(full) == "string" and full ~= "" then
		return full
	end
	return nil
end

-- Every activity a party of five can do, grouped by Group Finder category:
-- { { categoryID, name, activities = { { id, categoryID, name, minLevel, maxLevel } } } }
function Finder.ListActivities()
	local groups = {}
	if not C_LFGList or not C_LFGList.GetAvailableCategories or not C_LFGList.GetAvailableActivities then
		return groups
	end
	local ok, categories = pcall(C_LFGList.GetAvailableCategories)
	if not ok or type(categories) ~= "table" then
		return groups
	end
	for _, categoryID in ipairs(categories) do
		local okActivities, activityIDs = pcall(C_LFGList.GetAvailableActivities, categoryID)
		if okActivities and type(activityIDs) == "table" then
			local list = {}
			for _, activityID in ipairs(activityIDs) do
				local info = Finder.ActivityInfo(activityID)
				local size = info and tonumber(ns.Readable(info.maxNumPlayers)) or 0
				if info and size <= ns.MAX_PARTY then
					list[#list + 1] = {
						id = activityID,
						categoryID = categoryID,
						name = Finder.ActivityName(info) or ("Activity " .. activityID),
						minLevel = tonumber(ns.Readable(info.minLevelSuggestion)) or tonumber(ns.Readable(info.minLevel)) or 0,
						maxLevel = tonumber(ns.Readable(info.maxLevelSuggestion)) or 0,
						order = tonumber(ns.Readable(info.orderIndex)) or 0,
					}
				end
			end
			if #list > 0 then
				table.sort(list, function(a, b)
					if a.minLevel ~= b.minLevel then
						return a.minLevel < b.minLevel
					end
					if a.order ~= b.order then
						return a.order < b.order
					end
					return a.name < b.name
				end)
				local name
				if C_LFGList.GetLfgCategoryInfo then
					local okInfo, categoryInfo = pcall(C_LFGList.GetLfgCategoryInfo, categoryID)
					name = okInfo and type(categoryInfo) == "table" and ns.Readable(categoryInfo.name) or nil
				end
				groups[#groups + 1] = { categoryID = categoryID, name = name or ("Category " .. categoryID), activities = list }
			end
		end
	end
	return groups
end

-- Picks the dungeon. The minimum levels follow the dungeon's suggested level; you can still change
-- them afterwards.
function Finder.SetActivity(activity)
	local s = ns.settings
	s.activityID = activity.id
	s.activityName = activity.name
	s.categoryID = activity.categoryID
	ns.Log(("Dungeon set: %s (activity %s)"):format(tostring(activity.name), tostring(activity.id)))
	if activity.minLevel and activity.minLevel > 0 then
		for _, role in ipairs(ns.ROLES) do
			s.roles[role].minLevel = ns.Clamp(activity.minLevel, 1, ns.MAX_LEVEL)
		end
	end
	Finder.Scan()
end

-- The group ----------------------------------------------------------------------------------

-- The units of the other group members.
function Finder.GroupUnits()
	local units = {}
	if IsInRaid and ns.Readable(IsInRaid()) then
		for i = 1, (GetNumGroupMembers() or 0) do
			local unit = "raid" .. i
			if not ns.Readable(UnitIsUnit(unit, "player")) then
				units[#units + 1] = unit
			end
		end
	else
		local count = GetNumSubgroupMembers and GetNumSubgroupMembers() or 0
		for i = 1, (ns.Readable(count) or 0) do
			units[#units + 1] = "party" .. i
		end
	end
	return units
end

-- What EasyLFG knows about a member: { role = invited for, chosen = picked in a role check }.
function Finder.MemberRecord(name)
	if not name then
		return nil, nil
	end
	local roles = ns.db.memberRoles
	local key = ns.MakeKey(name) or ""
	if roles[key] then
		return roles[key], key
	end
	for otherKey, record in pairs(roles) do
		if ns.SameName(otherKey, name) then
			return record, otherKey
		end
	end
	return nil, nil
end

-- The role the game shows for a unit after a role check, or nil.
function Finder.AssignedRole(unit)
	if not UnitGroupRolesAssigned then
		return nil
	end
	local assigned = ns.Readable(UnitGroupRolesAssigned(unit))
	return ns.ROLE_LABEL[assigned] and assigned or nil
end

-- A member's role, most reliable first. For someone EasyLFG invited: their last answer to a role
-- check (or role change) as EasyLFG heard it, else the role they were invited for. The game's
-- role alone is not trusted for them: a fresh joiner gets a default role (often DPS) before
-- answering, which would make their seat look free. For anyone else: the game's role, then an
-- answer EasyLFG heard, then DPS as a guess.
local function memberRole(name, unit)
	local assigned = Finder.AssignedRole(unit)
	local record = Finder.MemberRecord(name)
	if record and ns.ROLE_LABEL[record.role] then
		return ns.ROLE_LABEL[record.chosen] and record.chosen or record.role, true
	end
	if assigned then
		return assigned, true
	end
	if record and ns.ROLE_LABEL[record.chosen] then
		return record.chosen, true
	end
	return "DAMAGER", false
end

-- Who is in the group, what is still missing, and which classes are taken. Invites in flight
-- count as if they were accepted, so nobody is invited for the same seat twice.
function Finder.GroupState()
	local s = ns.settings
	local state = {
		filled = { TANK = 0, HEALER = 0, DAMAGER = 0 },
		remaining = {},
		classes = {},
		members = {},
		size = 1,
		unknownRoles = 0,
	}
	-- Your seat is your "I am" setting. The game's role for you is not read here: everyone is marked
	-- DPS by default. Only the EasyLFG window changes "I am", never a role check answer.
	local myRole = ns.ROLE_LABEL[s.myRole] and s.myRole or "DAMAGER"
	state.filled[myRole] = state.filled[myRole] + 1
	local myClass = ns.Readable((select(2, UnitClass("player"))))
	if myClass then
		state.classes[myClass] = true
	end

	for _, unit in ipairs(Finder.GroupUnits()) do
		state.size = state.size + 1
		local name = ns.ReadUnitName(unit)
		local class = ns.Readable((select(2, UnitClass(unit))))
		if class then
			state.classes[class] = true
		end
		local role, known = memberRole(name, unit)
		if not known then
			state.unknownRoles = state.unknownRoles + 1
		end
		state.filled[role] = state.filled[role] + 1
		state.members[#state.members + 1] = { name = name, class = class, role = role, known = known }
	end

	-- Joined, but not in the roster yet: their seat is taken all the same.
	if ns.Inviter then
		for _, seat in ipairs(ns.Inviter.HeldSeats()) do
			if not Finder.InGroup(seat.name, state) then
				state.size = state.size + 1
				state.filled[seat.role] = state.filled[seat.role] + 1
				if seat.class then
					state.classes[seat.class] = true
				end
				state.members[#state.members + 1] = { name = seat.name, class = seat.class, role = seat.role, known = true }
			end
		end
	end

	state.pending = ns.Inviter and ns.Inviter.pending or {}
	for role, invite in pairs(state.pending) do
		state.size = state.size + 1
		state.filled[role] = state.filled[role] + 1
		if invite.class then
			state.classes[invite.class] = true
		end
	end

	local complete = true
	for _, role in ipairs(ns.ROLES) do
		state.remaining[role] = math.max(0, (s.roles[role].need or 0) - state.filled[role])
		if state.remaining[role] > 0 then
			complete = false
		end
	end
	state.free = math.max(0, ns.MAX_PARTY - state.size)
	state.full = state.free == 0
	state.complete = complete
	state.done = complete or state.full
	return state
end

function Finder.InGroup(name, state)
	for _, member in ipairs(state.members) do
		if member.name and ns.SameName(member.name, name) then
			return true
		end
	end
	return false
end

-- Search results ---------------------------------------------------------------------------

local function readPlayer(resultID)
	for _, getter in ipairs({ "GetSearchResultPlayerInfo", "GetSearchResultLeaderInfo" }) do
		local fn = C_LFGList[getter]
		if fn then
			local ok, player
			if getter == "GetSearchResultPlayerInfo" then
				ok, player = pcall(fn, resultID, 1)
			else
				ok, player = pcall(fn, resultID)
			end
			if ok and type(player) == "table" then
				return player
			end
		end
	end
	return nil
end

-- One listing as a candidate, or nil when it cannot be read at all.
function Finder.ReadResult(resultID)
	local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local c = {
		resultID = resultID,
		numMembers = ns.Readable(info.numMembers),
		delisted = ns.Readable(info.isDelisted) == true,
		hasSelf = ns.Readable(info.hasSelf) == true,
		age = tonumber(ns.Readable(info.age)) or 0,
		comment = ns.Readable(info.comment),
		activities = {},
		roles = {},
	}
	local activityIDs = ns.Readable(info.activityIDs)
	if type(activityIDs) == "table" then
		for _, activityID in ipairs(activityIDs) do
			local id = ns.Readable(activityID)
			if id then
				c.activities[id] = true
			end
		end
	end

	-- Blizzard invites leaderName, so that spelling is the one to use.
	local name = ns.Readable(info.leaderName)
	local player = readPlayer(resultID)
	if player then
		if type(name) ~= "string" or name == "" then
			name = ns.Readable(player.name)
		end
		c.class = ns.Readable(player.classFilename)
		c.level = tonumber(ns.Readable(player.level))
		c.area = ns.Readable(player.areaName)
		local roles = ns.Readable(player.lfgRoles)
		if type(roles) == "table" then
			for role, flag in pairs(ns.ROLE_FLAG) do
				if ns.Readable(roles[flag]) == true then
					c.roles[role] = true
				end
			end
		end
	end
	if type(name) == "string" and name ~= "" then
		c.name = name
		c.key = ns.MakeKey(name)
	end
	c.readable = c.key ~= nil and type(c.class) == "string" and type(c.level) == "number"
	return c
end

-- What EasyLFG remembers about asking this player this session, if it keeps them from a new invite.
function Finder.AskedRecord(key)
	local record = key and ns.asked[key]
	if type(record) ~= "table" or record.outcome == "joined" or record.outcome == "invited" then
		return nil
	end
	return record
end

-- The invite in flight for this player, if any.
function Finder.PendingInvite(name, state)
	for _, invite in pairs(state.pending) do
		if ns.SameName(invite.name, name) then
			return invite
		end
	end
	return nil
end

local function askedText(record)
	local text = OUTCOME_TEXT[record.outcome] or record.outcome
	local minutes = math.floor((time() - (record.time or time())) / 60)
	if minutes >= 1 then
		text = ("%s, %d min ago"):format(text, minutes)
	end
	return text
end

-- Decides what to do with one candidate: c.role is set when they fit, c.reason says why or why not.
function Finder.Judge(c, state)
	local s = ns.settings
	c.role, c.reason, c.status, c.guessedRole = nil, nil, nil, nil
	c.fits = {}
	if not c.readable then
		c.status, c.reason = "hidden", "details hidden by the game"
		return
	end
	local invite = Finder.PendingInvite(c.name, state)
	if invite then
		c.status, c.role = "invited", invite.role
		c.reason = ("invited as %s, waiting for an answer"):format(ns.ROLE_LABEL[invite.role])
		return
	end
	if Finder.InGroup(c.name, state) then
		c.status, c.reason = "ingroup", "in your group"
		return
	end
	local record = Finder.AskedRecord(c.key)
	if record then
		c.status, c.reason = "asked", askedText(record)
		return
	end
	if Finder.skipped[c.key] then
		c.status, c.reason = "skipped", "skipped by you"
		return
	end
	if c.delisted then
		c.status, c.reason = "delisted", "listing closed"
		return
	end
	if state.done then
		c.status, c.reason = "nofit", state.complete and "group complete" or "group full"
		return
	end

	local roles = c.roles
	if not next(roles) then
		-- Listed without a role: taken as DPS, which is what most such players are.
		roles = { DAMAGER = true }
		c.guessedRole = true
	end
	local problem, problemIsFullSlot
	for _, role in ipairs(ns.ROLES) do
		if roles[role] then
			local rule = s.roles[role]
			local label = ns.ROLE_LABEL[role]
			local text, fullSlot
			if state.remaining[role] <= 0 then
				text, fullSlot = ("no %s needed"):format(label), true
			elseif not rule.classes[c.class] then
				text = ("%s not wanted as %s"):format(ns.ClassName(c.class), label)
			elseif c.level < (rule.minLevel or 1) then
				text = ("level %d, %s needs %d"):format(c.level, label, rule.minLevel)
			elseif s.distinctClasses and state.classes[c.class] then
				text = ("%s already in the group"):format(ns.ClassName(c.class))
			end
			if not text then
				c.fits[role] = true
				c.role = c.role or role
			-- A real mismatch says more than a seat that is already taken.
			elseif not problem or (problemIsFullSlot and not fullSlot) then
				problem, problemIsFullSlot = text, fullSlot
			end
		end
	end
	if c.role then
		local labels = {}
		for _, role in ipairs(ns.ROLES) do
			if c.fits[role] then
				labels[#labels + 1] = ns.ROLE_LABEL[role]
			end
		end
		c.status = "match"
		c.reason = ("fits as %s"):format(table.concat(labels, " or ")) .. (c.guessedRole and " (no role listed)" or "")
	else
		c.status, c.reason = "nofit", problem or "does not fit"
	end
end

local ROLE_INDEX = { TANK = 1, HEALER = 2, DAMAGER = 3 }

local function compare(a, b)
	local orderA, orderB = STATUS_ORDER[a.status] or 9, STATUS_ORDER[b.status] or 9
	if orderA ~= orderB then
		return orderA < orderB
	end
	if a.status == "match" then
		if a.role ~= b.role then
			return ROLE_INDEX[a.role] < ROLE_INDEX[b.role]
		end
		if (a.level or 0) ~= (b.level or 0) then
			return (a.level or 0) > (b.level or 0)
		end
		-- The one who has waited longest goes first.
		if a.age ~= b.age then
			return a.age > b.age
		end
	end
	return (a.name or "") < (b.name or "")
end

-- Judges everyone again against the group as it is now. Returns the group state.
function Finder.Evaluate()
	local state = Finder.GroupState()
	Finder.state = state
	local eligible = 0
	for _, c in ipairs(Finder.candidates) do
		Finder.Judge(c, state)
		if c.status == "match" then
			eligible = eligible + 1
		end
	end
	table.sort(Finder.candidates, compare)
	Finder.stats.eligible = eligible
	return state
end

-- Reads the current search results again. Any search counts, also one made in Blizzard's window.
function Finder.Scan()
	local list, seen = {}, {}
	local stats = { results = 0, solo = 0, groups = 0, hidden = 0, otherActivity = 0, eligible = 0 }
	local activityID = ns.settings.activityID
	if activityID and C_LFGList and C_LFGList.GetSearchResults then
		local ok, _, results = pcall(C_LFGList.GetSearchResults)
		if ok and type(results) == "table" then
			for _, resultID in ipairs(results) do
				stats.results = stats.results + 1
				local c = Finder.ReadResult(resultID)
				if c and not c.hasSelf then
					if c.numMembers ~= 1 then
						stats.groups = stats.groups + 1
					elseif not c.activities[activityID] then
						stats.otherActivity = stats.otherActivity + 1
					else
						stats.solo = stats.solo + 1
						if not c.readable then
							stats.hidden = stats.hidden + 1
						end
						local dedupe = c.key or ("result" .. tostring(resultID))
						if not seen[dedupe] then
							seen[dedupe] = true
							list[#list + 1] = c
						end
					end
				end
			end
		end
	end
	Finder.candidates = list
	Finder.stats = stats
	return Finder.Evaluate()
end

-- The best candidate for one role right now, or nil: highest level, then longest listed.
function Finder.BestFor(role)
	Finder.Evaluate()
	local best
	for _, c in ipairs(Finder.candidates) do
		if c.status == "match" and c.fits[role] then
			if not best or c.level > best.level or (c.level == best.level and c.age > best.age) then
				best = c
			end
		end
	end
	return best
end

function Finder.FindCandidate(name)
	for _, c in ipairs(Finder.candidates) do
		if c.name and ns.SameName(c.name, name) then
			return c
		end
	end
	return nil
end

-- Searching ----------------------------------------------------------------------------------

-- The list is refreshed after every invite; while an open role has nobody listed, every
-- HUNT_REFRESH seconds until someone is (in auto mode, or while the window is open); and in auto
-- mode every AUTO_REFRESH seconds anyway. A search from a click or key press is always allowed.
-- One that is not may be refused by the game: then EasyLFG stops trying for the session and asks
-- for a click instead. A refusal shows up as ADDON_ACTION_BLOCKED or as a search that never
-- answers. A search the server answers with LFG_LIST_SEARCH_FAILED (busy, throttled) only pauses
-- automatic searches for FAIL_PAUSE seconds.
Finder.MIN_SEARCH_GAP = 5 -- seconds between two searches EasyLFG starts itself
Finder.HUNT_REFRESH = 5 -- seconds between searches while an open role has nobody listed
Finder.AUTO_REFRESH = 10 -- seconds between refreshes in auto mode while a role is open
Finder.FAIL_PAUSE = 15 -- seconds without automatic searches after the server failed one
Finder.searchFailures = 0
local SEARCH_WATCHDOG = 10 -- a search without an answer after this long counts as failed
local SILENT_FAILS_TO_GIVE_UP = 2

Finder.searchNeedsClick = false -- set once the game refused a search that was not from a click
Finder.searchFromClick = true -- what started the search in flight
Finder.silentFails = 0
Finder.autoSearches = 0
local searchToken = 0
local refreshQueued = false

-- The game refused a search that was not from a click: from now on only clicks search.
function Finder.SearchRefused(why)
	Finder.searching = false
	if not Finder.searchNeedsClick then
		Finder.searchNeedsClick = true
		Finder.lastSearchError = why
		ns.Log("Automatic searches refused (" .. tostring(why) .. "): from now on only Search clicks refresh the list")
		ns.Print("The game only allows a Group Finder search from a click here. Press |cffffd100Search|r (or its key binding) to refresh the list.")
	end
	ns.SetStatus("Press Search for a fresh list: the game refused an automatic search.")
end

-- Asks the server for the listings of the chosen dungeon, and nothing else. `auto` is true when
-- the call does not come from a click or key press.
function Finder.Search(auto)
	local s = ns.settings
	if not s.activityID then
		return false, "Pick a dungeon first."
	end
	if not C_LFGList or not C_LFGList.Search then
		return false, "This client has no Group Finder search."
	end
	if auto and Finder.searchNeedsClick then
		return false, "Press Search for a fresh list."
	end
	local categoryID = s.categoryID
	if not categoryID then
		local info = Finder.ActivityInfo(s.activityID)
		categoryID = info and ns.Readable(info.categoryID)
	end
	if not categoryID then
		return false, "The dungeon's Group Finder category is unknown; pick the dungeon again."
	end
	local ok, err = pcall(C_LFGList.Search, categoryID, 0, 0, nil, false, nil, { s.activityID })
	Finder.lastSearchAt = GetTime()
	Finder.searchCount = Finder.searchCount + 1
	if not ok then
		Finder.lastSearchError = tostring(err)
		ns.Log("Search FAILED: " .. tostring(err))
		return false, "The search failed: " .. tostring(err)
	end
	Finder.searching = true
	Finder.searchFromClick = not auto
	Finder.searchSentAt = GetTime()
	Finder.lastSearchError = nil
	if auto then
		Finder.autoSearches = Finder.autoSearches + 1
	end
	searchToken = searchToken + 1
	local token = searchToken
	C_Timer.After(SEARCH_WATCHDOG, ns.Guard("search watchdog", function()
		if token ~= searchToken or not Finder.searching then
			return
		end
		-- No answer at all: the search did not happen.
		Finder.searching = false
		ns.Log(("Search (%s) got no answer within %d s"):format(auto and "automatic" or "click", SEARCH_WATCHDOG))
		if auto then
			Finder.silentFails = Finder.silentFails + 1
			if Finder.silentFails >= SILENT_FAILS_TO_GIVE_UP then
				Finder.SearchRefused("automatic searches get no answer")
				return
			end
		end
		ns.Refresh()
	end))
	return true, ("Searching the Group Finder for %s..."):format(s.activityName or "your dungeon")
end

-- Refreshes the list unless a search is running or the last one is too recent; a refresh that is
-- too early waits for the gap. `fromClick` as for InviteRound.
function Finder.Refresh(fromClick)
	if not ns.settings.activityID or Finder.searching then
		return false
	end
	if not fromClick and (Finder.searchNeedsClick or GetTime() < (Finder.pauseUntil or 0)) then
		return false
	end
	local since = GetTime() - (Finder.lastSearchAt or -1000)
	if since < Finder.MIN_SEARCH_GAP then
		if not refreshQueued then
			refreshQueued = true
			C_Timer.After(Finder.MIN_SEARCH_GAP - since, ns.Guard("queued refresh", function()
				refreshQueued = false
				Finder.Refresh(false)
			end))
		end
		return false
	end
	return Finder.Search(not fromClick)
end

local rescanQueued = false

-- Several listings change at once; one rescan half a second later covers them all.
function Finder.QueueScan()
	if rescanQueued then
		return
	end
	rescanQueued = true
	C_Timer.After(0.5, ns.Guard("rescan", function()
		rescanQueued = false
		Finder.Scan()
		ns.Refresh()
	end))
end

-- The server answered the search with a failure (busy, too many searches): the game does allow the
-- search, so this is not a refusal; automatic searches just pause a little.
ns.On("LFG_LIST_SEARCH_FAILED", "search failed", function(_, reason)
	reason = ns.Readable(reason)
	local auto = Finder.searching and not Finder.searchFromClick
	Finder.searching = false
	Finder.searchFailures = Finder.searchFailures + 1
	Finder.lastSearchError = "server: " .. tostring(reason or "no reason given")
	if auto then
		Finder.silentFails = 0
		Finder.pauseUntil = GetTime() + Finder.FAIL_PAUSE
	end
	ns.Log(("Search failed on the server (%s)%s"):format(tostring(reason or "no reason given"),
		auto and (", automatic searches pause %d s"):format(Finder.FAIL_PAUSE) or ""))
	ns.Refresh()
end)

ns.On("LFG_LIST_SEARCH_RESULTS_RECEIVED", "search results", function()
	local source
	if Finder.searching then
		source = Finder.searchFromClick and "your click" or "automatic"
		if not Finder.searchFromClick then
			Finder.silentFails = 0 -- automatic searches work on this client
		end
	else
		source = "Blizzard's window or another addon"
	end
	Finder.searching = false
	Finder.lastResultsAt = GetTime()
	Finder.resultEvents = Finder.resultEvents + 1
	Finder.Scan()
	local stats = Finder.stats
	if ns.settings.activityID then
		ns.Log(("List refreshed (%s): %d listings, %d alone for %s, %d hidden, %d match"):format(source,
			stats.results or 0, stats.solo or 0, ns.settings.activityName or "?", stats.hidden or 0, stats.eligible or 0))
	end
	if ns.Inviter then
		ns.Inviter.OnResults()
	end
	ns.Refresh()
end)

ns.On("LFG_LIST_SEARCH_FAILED", "search failed", function(_, reason)
	Finder.searching = false
	Finder.lastSearchError = "search failed" .. (ns.Readable(reason) and (": " .. tostring(reason)) or "")
	ns.Log("Group Finder: " .. Finder.lastSearchError)
	-- Usually the server asking us to slow down: auto mode tries again on its next refresh.
	if ns.Inviter and ns.Inviter.auto then
		ns.SetStatus("The Group Finder search failed; auto mode tries again shortly.")
	else
		ns.SetStatus("The Group Finder search failed. Try again in a moment.")
	end
end)

ns.On("LFG_LIST_SEARCH_RESULT_UPDATED", "result updated", function()
	Finder.QueueScan()
end)
