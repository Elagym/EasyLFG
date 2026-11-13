-- EasyLFG: slash commands, key bindings, the button in Blizzard's Group Finder, and /elfg debug.

local _, ns = ...

local function say(message)
	if message then
		ns.Print(message)
	end
	ns.Refresh()
end

-- Key bindings (Bindings.xml) -------------------------------------------------------------------

BINDING_HEADER_EASYLFG = "EasyLFG"
BINDING_NAME_EASYLFG_TOGGLE = "Show or hide the window"
BINDING_NAME_EASYLFG_INVITE_NEXT = "Invite (one player per open role)"
BINDING_NAME_EASYLFG_SEARCH = "Search the Group Finder"

function EasyLFG_Toggle()
	ns.UI.Toggle()
end

function EasyLFG_InviteNext()
	local _, message = ns.Inviter.InviteNext(true)
	ns.SetStatus(message)
	if not ns.UI.IsShown() then
		ns.Print(message)
	end
end

function EasyLFG_Search()
	local _, message = ns.Finder.Search()
	ns.SetStatus(message)
	if not ns.UI.IsShown() then
		ns.Print(message)
	end
end

-- The button in Blizzard's Group Finder ---------------------------------------------------------

local lfgButton

local function addGroupFinderButton()
	if lfgButton or not LFGBrowseFrame then
		return
	end
	lfgButton = CreateFrame("Button", nil, LFGBrowseFrame, "UIPanelButtonTemplate")
	lfgButton:SetSize(90, 22)
	lfgButton:SetText("EasyLFG")
	if LFGBrowseFrame.SendMessageButton then
		lfgButton:SetPoint("LEFT", LFGBrowseFrame.SendMessageButton, "RIGHT", 6, 0)
	else
		lfgButton:SetPoint("BOTTOM", LFGBrowseFrame, "BOTTOM", 0, 79)
	end
	lfgButton:SetScript("OnClick", function()
		ns.UI.Toggle()
	end)
end

ns.On("ADDON_LOADED", "group finder button", function()
	addGroupFinderButton()
end)

-- Debug -------------------------------------------------------------------------------------------

local function yes(value)
	return value and "|cff60ff60yes|r" or "|cffff6060no|r"
end

local function ago(at)
	if not at then
		return "never"
	end
	return ("%d s ago"):format(math.floor(GetTime() - at))
end

local function printDebug()
	local Finder, Inviter = ns.Finder, ns.Inviter
	ns.Print(("v%s debug"):format(ns.VERSION))
	local lfg = C_LFGList or {}
	print(("  API: Search %s, GetSearchResults %s, PlayerInfo %s, LeaderInfo %s"):format(
		yes(lfg.Search), yes(lfg.GetSearchResults), yes(lfg.GetSearchResultPlayerInfo), yes(lfg.GetSearchResultLeaderInfo)))
	print(("  API: C_PartyInfo.InviteUnit %s, InviteUnit %s, C_ChatInfo.SendChatMessage %s, SendChatMessage %s, MenuUtil %s"):format(
		yes(C_PartyInfo and C_PartyInfo.InviteUnit), yes(InviteUnit), yes(C_ChatInfo and C_ChatInfo.SendChatMessage), yes(SendChatMessage), yes(MenuUtil)))
	local restricted = C_Secrets and C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions()
	print(("  Secret restrictions: %s"):format(tostring(restricted)))
	local groups = Finder.ListActivities()
	local count = 0
	for _, group in ipairs(groups) do
		count = count + #group.activities
	end
	print(("  Activities: %d in %d categories. Chosen: %s (id %s, category %s)"):format(
		count, #groups, tostring(ns.settings.activityName), tostring(ns.settings.activityID), tostring(ns.settings.categoryID)))
	local stats = Finder.stats or {}
	print(("  Searches: %d sent (last %s), %d result events (last %s), searching %s, error %s"):format(
		Finder.searchCount, ago(Finder.lastSearchAt), Finder.resultEvents, ago(Finder.lastResultsAt), tostring(Finder.searching), tostring(Finder.lastSearchError)))
	print(("  Automatic searches: %d sent, refused by the game %s, unanswered in a row %d, failed on the server %d"):format(
		Finder.autoSearches, yes(Finder.searchNeedsClick), Finder.silentFails, Finder.searchFailures))
	print(("  Watching the list %s; nobody listed for: %s"):format(yes(Inviter.Watching()), Inviter.huntingText or "-"))
	print(("  Last results: %d listings, %d groups, %d other dungeons, %d solo here (%d hidden), %d match"):format(
		stats.results or 0, stats.groups or 0, stats.otherActivity or 0, stats.solo or 0, stats.hidden or 0, stats.eligible or 0))
	local state = Finder.GroupState()
	local roles = ns.settings.roles
	print(("  Wanted: tank %s, healer %s, dps %s; I am %s"):format(
		tostring(roles.TANK.need), tostring(roles.HEALER.need), tostring(roles.DAMAGER.need), tostring(ns.settings.myRole)))
	print(("  Group: %d/5, tank %d, healer %d, dps %d, unknown roles %d, leader %s"):format(
		state.size, state.filled.TANK, state.filled.HEALER, state.filled.DAMAGER, state.unknownRoles, yes(Inviter.CanInvite())))
	for _, member in ipairs(state.members) do
		local unit
		for _, u in ipairs(Finder.GroupUnits()) do
			if ns.ReadUnitName(u) and member.name and ns.SameName(ns.ReadUnitName(u), member.name) then
				unit = u
			end
		end
		local record = Finder.MemberRecord(member.name)
		print(("    %s: %s (game says %s, picked %s, invited as %s)"):format(tostring(member.name), member.role,
			tostring(unit and Finder.AssignedRole(unit)),
			tostring(record and record.chosen), tostring(record and record.role)))
	end
	print(("  Invites sent: %d, auto %s, waiting: %d"):format(Inviter.invitesSent, tostring(Inviter.auto), Inviter.PendingCount()))
	for _, role in ipairs(ns.ROLES) do
		local p = Inviter.pending[role]
		if p then
			print(("    %s: %s, sent %s, server confirmed %s, whispered %s"):format(
				ns.ROLE_LABEL[role], p.name, ago(p.sentAt), tostring(p.confirmed), tostring(p.whispered)))
		end
	end
	local rc = Inviter.roleCheck
	print(("  Role checks: InitiateRolePoll %s, %d started (last %s, result %s), %d answers (last %s), wanted %s"):format(
		yes(InitiateRolePoll), rc.started, ago(rc.lastAt), tostring(rc.result), rc.answers, tostring(rc.lastAnswer), tostring(rc.wanted)))
	print(("  Role check popup: pre-selects %s, hook %s, refused by the game %s"):format(
		ns.ROLE_LABEL[ns.settings.myRole] or "?", yes(RolePollPopup_Show and hooksecurefunc), yes(Inviter.prefillBlocked)))
	for _, entry in ipairs(Inviter.AwaitingRoles()) do
		print(("    waiting for %s's role (invited as %s, joined %s, check started %s, %d s left)"):format(
			entry.name, ns.ROLE_LABEL[entry.role], ago(entry.joinedAt), ago(entry.checkAt),
			math.max(0, math.floor(entry.deadline - GetTime()))))
	end
	print(("  Last system message understood: %s"):format(tostring(Inviter.lastSystem)))
	print(("  Last invite error: %s; last whisper error: %s"):format(tostring(Inviter.lastInviteError), tostring(Inviter.lastWhisperError)))
	local blocked = {}
	for fn, times in pairs(ns.blocked) do
		blocked[#blocked + 1] = ("%s x%d"):format(fn, times)
	end
	print(("  Blocked by the game: %s"):format(#blocked > 0 and table.concat(blocked, ", ") or "nothing"))
	print(("  Last error: %s"):format(tostring(ns.lastError)))
	local log = ns.db.log
	for i = math.max(1, #log - 4), #log do
		print("  log " .. ns.LogLine(log[i]))
	end
end

-- Slash commands ----------------------------------------------------------------------------------

local function help()
	ns.Print("commands:")
	print("  /elfg - show or hide the window")
	print("  /elfg search - search the Group Finder for your dungeon")
	print("  /elfg invite - invite the next matching player (tank, then healer, then dps)")
	print("  /elfg start | stop - auto invite on or off")
	print("  /elfg rolecheck - ask the group to confirm their roles")
	print("  /elfg forget - forget who declined or did not answer")
	print("  /elfg log - show what EasyLFG did")
	print("  /elfg debug - what the game allows, and what happened")
	print("Key bindings: Options > Key Bindings > AddOns > EasyLFG.")
end

local function handle(input)
	local command = ns.Trim((input or ""):lower())
	if command == "" or command == "show" then
		ns.UI.Toggle()
	elseif command == "search" then
		local _, message = ns.Finder.Search()
		ns.SetStatus(message)
		ns.Print(message)
	elseif command == "next" or command == "invite" then
		local _, message = ns.Inviter.InviteNext(true)
		ns.SetStatus(message)
		ns.Print(message)
	elseif command == "start" or command == "auto" then
		local _, message = ns.Inviter.Start()
		ns.SetStatus(message)
		ns.Print(message)
	elseif command == "stop" then
		local _, message = ns.Inviter.Stop()
		ns.SetStatus(message)
		ns.Print(message)
	elseif command == "forget" or command == "reset" then
		wipe(ns.asked)
		ns.Log("Forgot every answer and skip (/elfg forget)")
		wipe(ns.Finder.skipped)
		ns.Finder.Evaluate()
		say("Forgot every answer and skip; everyone can be asked again.")
	elseif command == "rolecheck" or command == "roles" then
		local _, message = ns.Inviter.StartRoleCheck()
		ns.SetStatus(message)
		ns.Print(message)
	elseif command == "log" then
		ns.LogWindow.Toggle()
	elseif command == "debug" then
		printDebug()
	else
		help()
	end
end

SLASH_EASYLFG1 = "/elfg"
SLASH_EASYLFG2 = "/easylfg"
SlashCmdList.EASYLFG = ns.Guard("slash command", handle)

function ns.OnReady()
	addGroupFinderButton()
	if ns.repairedNeeds then
		ns.Print("Every role was set to 0 needed; the needs are back to 1 tank, 1 healer and 3 DPS.")
	end
end
