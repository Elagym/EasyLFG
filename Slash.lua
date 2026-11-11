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
BINDING_NAME_EASYLFG_INVITE_NEXT = "Invite the next player"
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
	print(("  Last results: %d listings, %d groups, %d other dungeons, %d solo here (%d hidden), %d match"):format(
		stats.results or 0, stats.groups or 0, stats.otherActivity or 0, stats.solo or 0, stats.hidden or 0, stats.eligible or 0))
	local state = Finder.GroupState()
	print(("  Group: %d/5, tank %d, healer %d, dps %d, unknown roles %d, leader %s"):format(
		state.size, state.filled.TANK, state.filled.HEALER, state.filled.DAMAGER, state.unknownRoles, yes(Inviter.CanInvite())))
	local p = Inviter.pending
	print(("  Invites sent: %d, auto %s, pending %s%s"):format(Inviter.invitesSent, tostring(Inviter.auto),
		p and p.name or "none", p and (" (" .. ago(p.sentAt) .. ", server confirmed " .. tostring(p.confirmed) .. ", whispered " .. tostring(p.whispered) .. ")") or ""))
	print(("  Last system message understood: %s"):format(tostring(Inviter.lastSystem)))
	print(("  Last invite error: %s; last whisper error: %s"):format(tostring(Inviter.lastInviteError), tostring(Inviter.lastWhisperError)))
	local blocked = {}
	for fn, times in pairs(ns.blocked) do
		blocked[#blocked + 1] = ("%s x%d"):format(fn, times)
	end
	print(("  Blocked by the game: %s"):format(#blocked > 0 and table.concat(blocked, ", ") or "nothing"))
	print(("  Last error: %s"):format(tostring(ns.lastError)))
	for i = 1, math.min(5, #Inviter.log) do
		print(("  log %s %s"):format(Inviter.log[i].at, Inviter.log[i].text))
	end
end

-- Slash commands ----------------------------------------------------------------------------------

local function help()
	ns.Print("commands:")
	print("  /elfg - show or hide the window")
	print("  /elfg search - search the Group Finder for your dungeon")
	print("  /elfg next - invite the next matching player")
	print("  /elfg start | stop - auto invite on or off")
	print("  /elfg forget - forget who declined or did not answer")
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
		wipe(ns.db.asked)
		wipe(ns.Finder.skipped)
		ns.Finder.Evaluate()
		say("Forgot every answer and skip; everyone can be asked again.")
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
end
