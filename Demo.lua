-- EasyLFG demo: the whole flow with made-up players, and nothing sent to the game. It runs in its
-- own window, opened with /elfg demo only (UI.ToggleDemo): opening it starts the demo, closing it
-- ends the demo.
--
-- While the demo runs, ns.Game (Core.lua) is swapped for a simulation: searches list made-up
-- players for your dungeon, invites and whispers go nowhere, each made-up player answers after a
-- few seconds (joins, declines, is already in a group, or lets the invite run out), joiners make
-- up a pretend group, and the role check is answered by them. Your settings are used as they are;
-- who was asked, the roles of members and the search state are put aside and come back when the
-- demo ends. Log lines and chat messages are marked [demo].

local _, ns = ...

local Demo = {}
ns.Demo = Demo

Demo.active = false
Demo.session = 0
Demo.pool = {} -- listed made-up players: { id, name, class, level, roles, listedAt, age, comment }
Demo.roster = {} -- made-up players in the pretend group: { name, class, role (as the game shows), listing }
Demo.script = nil -- tests: a list of outcomes to use in turn instead of random ones

local POOL_START = { TANK = 3, HEALER = 3, DAMAGER = 8 }
local POOL_MAX = 24
local ARRIVAL_MIN, ARRIVAL_MAX = 20, 40 -- seconds between two new listings
local OUTCOMES = { -- weights
	{ "joined", 55 },
	{ "declined", 20 },
	{ "busy", 10 },
	{ "slow", 15 }, -- leaves the invite unanswered: it closes itself as a decline
}
local SLOW_DECLINE = 25 -- seconds before an unanswered demo invite closes itself
local OTHER_ROLE_CHANCE = 0.15 -- a role check answer other than the invited role

local FIRST = { "Aldric", "Brenna", "Corvin", "Dagny", "Elric", "Fenna", "Garrick", "Hilde", "Ivor",
	"Jorun", "Kael", "Liora", "Maren", "Nils", "Odessa", "Perrin", "Quill", "Rowena", "Soren", "Talia",
	"Ulric", "Vesna", "Wren", "Yorick", "Zara", "Bram", "Edda", "Torin", "Mira", "Halvard" }
local LAST = { "Ashford", "Blackwood", "Coldbrook", "Dunmore", "Emberly", "Fairwind", "Greyhelm",
	"Hollowell", "Ironside", "Kettleby", "Longmere", "Mossgrove", "Northcott", "Oakheart", "Pellwood",
	"Ravenhill", "Stonebrook", "Thornfield", "Underhill", "Westvale", "Wolfsbane", "Brightwater" }
local AREAS = { "Orgrimmar", "Stormwind City", "Ironforge", "Thunder Bluff", "The Barrens", "Westfall" }
local COMMENTS = { "", "", "", "lf group", "need xp", "first time here", "quest run pls", "fast run" }

-- Randomness --------------------------------------------------------------------------------------

local function random(low, high)
	return math.random(low, high)
end

local function pick(list)
	return list[random(1, #list)]
end

local function chance(p)
	return math.random() < p
end

-- A player's answer to an invite: from Demo.script when a test set one, else by weight.
function Demo.NextOutcome()
	if Demo.script and #Demo.script > 0 then
		return table.remove(Demo.script, 1)
	end
	local total = 0
	for _, entry in ipairs(OUTCOMES) do
		total = total + entry[2]
	end
	local roll = random(1, total)
	for _, entry in ipairs(OUTCOMES) do
		roll = roll - entry[2]
		if roll <= 0 then
			return entry[1]
		end
	end
	return "joined"
end

-- Runs fn after `seconds`, unless the demo ended (or restarted) in the meantime.
local function later(seconds, label, fn)
	local session = Demo.session
	C_Timer.After(seconds, ns.Guard("demo " .. label, function()
		if Demo.active and Demo.session == session then
			fn()
		end
	end))
end

-- Made-up players -------------------------------------------------------------------------------

local nextID = 0

local function nameTaken(name)
	for _, entry in ipairs(Demo.pool) do
		if entry.name == name then
			return true
		end
	end
	for _, member in ipairs(Demo.roster) do
		if member.name == name then
			return true
		end
	end
	return false
end

local function newName()
	for _ = 1, 50 do
		local name = pick(FIRST) .. " " .. pick(LAST)
		if not nameTaken(name) then
			return name
		end
	end
	nextID = nextID + 1
	return "Demo " .. pick(LAST) .. nextID
end

-- A made-up player listed for `role`: a class that can play it, sometimes a second role, and a
-- level around what that role needs (now and then too low, to show a refusal).
function Demo.NewPlayer(role)
	role = role or pick({ "TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER" })
	local class = pick(ns.ROLE_CLASSES[role])
	local roles = { [role] = true }
	if role ~= "DAMAGER" and chance(0.35) then
		roles.DAMAGER = true
	elseif role == "DAMAGER" then
		for _, other in ipairs({ "TANK", "HEALER" }) do
			if ns.CanPlay(class, other) and chance(0.2) then
				roles[other] = true
			end
		end
	end
	local base = ns.settings.roles[role] and ns.settings.roles[role].minLevel or 15
	local level = chance(0.2) and base - random(1, 4) or base + random(0, 8)
	nextID = nextID + 1
	return {
		id = "demo" .. nextID,
		name = newName(),
		class = class,
		level = ns.Clamp(level, 1, ns.MAX_LEVEL),
		roles = roles,
		listedAt = GetTime(),
		age = random(30, 900),
		area = pick(AREAS),
		comment = pick(COMMENTS),
	}
end

local function addListing(role)
	if #Demo.pool >= POOL_MAX then
		return nil
	end
	local entry = Demo.NewPlayer(role)
	Demo.pool[#Demo.pool + 1] = entry
	return entry
end

local function findListing(name)
	for index, entry in ipairs(Demo.pool) do
		if ns.SameName(entry.name, name) then
			return entry, index
		end
	end
	return nil
end

local function delist(entry)
	for index, other in ipairs(Demo.pool) do
		if other == entry then
			table.remove(Demo.pool, index)
			return
		end
	end
end

local function rosterIndex(unit)
	local index = type(unit) == "string" and tonumber(unit:match("^demo(%d+)$"))
	return index and Demo.roster[index] and index or nil
end

-- A fresh list for the dungeon picked: the levels follow its rules. Picking another dungeon
-- during the demo makes a new list.
function Demo.FillPool()
	wipe(Demo.pool)
	Demo.poolActivity = ns.settings.activityID
	if not Demo.poolActivity then
		return
	end
	for _, role in ipairs(ns.ROLES) do
		for _ = 1, POOL_START[role] do
			addListing(role)
		end
	end
	ns.Log(("Demo list for %s: %d made-up players"):format(ns.settings.activityName or "?", #Demo.pool))
end

-- Someone new lists themselves now and then, so the list keeps moving.
local function scheduleArrival()
	later(random(ARRIVAL_MIN, ARRIVAL_MAX), "arrival", function()
		local entry = ns.settings.activityID and Demo.poolActivity == ns.settings.activityID and addListing()
		if entry then
			ns.Log(("A made-up player listed: %s (%s %d)"):format(entry.name, ns.ClassName(entry.class), entry.level))
		end
		scheduleArrival()
	end)
end

-- The pretend game ---------------------------------------------------------------------------

local function system(format, name)
	ns.Dispatch("CHAT_MSG_SYSTEM", (format or "%s"):format(name))
end

local function answerInvite(entry)
	system(ERR_INVITE_PLAYER_S or "You have invited %s to join your group.", entry.name)
	local outcome = Demo.NextOutcome()
	if outcome == "joined" then
		later(random(3, 8), "join", function()
			delist(entry)
			system(ERR_JOINED_GROUP_S or "%s joins the party.", entry.name)
			-- The roster shows them a moment later, as in the game; marked DPS by default.
			later(1.5, "roster", function()
				Demo.roster[#Demo.roster + 1] = { name = entry.name, class = entry.class, role = "DAMAGER", listing = entry }
				ns.Dispatch("GROUP_ROSTER_UPDATE")
			end)
		end)
	elseif outcome == "declined" then
		later(random(2, 6), "decline", function()
			system(ERR_DECLINE_GROUP_S or "%s declines your group invitation.", entry.name)
		end)
	elseif outcome == "busy" then
		later(1, "busy", function()
			delist(entry)
			system(ERR_ALREADY_IN_GROUP_S or "%s is already in a group.", entry.name)
		end)
	else
		later(SLOW_DECLINE, "no answer", function()
			system(ERR_DECLINE_GROUP_S or "%s declines your group invitation.", entry.name)
		end)
	end
end

-- Each made-up member answers the role check: mostly the role they were invited for, sometimes
-- another role they listed.
local function answerRolePoll()
	ns.Log("Your own role check popup is not shown in the demo")
	for _, member in ipairs(Demo.roster) do
		later(random(2, 6), "role answer", function()
			local record = ns.Finder.MemberRecord(member.name)
			local picked = record and record.role or "DAMAGER"
			if chance(OTHER_ROLE_CHANCE) and member.listing then
				for _, role in ipairs(ns.ROLES) do
					if role ~= picked and member.listing.roles[role] then
						picked = role
						break
					end
				end
			end
			local old = member.role
			if picked ~= old then
				member.role = picked
				ns.Dispatch("ROLE_CHANGED_INFORM", member.name, member.name, old, picked)
			end
			ns.Dispatch("PLAYER_ROLES_ASSIGNED")
		end)
	end
end

local sim = {}

function sim.UnitName(unit)
	local index = rosterIndex(unit)
	if index then
		return Demo.roster[index].name
	end
	if type(unit) == "string" and (unit:match("^party") or unit:match("^raid")) then
		return nil -- your real group is not part of the demo
	end
	return Demo.real.UnitName(unit)
end

function sim.UnitClass(unit)
	local index = rosterIndex(unit)
	if index then
		return Demo.roster[index].class
	end
	return Demo.real.UnitClass(unit)
end

function sim.AssignedRole(unit)
	local index = rosterIndex(unit)
	return index and Demo.roster[index].role or nil
end

function sim.GroupUnits()
	local units = {}
	for index = 1, #Demo.roster do
		units[index] = "demo" .. index
	end
	return units
end

function sim.IsInGroup()
	return #Demo.roster > 0
end

function sim.IsLeader()
	return true
end

function sim.IsRaidAssistant()
	return false
end

function sim.HasSearch()
	return true
end

function sim.Search()
	later(0.8, "search results", function()
		ns.Dispatch("LFG_LIST_SEARCH_RESULTS_RECEIVED")
	end)
	return true
end

function sim.SearchResults()
	if ns.settings.activityID ~= Demo.poolActivity then
		Demo.FillPool()
	end
	local ids = {}
	for _, entry in ipairs(Demo.pool) do
		ids[#ids + 1] = entry.id
	end
	return ids
end

function sim.ResultInfo(resultID)
	for _, entry in ipairs(Demo.pool) do
		if entry.id == resultID then
			return {
				numMembers = 1,
				isDelisted = false,
				hasSelf = false,
				age = entry.age + math.floor(GetTime() - entry.listedAt),
				comment = entry.comment,
				activityIDs = { ns.settings.activityID },
				leaderName = entry.name,
			}
		end
	end
	return nil
end

function sim.ResultPlayer(resultID)
	for _, entry in ipairs(Demo.pool) do
		if entry.id == resultID then
			local roles = {}
			for role, flag in pairs(ns.ROLE_FLAG) do
				roles[flag] = entry.roles[role] == true
			end
			return { name = entry.name, classFilename = entry.class, level = entry.level, areaName = entry.area, lfgRoles = roles }
		end
	end
	return nil
end

function sim.Whisper()
	return true -- not sent
end

function sim.Invite(name)
	local entry = findListing(name)
	if entry then
		answerInvite(entry)
	else
		later(0.5, "not found", function()
			system(ERR_BAD_PLAYER_NAME_S or "Cannot find player '%s'.", name)
		end)
	end
	return true
end

function sim.HasRolePoll()
	return true
end

function sim.RolePoll()
	answerRolePoll()
	return true, true
end

Demo.sim = sim

-- Starting and ending -------------------------------------------------------------------------

-- What the demo puts aside, and gives back when it ends.
local function swapState()
	local Inviter, Finder = ns.Inviter, ns.Finder
	return {
		asked = ns.asked,
		memberRoles = ns.db.memberRoles,
		pending = Inviter.pending,
		joining = Inviter.joining,
		roleCheck = Inviter.roleCheck,
		invitesSent = Inviter.invitesSent,
		announcedComplete = Inviter.announcedComplete,
		finalCheckAsked = Inviter.finalCheckAsked,
		autoStoppedAt = Inviter.autoStoppedAt,
		hunting = Inviter.hunting,
		huntingText = Inviter.huntingText,
		lastMissingLogged = Inviter.lastMissingLogged,
		inviteAfterSearch = Inviter.inviteAfterSearch,
		candidates = Finder.candidates,
		stats = Finder.stats,
		skipped = Finder.skipped,
		searching = Finder.searching,
		searchNeedsClick = Finder.searchNeedsClick,
		silentFails = Finder.silentFails,
		pauseUntil = Finder.pauseUntil,
		lastSearchAt = Finder.lastSearchAt,
		lastResultsAt = Finder.lastResultsAt,
		searchFromClick = Finder.searchFromClick,
		status = ns.status,
	}
end

local function putState(saved)
	local Inviter, Finder = ns.Inviter, ns.Finder
	ns.asked = saved.asked
	ns.db.memberRoles = saved.memberRoles
	Inviter.pending = saved.pending
	Inviter.joining = saved.joining
	Inviter.roleCheck = saved.roleCheck
	Inviter.invitesSent = saved.invitesSent
	Inviter.announcedComplete = saved.announcedComplete
	Inviter.finalCheckAsked = saved.finalCheckAsked
	Inviter.autoStoppedAt = saved.autoStoppedAt
	Inviter.hunting = saved.hunting
	Inviter.huntingText = saved.huntingText
	Inviter.lastMissingLogged = saved.lastMissingLogged
	Inviter.inviteAfterSearch = saved.inviteAfterSearch
	Finder.candidates = saved.candidates
	Finder.stats = saved.stats
	Finder.skipped = saved.skipped
	Finder.searching = saved.searching
	Finder.searchNeedsClick = saved.searchNeedsClick
	Finder.silentFails = saved.silentFails
	Finder.pauseUntil = saved.pauseUntil
	Finder.lastSearchAt = saved.lastSearchAt
	Finder.lastResultsAt = saved.lastResultsAt
	Finder.searchFromClick = saved.searchFromClick
	ns.status = saved.status
end

function Demo.Start()
	if Demo.active then
		return false, "The demo is already running. /elfg demo ends it."
	end
	if ns.Inviter.PendingCount() > 0 then
		return false, ("Wait for %s's answer first."):format(ns.Inviter.PendingText())
	end
	if ns.Inviter.auto then
		ns.Inviter.Stop()
	end

	Demo.saved = swapState()
	Demo.real = {}
	for key, fn in pairs(ns.Game) do
		Demo.real[key] = fn
	end
	for key, fn in pairs(sim) do
		ns.Game[key] = fn
	end
	Demo.session = Demo.session + 1
	Demo.active = true

	-- A fresh pretend world: nobody asked, nobody in the group, a list ready to search.
	ns.asked = {}
	ns.db.memberRoles = {}
	ns.Inviter.pending = {}
	ns.Inviter.joining = {}
	ns.Inviter.roleCheck = { wanted = false, started = 0, answers = 0 }
	ns.Inviter.invitesSent = 0
	ns.Inviter.announcedComplete = false
	ns.Inviter.finalCheckAsked = false
	ns.Inviter.autoStoppedAt = nil
	ns.Inviter.hunting = {}
	ns.Inviter.huntingText = nil
	ns.Inviter.lastMissingLogged = nil
	ns.Inviter.inviteAfterSearch = false
	ns.Finder.candidates = {}
	ns.Finder.stats = {}
	ns.Finder.skipped = {}
	ns.Finder.searching = false
	ns.Finder.searchNeedsClick = false
	ns.Finder.silentFails = 0
	ns.Finder.pauseUntil = nil
	ns.Finder.lastSearchAt = nil
	ns.Finder.lastResultsAt = nil

	wipe(Demo.pool)
	wipe(Demo.roster)
	Demo.poolActivity = nil
	scheduleArrival()

	ns.Log("Demo started: made-up players; nothing is sent to the game")
	ns.Print("Demo started: made-up players, nothing is sent to the game. Close the demo window (or /elfg demo) to end it.")
	if ns.settings.activityID then
		Demo.FillPool()
		ns.Finder.Search()
		ns.SetStatus("Demo: made-up players, nothing is sent. Click + on a player, or Start auto.")
	else
		ns.SetStatus("Demo: pick a dungeon, and made-up players list themselves for it.")
	end
	return true, "Demo started."
end

function Demo.Stop()
	if not Demo.active then
		return false, "The demo is not running."
	end
	local invited, joined = ns.Inviter.invitesSent, #Demo.roster
	ns.Inviter.auto = false
	ns.Log(("Demo ended: %d invites, %d made-up players joined"):format(invited, joined))
	Demo.active = false
	Demo.session = Demo.session + 1
	for key, fn in pairs(Demo.real) do
		ns.Game[key] = fn
	end
	putState(Demo.saved)
	Demo.saved = nil
	wipe(Demo.pool)
	wipe(Demo.roster)
	ns.Print("Demo ended.")
	ns.Finder.Scan()
	ns.SetStatus("Demo ended.")
	-- Ended some other way (a logout): the demo window goes too.
	if ns.UI and ns.UI.IsDemoShown and ns.UI.IsDemoShown() then
		ns.UI.ToggleDemo()
	end
	return true, "Demo ended."
end

-- A logout or /reload during the demo must save your real data, not the demo's.
ns.On("PLAYER_LOGOUT", "demo logout", function()
	if Demo.active then
		Demo.Stop()
	end
end)

