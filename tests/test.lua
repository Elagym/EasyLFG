-- EasyLFG scenario tests on a simulated client. From this folder: lua test.lua . ..
package.path = arg[1] .. "/?.lua;" .. package.path
local ADDON = arg[2]
local M = require("mock")
M.Install()

local passed, failed = 0, 0
local function out(s)
	io.write(tostring(s), string.char(10))
end
local function report(label, cond, extra)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		out("FAIL: " .. label .. (extra ~= nil and ("  [" .. tostring(extra) .. "]") or ""))
	end
end

-- Saved data from version 1, to check the upgrade.
EasyLFGDB = {
	settings = { message = "Hi, do you wanna join for <dungeon> ?", forgetMinutes = 30, timeout = 60 },
	asked = { ["old-guy"] = { outcome = "declined", time = os.time() } },
}

local ns = M.Load(ADDON)
local Finder, Inviter = ns.Finder, ns.Inviter

-- 1. Loading and upgrade -----------------------------------------------------------------------
M.Fire("ADDON_LOADED", "EasyLFG")
report("db version 3", EasyLFGDB.version == 3)
report("delay setting gone", ns.settings.delay == nil)
report("old default message upgraded", ns.settings.message == "Hi, do you wanna join for <dungeon> as <role> ?", ns.settings.message)
report("ask-again setting removed", ns.settings.forgetMinutes == nil)
report("saved answers dropped", EasyLFGDB.asked == nil)
report("timeout raised past the 60 s popup", ns.settings.timeout == 70, ns.settings.timeout)
ns.settings.timeout = 90
report("default needs 1/1/3", ns.settings.roles.TANK.need == 1 and ns.settings.roles.HEALER.need == 1 and ns.settings.roles.DAMAGER.need == 3)
report("slash registered", SlashCmdList.EASYLFG ~= nil and SLASH_EASYLFG1 == "/elfg")

-- 2. No dungeon: no search, no list, no invite ---------------------------------------------------------
local ok, msg = Finder.Search()
report("search refused without dungeon", not ok and msg:find("Pick a dungeon") and #M.searches == 0, msg)
M.AddListing({ name = "Early Bird", class = "WARRIOR", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("no list without dungeon", #Finder.candidates == 0)
ok, msg = Inviter.InviteRound(true)
report("no invite without dungeon", not ok and #M.invites == 0 and #M.searches == 0, msg)
M.ClearListings()

-- 3. Activities ----------------------------------------------------------------------------------------
local groups = Finder.ListActivities()
report("raids left out", #groups == 1 and #groups[1].activities == 3, #groups)
local deadmines
for _, a in ipairs(groups[1].activities) do if a.id == 801 then deadmines = a end end
Finder.SetActivity(deadmines)
report("activity saved", ns.settings.activityID == 801 and ns.settings.activityName == "Deadmines" and ns.settings.categoryID == 2)
report("min level follows dungeon", ns.settings.roles.TANK.minLevel == 17)
ok, msg = Finder.Search()
local s = M.searches[1]
report("search only for the chosen dungeon", ok and s[1] == 2 and #s[7] == 1 and s[7][1] == 801, msg)

-- 4. Results ----------------------------------------------------------------------------------------
M.AddListing({ name = "Garlick Naan", class = "PRIEST", level = 20, healer = true, dps = true, age = 50 })
M.AddListing({ name = "Fetto Vandike", class = "WARRIOR", level = 22, tank = true, age = 10 })
M.AddListing({ name = "Low Guy", class = "MAGE", level = 15, dps = true })
M.AddListing({ name = "Rogue One", class = "ROGUE", level = 25, dps = true, age = 5 })
M.AddListing({ name = "Rogue Two", class = "ROGUE", level = 24, dps = true, age = 500 })
M.AddListing({ name = "Group Lead", class = "PALADIN", level = 25, tank = true, members = 3 })
M.AddListing({ name = "Elsewhere Guy", class = "HUNTER", level = 25, dps = true, activities = { 802 } })
M.AddListing({ name = "Closed Hunter", class = "HUNTER", level = 25, dps = true, delisted = true })
M.AddListing({ name = "Norole Mage", class = "MAGE", level = 20 })
M.AddListing({ name = "Wrong Tank", class = "MAGE", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
local cands = Finder.candidates
local function find(name) for _, c in ipairs(Finder.candidates) do if c.name == name then return c end end end
report("only solo listings for this dungeon", #cands == 8 and not find("Elsewhere Guy") and not find("Group Lead"), #cands)
report("healer/dps fits both", find("Garlick Naan").fits.HEALER and find("Garlick Naan").fits.DAMAGER)
report("low level reason", find("Low Guy").reason:find("level 15"), find("Low Guy").reason)
report("class not wanted", find("Wrong Tank").reason == "Mage not wanted as Tank", find("Wrong Tank").reason)

-- 5. One invite at a time, tank first, with its whisper ---------------------------------------------
ok, msg = Inviter.InviteRound(true)
report("round ok", ok, msg)
report("one invite only", #M.invites == 1, #M.invites)
report("tank first", Inviter.pending.TANK and Inviter.pending.TANK.name == "Fetto Vandike" and M.invites[1] == "Fetto Vandike")
report("tank whisper says as tank", #M.whispers == 1 and M.whispers[1].target == "Fetto Vandike" and M.whispers[1].text == "Hi, do you wanna join for Deadmines as tank ?", M.whispers[1] and M.whispers[1].text)
local state = Finder.Evaluate()
report("waiting invite holds its seat", state.remaining.TANK == 0 and state.remaining.HEALER == 1 and state.remaining.DAMAGER == 2, state.remaining.DAMAGER)
report("other tanks wait", find("Wrong Tank").status == "nofit")

ok, msg = Inviter.InviteRound(true)
report("nothing more while an invite waits", not ok and #M.invites == 1 and msg:find("Waiting for Fetto Vandike's answer"), msg)
ok, msg = Inviter.InviteCandidate(find("Garlick Naan"), "HEALER")
report("hand invite refused while one waits", not ok and msg:find("Waiting for") and #M.invites == 1, msg)

M.Fire("CHAT_MSG_SYSTEM", "You have invited Fetto Vandike to join your group.")
report("server confirmation keeps waiting", Inviter.pending.TANK and Inviter.pending.TANK.confirmed)

-- 6. Tank declines, no other tank fits: the healer comes before any DPS -----------------------------------
M.Fire("CHAT_MSG_SYSTEM", "Fetto Vandike declines your group invitation.")
report("tank seat freed", Inviter.pending.TANK == nil and Inviter.PendingCount() == 0)
report("decline remembered", ns.asked["fetto-vandike"].outcome == "declined" and find("Fetto Vandike").status == "asked")
ok, msg = Inviter.InviteRound(true)
report("healer before dps", ok and #M.invites == 2 and Inviter.pending.HEALER and Inviter.pending.HEALER.name == "Garlick Naan" and Inviter.pending.DAMAGER == nil, msg)
report("healer whisper says as healer", M.whispers[2].target == "Garlick Naan" and M.whispers[2].text == "Hi, do you wanna join for Deadmines as healer ?", M.whispers[2].text)

-- 7. Healer joins; the game shows DPS until they answer the role check: never a second healer ----------
local polls = M.rolePolls
M.Fire("CHAT_MSG_SYSTEM", "Garlick Naan joins the party.")
report("healer joined", Inviter.pending.HEALER == nil and EasyLFGDB.memberRoles["garlick-naan"].role == "HEALER")
report("waiting for the healer's role", Inviter.Busy() == "rolecheck")
-- A default role before the role check is not their answer.
M.Fire("ROLE_CHANGED_INFORM", "Garlick Naan", "", "NONE", "DAMAGER")
report("early default role ignored", EasyLFGDB.memberRoles["garlick-naan"].chosen == nil and Finder.Evaluate().filled.HEALER == 1)
M.Join("Garlick", "Naan", "PRIEST", "DAMAGER") -- surname in the realm slot, DPS shown by default
M.Fire("GROUP_ROSTER_UPDATE")
report("role check once in the roster", M.rolePolls == polls + 1, M.rolePolls - polls)
state = Finder.Evaluate()
report("counted as healer, not the game's default dps", state.filled.HEALER == 1 and state.filled.DAMAGER == 1, state.filled.DAMAGER)
M.AddListing({ name = "Holy Paly", class = "PALADIN", level = 30, healer = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("second healer not wanted", find("Holy Paly").reason == "no Healer needed", find("Holy Paly").reason)
ok, msg = Inviter.InviteRound(true)
report("no invite before the role check answer", not ok and #M.invites == 2 and msg:find("confirm their role"), msg)
M.party[1].role = "HEALER"
M.Fire("ROLE_CHANGED_INFORM", "Garlick Naan", "Garlick Naan", "DAMAGER", "HEALER")
report("role check done", Inviter.Busy() == nil and EasyLFGDB.memberRoles["garlick-naan"].chosen == "HEALER")
ok, msg = Inviter.InviteRound(true)
report("then the best dps", ok and M.invites[3] == "Rogue One" and #M.invites == 3, msg)

-- 8. A DPS joins: no role check (everyone is DPS by default), the next invite may go out at once ---------
polls = M.rolePolls
M.Fire("CHAT_MSG_SYSTEM", "Rogue One joins the party.")
M.Join("Rogue", "One", "ROGUE", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
M.Advance(6)
report("dps joined with role", EasyLFGDB.memberRoles["rogue-one"].role == "DAMAGER" and Inviter.PendingCount() == 0)
report("no role check for a dps", M.rolePolls == polls and Inviter.Busy() == nil, M.rolePolls - polls)
ns.settings.distinctClasses = true
Finder.Evaluate()
report("distinct: second rogue refused", find("Rogue Two").reason:find("Rogue already"), find("Rogue Two").reason)
report("distinct: my class counts", find("Norole Mage").reason:find("Mage already"), find("Norole Mage").reason)
ns.settings.distinctClasses = false
ok, msg = Inviter.InviteRound(true)
report("next dps by level", ok and M.invites[4] == "Rogue Two", msg)

-- 9. Time limit ------------------------------------------------------------------------------------
M.Advance(89)
report("still waiting at 89 s", Inviter.pending.DAMAGER ~= nil)
M.Advance(2)
report("given up at 90 s", Inviter.pending.DAMAGER == nil and ns.asked["rogue-two"].outcome == "noanswer")

-- 10. Auto mode --------------------------------------------------------------------------------------
local searchesBefore = #M.searches
M.Advance(31)
ok, msg = Inviter.Start()
report("auto with old results searches first", ok and #M.searches == searchesBefore + 1 and #M.invites == 4, msg)
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("auto invites the round when results arrive", Inviter.auto and M.invites[5] == "Norole Mage", M.invites[5])
M.AddListing({ name = "Next Warlock", class = "WARLOCK", level = 21, dps = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("dps still waiting: no second dps", #M.invites == 5)
M.Fire("CHAT_MSG_SYSTEM", "Norole Mage is already in a group.")
report("busy: next dps invited right away", Inviter.pending.DAMAGER and Inviter.pending.DAMAGER.name == "Next Warlock" and #M.invites == 6, M.invites[6])
report("its whisper too", M.whispers[#M.whispers].target == "Next Warlock" and M.whispers[#M.whispers].text:find("as dps"))
M.Fire("CHAT_MSG_SYSTEM", "Next Warlock declines your group invitation.")
report("decline with nobody left: nothing sent", Inviter.pending.DAMAGER == nil and #M.invites == 6)
M.AddListing({ name = "Big Bear", class = "DRUID", level = 26, tank = true, dps = true })
M.AddListing({ name = "Fire Mage", class = "MAGE", level = 23, dps = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("new results: the tank first, alone", Inviter.pending.TANK and Inviter.pending.TANK.name == "Big Bear" and Inviter.pending.DAMAGER == nil, #M.invites)
report("one invite only", #M.invites == 7, #M.invites)
-- The join message comes before the roster: the seat stays taken, and nothing goes out before the
-- role check is answered.
M.AddListing({ name = "Extra Dps", class = "HUNTER", level = 40, dps = true })
M.Fire("CHAT_MSG_SYSTEM", "Big Bear joins the party.")
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED") -- auto mode tries here as well
state = Finder.Evaluate()
report("joiner's seat held before the roster", state.remaining.TANK == 0 and Inviter.pending.TANK == nil and #M.invites == 7, #M.invites)
report("a matching dps waits for the role check", find("Extra Dps").status == "match" and #M.invites == 7)
polls = M.rolePolls
M.Join("Big", "Bear", "DRUID", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("held seat released once in the roster", next(Inviter.joining) == nil)
report("role check for the bear", M.rolePolls == polls + 1 and #M.invites == 7)
-- The bear never answers: after 30 s EasyLFG counts them as the tank they were invited as.
M.Advance(29)
report("still waiting for the bear at 29 s", #M.invites == 7 and Inviter.Busy() == "rolecheck")
M.Advance(2)
report("wait over: auto invites the best dps", Inviter.pending.DAMAGER and Inviter.pending.DAMAGER.name == "Extra Dps" and #M.invites == 8, M.invites[8])
report("bear counted as tank", Finder.Evaluate().filled.TANK == 1)
polls = M.rolePolls
M.Fire("CHAT_MSG_SYSTEM", "Extra Dps joins the party.")
M.Join("Extra", "Dps", "HUNTER", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
M.Advance(6)
report("last dps joins: no role check", M.rolePolls == polls)
state = Finder.Evaluate()
report("group complete", state.complete and state.size == 5, state.size)
report("auto off when complete", Inviter.auto == false)
report("complete announced once", M.PrintsContain("Your group is complete") and (M.sound or 0) == 1)
ok, msg = Inviter.InviteRound(true)
report("no invite when complete", not ok and msg:find("complete"), msg)

-- 11. Distinct classes, one invite after the other ----------------------------------------------------
M.party = {}
M.Fire("GROUP_ROSTER_UPDATE")
wipe(ns.asked)
wipe(EasyLFGDB.memberRoles)
M.ClearListings()
M.AddListing({ name = "Pala Tank", class = "PALADIN", level = 30, tank = true })
M.AddListing({ name = "Pala Dps", class = "PALADIN", level = 40, dps = true })
M.AddListing({ name = "Hunter Dps", class = "HUNTER", level = 30, dps = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
ns.settings.distinctClasses = true
local before = #M.invites
Inviter.InviteRound(true)
report("tank invited", Inviter.pending.TANK and Inviter.pending.TANK.name == "Pala Tank" and #M.invites == before + 1)
report("distinct: waiting paladin counts", find("Pala Dps").reason:find("Paladin already"), find("Pala Dps").reason)
ns.settings.distinctClasses = false
-- A message without a name ends the single invite waiting.
M.Fire("CHAT_MSG_SYSTEM", "Your party is full.")
report("plain message ends the single invite", Inviter.PendingCount() == 0 and ns.asked["pala-tank"].outcome == "failed")

-- 12. Late accept warns about a role filled twice ---------------------------------------------------
ns.asked["late-tank"] = { name = "Late Tank", outcome = "noanswer", time = time(), role = "TANK" }
M.Join("Other", "Tank", "WARRIOR", "TANK")
M.Join("Late", "Tank", "WARRIOR", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("late joiner warning", M.PrintsContain("joined late as Tank"))
M.party = {}
M.Fire("GROUP_ROSTER_UPDATE")

-- 13. Answers last the session --------------------------------------------------------------------
wipe(ns.asked)
wipe(EasyLFGDB.memberRoles)
ns.asked["hunter-dps"] = { name = "Hunter Dps", outcome = "declined", time = time() - 7200 }
Finder.Evaluate()
report("declined is not asked again, even 2 h later", find("Hunter Dps").status == "asked")
SlashCmdList.EASYLFG("forget")
report("forget allows it again", find("Hunter Dps").status == "match")

-- 14. Template ------------------------------------------------------------------------------------
ns.settings.message = "Hey <name>, <role> for <Dungeon>? 100%"
ns.settings.activityName = "Gnome%Town"
local text = Inviter.FormatMessage({ name = "Fetto Vandike" }, "HEALER")
report("template", text == "Hey Fetto, healer for Gnome%Town? 100%", text)
ns.settings.message = "   "
report("blank template falls back", Inviter.FormatMessage({ name = "A" }, "TANK"):find("as tank"))
ns.settings.activityName = "Deadmines"
ns.settings.message = ns.DEFAULT_MESSAGE

-- 15. Leader, failures, blocked ---------------------------------------------------------------------
M.party = { { name = "Someone", realm = "Else", class = "PRIEST" } }
M.leader = false
ok, msg = Inviter.InviteRound(true)
report("not leader refused", not ok and msg:find("leader"), msg)
M.leader = true
M.party = {}
M.ClearListings()
M.AddListing({ name = "Fail Guy", class = "WARRIOR", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.inviteError = "boom"
ok, msg = Inviter.InviteRound(true)
report("invite error handled", not ok and msg:find("boom") and Inviter.PendingCount() == 0, msg)
M.inviteError = nil
Inviter.auto = true
M.Fire("ADDON_ACTION_BLOCKED", "EasyLFG", "C_PartyInfo.InviteUnit()")
report("blocked stops auto", Inviter.auto == false and ns.blocked["C_PartyInfo.InviteUnit()"] == 1)
M.Fire("ADDON_ACTION_BLOCKED", "OtherAddon", "Foo()")
report("other addon ignored", ns.blocked["Foo()"] == nil)

-- 16. Secret values ---------------------------------------------------------------------------------
M.ClearListings()
M.AddListing({ name = "Secret Sam", class = "WARRIOR", level = 30, tank = true })
M.secret["Secret Sam"] = true
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("secret listing hidden", Finder.candidates[1].status == "hidden" and Finder.stats.hidden == 1)
M.secret["Secret Sam"] = nil

-- 17. Empty list: a click searches, a timer never does -----------------------------------------------
M.ClearListings()
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.Advance(20)
local searches = #M.searches
ok, msg = Inviter.InviteRound(true)
report("empty list click searches", ok and #M.searches == searches + 1 and Inviter.inviteAfterSearch, msg)
M.AddListing({ name = "Tardy Tank", class = "PALADIN", level = 30, tank = true })
before = #M.invites
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("invite after search", #M.invites == before + 1 and M.invites[#M.invites] == "Tardy Tank")
M.Fire("CHAT_MSG_SYSTEM", "Cannot find player 'Tardy Tank'.")
report("not found resolves", Inviter.PendingCount() == 0 and ns.asked["tardy-tank"].outcome == "notfound")
M.Advance(20)
searches = #M.searches
ok = Inviter.InviteRound(false)
report("timer never searches", not ok and #M.searches == searches)

-- 18. Patterns and names --------------------------------------------------------------------------------
report("pattern escapes", ("Cannot find player 'Bob Smith'."):match(Inviter.ToPattern(ERR_BAD_PLAYER_NAME_S)) == "Bob Smith")
report("pattern %1$s", ("Ann joins."):match(Inviter.ToPattern("%1$s joins.")) == "Ann")
report("strip link", ns.StripCodes("|Hplayer:Bob-Smith|h[Bob Smith]|h declines") == "Bob Smith declines")
report("same name space/dash", ns.SameName("Garlick Naan", "Garlick-Naan"))
report("loose first name", ns.SameName("Garlick", "Garlick Naan"))
report("different surname", not ns.SameName("Garlick Naan", "Garlick Other"))

-- 19. UI --------------------------------------------------------------------------------------------
local uiOk, uiErr = pcall(ns.UI.Show)
report("window builds", uiOk, uiErr)
report("no error recorded", ns.lastError == nil, ns.lastError)
local function findFrame(test)
	for _, f in ipairs(M.frames) do
		if test(f) then return f end
	end
end
local searchButton = findFrame(function(f) return f.kind == "Button" and f.text == "Search" end)
local autoButton = findFrame(function(f) return f.kind == "Button" and f.text == "Start auto" end)
report("search and auto buttons found", searchButton and autoButton)
report("no Invite button any more", not findFrame(function(f) return f.kind == "Button" and f.text == "Invite" end))
report("no ask-again box", not findFrame(function(f) return f.text == "Ask again after (min)" end))
local saved = ns.settings.activityID
ns.settings.activityID = nil
ns.UI.Refresh()
report("buttons off without dungeon", searchButton.enabled == false and autoButton.enabled == false)
ns.settings.activityID = saved
ns.UI.Refresh()
report("search button on with dungeon", searchButton.enabled == true)
local timeoutBox = findFrame(function(f) return f.kind == "EditBox" and rawget(f, "load") and f.text == "90" end)
report("timeout box", timeoutBox ~= nil)
if timeoutBox then
	timeoutBox.text = "30"
	timeoutBox:ClearFocus()
	report("timeout box clamps to 70", ns.settings.timeout == 70, ns.settings.timeout)
	timeoutBox.text = "90"
	timeoutBox:ClearFocus()
end
-- Class menu
local classButton = findFrame(function(f) return f.scripts.OnClick and f.text == "Any tank class" end)
report("tank classes summed up", classButton ~= nil)
classButton.scripts.OnClick(classButton)
local warrior
local tankChecks = {}
for _, item in ipairs(M.menu.items) do
	if item.kind == "check" then tankChecks[#tankChecks + 1] = item.data end
	if item.kind == "check" and item.data == "WARRIOR" then warrior = item end
end
report("tank menu: only warrior, paladin, druid", table.concat(tankChecks, ",") == "WARRIOR,PALADIN,DRUID", table.concat(tankChecks, ","))
report("class menu toggles", warrior and warrior.b(warrior.data) == 2 and ns.settings.roles.TANK.classes.WARRIOR == false)
ns.UI.Refresh()
report("summary names the classes left", classButton.text:find("Paladin") and classButton.text:find("Druid") and not classButton.text:find("Warrior"), classButton.text)
ns.InitDB()
report("unticked survives reload", ns.settings.roles.TANK.classes.WARRIOR == false)
local allTank
for _, item in ipairs(M.menu.items) do if item.text == "All tank classes" then allTank = item end end
allTank.a()
report("all tank classes: only those three", ns.settings.roles.TANK.classes.WARRIOR and not ns.settings.roles.TANK.classes.HUNTER and not ns.settings.roles.TANK.classes.MAGE)
local healerButton = findFrame(function(f) return f.scripts.OnClick and f.text == "Any healer class" end)
healerButton.scripts.OnClick(healerButton)
local healChecks = {}
for _, item in ipairs(M.menu.items) do if item.kind == "check" then healChecks[#healChecks + 1] = item.data end end
report("healer menu: paladin, priest, shaman, druid", table.concat(healChecks, ",") == "PALADIN,PRIEST,SHAMAN,DRUID", table.concat(healChecks, ","))
local dpsButton = findFrame(function(f) return f.scripts.OnClick and f.text == "Any class" end)
dpsButton.scripts.OnClick(dpsButton)
local dpsCount = 0
for _, item in ipairs(M.menu.items) do if item.kind == "check" then dpsCount = dpsCount + 1 end end
report("dps menu: all nine classes", dpsCount == 9, dpsCount)
-- An impossible class in old saved settings is cleared.
ns.settings.roles.TANK.classes.HUNTER = true
ns.settings.roles.HEALER.classes.ROGUE = true
ns.InitDB()
report("saved hunter tank cleared", ns.settings.roles.TANK.classes.HUNTER == false and ns.settings.roles.HEALER.classes.ROGUE == false)
report("can-play table", ns.CanPlay("DRUID", "TANK") and not ns.CanPlay("HUNTER", "TANK") and ns.CanPlay("SHAMAN", "HEALER") and not ns.CanPlay("WARRIOR", "HEALER") and ns.CanPlay("HUNTER", "DAMAGER"))
-- Row menu
M.ClearListings()
M.AddListing({ name = "Menu Man", class = "WARLOCK", level = 40, dps = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
ns.UI.Refresh()
local row = findFrame(function(f) return rawget(f, "candidate") and f.candidate.name == "Menu Man" end)
report("row drawn", row ~= nil)
row.scripts.OnClick(row)
local inviteItem, skipItem
for _, item in ipairs(M.menu.items) do
	if item.text == "Invite as DPS" then inviteItem = item end
	if item.text == "Skip this player" then skipItem = item end
end
report("row menu names the role", inviteItem ~= nil)
skipItem.a()
report("skip works", Finder.candidates[1].status == "skipped")
row.scripts.OnEnter(row)
inviteItem.a()
report("hand invite as dps", Inviter.pending.DAMAGER and Inviter.pending.DAMAGER.name == "Menu Man")
ns.UI.RefreshStatus()
local statusLabel = findFrame(function(f) return type(f.text) == "string" and f.text:find("^Waiting for") end)
report("status shows the waiting invite", statusLabel and statusLabel.text:find("Menu Man"), statusLabel and statusLabel.text)
SlashCmdList.EASYLFG("debug")
report("debug prints", M.PrintsContain("DPS: Menu Man"))
SlashCmdList.EASYLFG("help")
report("no errors at the end", ns.lastError == nil, ns.lastError)

-- 20. Group Finder button -----------------------------------------------------------------------------
LFGBrowseFrame = M.NewFrame("Frame")
LFGBrowseFrame.SendMessageButton = M.NewFrame("Button")
M.Fire("ADDON_LOADED", "Blizzard_GroupFinder_VanillaStyle")
report("group finder button", findFrame(function(f) return f.kind == "Button" and f.text == "EasyLFG" end) ~= nil)

-- 21. The list refreshes after invites, and every 10 s in auto mode -----------------------------------
Inviter.Stop()
-- Earlier scenarios never answered their automatic searches, so EasyLFG already fell back to clicks.
report("earlier unanswered searches made it fall back", Finder.searchNeedsClick == true)
Finder.searchNeedsClick = false
Finder.silentFails = 0
Finder.autoSearches = 0
wipe(Inviter.pending)
wipe(Inviter.joining)
wipe(Inviter.awaiting)
wipe(ns.asked)
M.party = {}
M.ClearListings()
M.AddListing({ name = "Fresh Tank", class = "WARRIOR", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
Finder.searching = false
M.Advance(30)
searches = #M.searches
ok = Inviter.InviteRound(true)
report("click round invites", ok and Inviter.pending.TANK and Inviter.pending.TANK.name == "Fresh Tank")
report("click round refreshes the list at once", #M.searches == searches + 1 and Finder.searchFromClick == true, #M.searches - searches)
report("refresh is for the chosen dungeon only", M.searches[#M.searches][7][1] == ns.settings.activityID and #M.searches[#M.searches][7] == 1)
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.Fire("CHAT_MSG_SYSTEM", "Fresh Tank declines your group invitation.")

-- Auto mode: every role is open with nobody to invite, so it refreshes every 10 s.
ok = Inviter.Start()
searches = #M.searches
M.Advance(10)
report("auto refresh after 10 s", #M.searches == searches + 1 and Finder.searchFromClick == false and Finder.autoSearches == 1, #M.searches - searches)
M.AddListing({ name = "Fresh Priest", class = "PRIEST", level = 30, healer = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("auto results invite the healer", Inviter.pending.HEALER and Inviter.pending.HEALER.name == "Fresh Priest")
report("automatic searches work: no failures counted", Finder.silentFails == 0 and not Finder.searchNeedsClick)
report("refresh after those invites waits for the 5 s gap", #M.searches == searches + 1)
M.Advance(5)
report("gap passed: refreshed", #M.searches == searches + 2, #M.searches - searches)

-- The game silently ignores automatic searches: after two without an answer, a click is needed.
M.Advance(11) -- the search above gets no answer
report("one unanswered search counted", Finder.silentFails == 1 and not Finder.searchNeedsClick, Finder.silentFails)
M.Advance(10) -- the ticker searches again, and that one is not answered either
M.Advance(11)
report("two unanswered: falls back to clicks", Finder.searchNeedsClick == true)
report("you are told to press Search", M.PrintsContain("only allows a Group Finder search from a click"))
searches = #M.searches
M.Advance(30)
report("no more automatic searches", #M.searches == searches)
report("auto invites keep running", Inviter.auto == true)
ok = Finder.Search()
report("a click still searches", ok and #M.searches == searches + 1)
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")

-- A blocked automatic search is noticed at once.
Finder.searchNeedsClick = false
Finder.silentFails = 0
M.Fire("ADDON_ACTION_BLOCKED", "EasyLFG", "C_LFGList.Search()")
report("blocked search: falls back to clicks", Finder.searchNeedsClick == true and Inviter.auto == true)

-- Stopping auto mode stops the refreshes.
Finder.searchNeedsClick = false
Inviter.Stop()
searches = #M.searches
M.Advance(60)
report("no refresh after stop", #M.searches == searches)
report("no errors after refresh tests", ns.lastError == nil, ns.lastError)

-- 22. Role checks ------------------------------------------------------------------------------------
Inviter.Stop()
wipe(Inviter.pending)
wipe(Inviter.joining)
wipe(Inviter.awaiting)
wipe(ns.asked)
wipe(EasyLFGDB.memberRoles)
M.party = {}
M.ClearListings()
Finder.searchNeedsClick = true -- keeps automatic searches out of the way here
ns.settings.myRole = "DAMAGER"
ns.settings.roles.DAMAGER.need = 1 -- a group of three: tank, healer, me
M.AddListing({ name = "Bear Tank", class = "DRUID", level = 30, tank = true, healer = true })
M.AddListing({ name = "Holy Priest", class = "PRIEST", level = 30, healer = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
ok, msg = Inviter.Start()
report("tank invited, healer waits its turn", Inviter.pending.TANK and Inviter.pending.TANK.name == "Bear Tank" and Inviter.pending.HEALER == nil, msg)
polls = M.rolePolls
M.Fire("CHAT_MSG_SYSTEM", "Bear Tank joins the party.")
report("no role check before the roster shows the tank", M.rolePolls == polls)
report("no healer invite before the tank's role check", Inviter.pending.HEALER == nil)
M.Join("Bear", "Tank", "DRUID", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("role check once the tank is in the roster", M.rolePolls == polls + 1, M.rolePolls - polls)

-- The druid picks healer: the tank seat opens again and auto mode fills it, tank first.
M.AddListing({ name = "Spare Tank", class = "WARRIOR", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("tank seat still taken before the answer", Inviter.PendingCount() == 0 and find("Spare Tank").status == "nofit")
M.party[1].role = "HEALER"
M.Fire("ROLE_CHANGED_INFORM", "Bear Tank", "Bear Tank", "NONE", "HEALER")
report("answer stored", EasyLFGDB.memberRoles["bear-tank"].chosen == "HEALER")
report("you are told the seat reopened", M.PrintsContain("Bear Tank picked Healer in the role check (invited as Tank)"))
report("new tank invited right away", Inviter.pending.TANK and Inviter.pending.TANK.name == "Spare Tank" and Inviter.pending.HEALER == nil)
state = Finder.Evaluate()
report("answer counts over the invited role", state.filled.HEALER == 1 and state.filled.TANK == 1 and state.complete, state.filled.TANK)
report("the priest is no longer needed", find("Holy Priest").reason == "group complete", find("Holy Priest").reason)

-- Group complete, then a role check reopens a seat: auto mode comes back.
M.Fire("CHAT_MSG_SYSTEM", "Spare Tank joins the party.")
M.Join("Spare", "Tank", "WARRIOR", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("not complete before the spare tank's role check", Inviter.auto == true and Inviter.Busy() == "rolecheck")
local pollsBefore = M.rolePolls
M.Advance(6)
report("role check for the new tank too", M.rolePolls > pollsBefore)
M.party[2].role = "TANK"
M.Fire("ROLE_CHANGED_INFORM", "Spare Tank", "Spare Tank", "NONE", "TANK")
state = Finder.Evaluate()
report("complete with the spare tank", state.complete and Inviter.auto == false)
M.AddListing({ name = "Last Tank", class = "PALADIN", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.party[2].role = "DAMAGER"
M.Fire("ROLE_CHANGED_INFORM", "Spare Tank", "Spare Tank", "TANK", "DAMAGER")
report("too many dps flagged", M.PrintsContain("You now have 2 DPS for 1 wanted"))
report("auto mode back on", Inviter.auto == true and M.PrintsContain("auto invite is back on"))
report("seat filled again", Inviter.pending.TANK and Inviter.pending.TANK.name == "Last Tank")

-- Stopped by you: a role check never turns auto mode back on.
Inviter.Stop()
wipe(Inviter.pending)
M.party[2].role = "TANK"
M.Fire("ROLE_CHANGED_INFORM", "Spare Tank", "Spare Tank", "DAMAGER", "TANK")
M.party[2].role = "DAMAGER"
M.Fire("ROLE_CHANGED_INFORM", "Spare Tank", "Spare Tank", "TANK", "DAMAGER")
report("stopped stays stopped", Inviter.auto == false and Inviter.pending.TANK == nil)

-- Your own answer updates "I am".
M.myAssigned = "HEALER"
Finder.Evaluate()
report("my role from the role check", ns.settings.myRole == "HEALER")
M.myAssigned = nil
ns.settings.myRole = "DAMAGER"

-- By hand, and not when alone.
M.party = {}
SlashCmdList.EASYLFG("rolecheck")
report("no role check alone", M.PrintsContain("You are not in a group"))
M.Join("Some", "One", "MAGE", "NONE")
polls = M.rolePolls
SlashCmdList.EASYLFG("rolecheck")
report("role check by hand", M.rolePolls == polls + 1)
SlashCmdList.EASYLFG("debug")
report("debug shows role checks", M.PrintsContain("Role checks: InitiateRolePoll"))
report("no errors after role checks", ns.lastError == nil, ns.lastError)
ns.settings.roles.DAMAGER.need = 3

-- 23. Group status in the window -----------------------------------------------------------------------
-- An emptied Needed box keeps its value instead of saving 0.
ns.settings.roles.DAMAGER.need = 4
ns.UI.Refresh()
local dpsBox = findFrame(function(f) return f.kind == "EditBox" and rawget(f, "load") and f.text == "4" end)
report("dps needed box found", dpsBox ~= nil)
dpsBox.text = ""
dpsBox:ClearFocus()
report("emptied box keeps its value", ns.settings.roles.DAMAGER.need == 4 and dpsBox.text == "4", ns.settings.roles.DAMAGER.need)
dpsBox.text = "2"
dpsBox:ClearFocus()
report("typed number saved", ns.settings.roles.DAMAGER.need == 2)
ns.settings.roles.DAMAGER.need = 3

-- Saved needs of 0/0/0 are repaired on load.
for _, role in ipairs(ns.ROLES) do EasyLFGDB.settings.roles[role].need = 0 end
ns.repairedNeeds = nil
ns.InitDB()
report("all-zero needs repaired", ns.settings.roles.TANK.need == 1 and ns.settings.roles.HEALER.need == 1 and ns.settings.roles.DAMAGER.need == 3 and ns.repairedNeeds)
ns.settings.roles.TANK.need = 0
ns.repairedNeeds = nil
ns.InitDB()
report("a single 0 is a choice and stays", ns.settings.roles.TANK.need == 0 and not ns.repairedNeeds)
ns.settings.roles.TANK.need = 1

-- Opening the window reads the group and its roles.
Inviter.Stop()
wipe(Inviter.pending)
wipe(Inviter.joining)
wipe(Inviter.awaiting)
wipe(EasyLFGDB.memberRoles)
M.party = {}
M.Join("Tank", "Guy", "WARRIOR", "TANK") -- picked tank in a role check
M.Join("Heal", "Gal", "PRIEST", "NONE") -- invited as healer by EasyLFG
M.Join("Who", "Knows", "ROGUE", "NONE") -- nobody knows
EasyLFGDB.memberRoles["heal-gal"] = { name = "Heal Gal", role = "HEALER", time = time() }
ns.settings.myRole = "DAMAGER"
local groupLabel = findFrame(function(f) return type(f.text) == "string" and f.text:find("%d/%d") end)
EasyLFGFrame:Hide()
polls = M.rolePolls
M.Advance(10)
EasyLFGFrame:Show()
groupLabel = findFrame(function(f) return type(f.text) == "string" and f.text:find("1/1") and f.text:find("2/3") end)
report("window shows the group: tank 1/1, healer 1/1, dps 2/3", groupLabel ~= nil, groupLabel and groupLabel.text)
report("unknown role shown", groupLabel and groupLabel.text:find("1 unknown"))
report("opening the window starts no role check", M.rolePolls == polls, M.rolePolls - polls)
M.Join("New", "Face", "MAGE", "NONE")
EasyLFGFrame:Hide()
M.Advance(10)
EasyLFGFrame:Show()
report("overfilled dps shown", findFrame(function(f) return type(f.text) == "string" and f.text:find("3/3") end) ~= nil)
M.party[3].role = "DAMAGER"
M.party[4].role = "DAMAGER"
ns.settings.roles.DAMAGER.need = 2
ns.UI.Refresh()
report("more than wanted is red", findFrame(function(f) return type(f.text) == "string" and f.text:find("ff6060" .. "3/2") end) ~= nil)
ns.settings.roles.DAMAGER.need = 3
report("no errors after window tests", ns.lastError == nil, ns.lastError)

-- 24. The log -------------------------------------------------------------------------------------------
local function logHas(text)
	for _, entry in ipairs(EasyLFGDB.log) do
		if entry.text:find(text, 1, true) then return true end
	end
	return false
end
local function logShow()
	local lines = {}
	for i = math.max(1, #EasyLFGDB.log - 6), #EasyLFGDB.log do lines[#lines + 1] = EasyLFGDB.log[i].text end
	return table.concat(lines, " | ")
end
report("log: session start", logHas("=== Session start"))
report("log: dungeon set", logHas("Dungeon set: Deadmines (activity 801)"))
report("log: rules", logHas("Rules for Deadmines: Tank 1 (17+, Warrior/Paladin/Druid)"))
report("log: invite with whisper text", logHas('Invited Fetto Vandike (Warrior 22) as Tank (round); whispered "Hi, do you wanna join for Deadmines as tank ?"'))
report("log: decline with timing", logHas("Fetto Vandike (Tank): declined after"))
report("log: join", logHas("Garlick Naan (Healer): joined after"))
report("log: no answer", logHas("Rogue Two (DPS): no answer after 90 s"))
report("log: busy", logHas("Norole Mage (DPS): already in a group"))
report("log: nobody matches", logHas("No match for Tank"))
report("log: click refresh", logHas("List refreshed (your click)"))
report("log: automatic refresh", logHas("List refreshed (automatic)"))
report("log: refresh by Blizzard's window", logHas("List refreshed (Blizzard's window or another addon)"))
report("log: search without answer", logHas("got no answer within 10 s"))
report("log: automatic searches refused", logHas("Automatic searches refused"))
report("log: blocked", logHas("The game blocked C_LFGList.Search()"))
report("log: invite failure", logHas("Invite to Fail Guy as Tank FAILED"))
report("log: auto on/off", logHas("Auto invite ON") and logHas("Auto invite OFF (stopped)") and logHas("Auto invite OFF (group complete)"))
report("log: group complete with members", logHas("Group complete (5 players): you DPS") and logHas("Healer Bear Tank"))
report("log: role check started", logHas("Role check started (Garlick Naan joined as Healer)"))
report("log: early default role", logHas("Garlick Naan was set to DPS before the role check; still counted as Healer until they answer"))
report("log: role check done", logHas("Role check done for Garlick Naan: Healer (invited as Healer"))
report("log: role check timed out", logHas("Role check timed out: no role check answer from Big Bear after 30 s; counted as Tank"), logShow())
report("log: role check by hand", logHas("Role check started (by hand)"))
report("log: role answer differs", logHas("Role check: Bear Tank picked Healer but was invited as Tank; the Tank seat is open again"))
report("log: too many", logHas("Too many DPS: 2 for 1 wanted"))
report("log: auto back on", logHas("Auto invite ON again (a role check reopened a seat)"))
report("log: skip by hand", logHas("Skipped Menu Man by hand"))
report("log: forget", logHas("Forgot every answer and skip"))
local colored = false
for _, entry in ipairs(EasyLFGDB.log) do if entry.text:find("|c", 1, true) then colored = true end end
report("log: plain text, no colour codes", not colored)

-- Repeats are counted, errors logged, the size capped.
local before = #EasyLFGDB.log
ns.Log("Same thing")
ns.Log("Same thing")
ns.Log("Same thing")
report("log: repeats counted", #EasyLFGDB.log == before + 1 and EasyLFGDB.log[#EasyLFGDB.log].count == 3, logShow())
report("log line shows the count", ns.LogLine(EasyLFGDB.log[#EasyLFGDB.log]):find("(x3, last", 1, true))
ns.Guard("test handler", function() error("kaboom") end)()
report("log: errors", logHas("Error in test handler") and logHas("kaboom"))
ns.lastError = nil
for i = 1, 600 do ns.Log("filler " .. i) end
report("log: capped at 500", #EasyLFGDB.log == 500 and EasyLFGDB.log[500].text == "filler 600")

-- The window.
local logButton = findFrame(function(f) return f.kind == "Button" and f.text == "Log" end)
report("Log button in the main window", logButton ~= nil)
logButton.scripts.OnClick(logButton)
report("log window opens", ns.LogWindow.IsShown())
report("log window shows the lines", ns.LogWindow.Text():find("filler 600", 1, true) ~= nil)
local logEdit = findFrame(function(f) return f.kind == "EditBox" and type(f.text) == "string" and f.text:find("filler 600", 1, true) end)
report("log text box found", logEdit ~= nil)
logEdit.text = "typed over"
logEdit.scripts.OnTextChanged(logEdit, true)
report("log is read only", logEdit.text:find("filler 600", 1, true) ~= nil)
ns.Log("A new line")
M.Advance(1)
report("open window follows new lines", ns.LogWindow.Text():find("A new line", 1, true) ~= nil)
local clearButton = findFrame(function(f) return f.kind == "Button" and f.text == "Clear" end)
clearButton.scripts.OnClick(clearButton)
report("clear empties the log", #EasyLFGDB.log == 1 and EasyLFGDB.log[1].text == "Log cleared")
SlashCmdList.EASYLFG("log")
report("/elfg log toggles", not ns.LogWindow.IsShown())
report("no errors after log tests", ns.lastError == nil, ns.lastError)

-- 25. The + button on each row ---------------------------------------------------------------------------
Inviter.Stop()
wipe(Inviter.pending)
wipe(Inviter.joining)
wipe(Inviter.awaiting)
wipe(ns.asked)
wipe(EasyLFGDB.memberRoles)
wipe(Finder.skipped)
M.party = {}
M.leader = true
ns.settings.myRole = "DAMAGER"
ns.settings.roles.TANK.need, ns.settings.roles.HEALER.need, ns.settings.roles.DAMAGER.need = 1, 1, 3
ns.settings.distinctClasses = false
Finder.searchNeedsClick = false
Finder.searching = false
M.ClearListings()
M.AddListing({ name = "Plus Tank", class = "WARRIOR", level = 30, tank = true })
M.AddListing({ name = "Other Tank", class = "PALADIN", level = 31, tank = true })
M.AddListing({ name = "Plus Dps", class = "ROGUE", level = 30, dps = true })
M.AddListing({ name = "Low Dps", class = "MAGE", level = 5, dps = true })
M.AddListing({ name = "Flex Druid", class = "DRUID", level = 32, tank = true, dps = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
EasyLFGFrame:Show()
ns.UI.Refresh()
local function rowOf(name)
	return findFrame(function(f) return rawget(f, "candidate") and f.candidate.name == name and f.shown end)
end
local plusTankRow, lowRow = rowOf("Plus Tank"), rowOf("Low Dps")
report("rows have a + button", plusTankRow and plusTankRow.invite ~= nil)
report("+ on for a matching player", plusTankRow.invite.enabled == true and plusTankRow.invite.role == "TANK")
report("+ off for a player outside the rules", lowRow.invite.enabled == false and lowRow.invite.why:find("level 5") and lowRow.invite.why:find("invite anyway"), lowRow.invite.why)
report("disabled + is dimmed", lowRow.invite.alpha < 1)
plusTankRow.invite.scripts.OnEnter(plusTankRow.invite)
report("+ tooltip without errors", ns.lastError == nil, ns.lastError)

M.Advance(20)
searches = #M.searches
local whispersBefore = #M.whispers
plusTankRow.invite.scripts.OnClick(plusTankRow.invite)
report("+ invites the player", Inviter.pending.TANK and Inviter.pending.TANK.name == "Plus Tank")
report("+ sends the whisper with the role", #M.whispers == whispersBefore + 1 and M.whispers[#M.whispers].target == "Plus Tank" and M.whispers[#M.whispers].text:find("as tank"))
report("+ refreshes the list", #M.searches == searches + 1 and Finder.searchFromClick == true)
report("+ logged as by hand", logHas("Invited Plus Tank (Warrior 30) as Tank (by hand)"))
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
ns.UI.Refresh()
report("other tanks: + off once a tank is invited", rowOf("Other Tank").invite.enabled == false and rowOf("Other Tank").invite.why:find("no Tank needed"), rowOf("Other Tank").invite.why)
report("invited player: + off", rowOf("Plus Tank").invite.enabled == false and rowOf("Plus Tank").invite.why:find("waiting"))
local plusDpsRow = rowOf("Plus Dps")
report("one invite at a time: dps + off", plusDpsRow.invite.enabled == false and plusDpsRow.invite.why:find("Waiting for Plus Tank's answer") and plusDpsRow.invite.why:find("One invite at a time"), plusDpsRow.invite.why)
report("flexible player + off too", rowOf("Flex Druid").invite.enabled == false)
plusDpsRow.invite.scripts.OnClick(plusDpsRow.invite)
report("clicking a disabled + sends nothing", Inviter.PendingCount() == 1 and Inviter.pending.TANK.name == "Plus Tank")
M.Fire("CHAT_MSG_SYSTEM", "Plus Tank declines your group invitation.")
ns.UI.Refresh()
report("answer back: dps + on again", rowOf("Plus Dps").invite.enabled == true)
local flexRow = rowOf("Flex Druid")
report("flexible player offered as tank first", flexRow.invite.enabled == true and flexRow.invite.role == "TANK", flexRow.invite.role)
flexRow.invite.scripts.OnClick(flexRow.invite)
report("flexible player invited as tank", Inviter.pending.TANK and Inviter.pending.TANK.name == "Flex Druid" and M.whispers[#M.whispers].text:find("as tank"))
M.Advance(6)
M.Fire("CHAT_MSG_SYSTEM", "Flex Druid joins the party.")
M.Join("Flex", "Druid", "DRUID", "DAMAGER")
M.Fire("GROUP_ROSTER_UPDATE")
ns.UI.Refresh()
report("joined: + off until the role check is answered", rowOf("Plus Dps").invite.enabled == false and rowOf("Plus Dps").invite.why:find("confirm their role"), rowOf("Plus Dps").invite.why)
ns.UI.RefreshStatus()
report("status shows the role check wait", findFrame(function(f) return type(f.text) == "string" and f.text:find("^Role check: waiting for Flex Druid") end) ~= nil)
M.party[1].role = "TANK"
M.Fire("PLAYER_ROLES_ASSIGNED")
ns.UI.Refresh()
report("a role change seen in the roster counts as the answer", Inviter.Busy() == nil and rowOf("Plus Dps").invite.enabled == true)
M.party = {}
M.Fire("GROUP_ROSTER_UPDATE")
M.Join("Some", "Body", "PRIEST", "NONE")
M.leader = false
ns.UI.Refresh()
report("not the leader: + off", rowOf("Plus Dps").invite.enabled == false and rowOf("Plus Dps").invite.why:find("leader"))
M.leader = true
M.party = {}
report("no errors after + tests", ns.lastError == nil, ns.lastError)

out(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	for i = math.max(1, #M.prints - 12), #M.prints do out("  chat: " .. tostring(M.prints[i])) end
end
