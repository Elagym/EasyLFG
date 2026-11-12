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

-- 5. One round: one invite per open role, at the same time, each with its whisper ------------------
ok, msg = Inviter.InviteRound(true)
report("round ok", ok, msg)
report("three invites at once", #M.invites == 3, #M.invites)
report("tank invited", Inviter.pending.TANK and Inviter.pending.TANK.name == "Fetto Vandike")
report("healer invited", Inviter.pending.HEALER and Inviter.pending.HEALER.name == "Garlick Naan")
report("best dps invited", Inviter.pending.DAMAGER and Inviter.pending.DAMAGER.name == "Rogue One")
local whisperTo = {}
for _, w in ipairs(M.whispers) do whisperTo[w.target] = w.text end
report("tank whisper says as tank", whisperTo["Fetto Vandike"] == "Hi, do you wanna join for Deadmines as tank ?", whisperTo["Fetto Vandike"])
report("healer whisper says as healer", whisperTo["Garlick Naan"] == "Hi, do you wanna join for Deadmines as healer ?", whisperTo["Garlick Naan"])
report("dps whisper", whisperTo["Rogue One"] == "Hi, do you wanna join for Deadmines as dps ?", whisperTo["Rogue One"])
report("each whisper goes with its invite", #M.whispers == 3)
local state = Finder.Evaluate()
report("waiting invites hold their seats", state.remaining.TANK == 0 and state.remaining.HEALER == 0 and state.remaining.DAMAGER == 1, state.remaining.DAMAGER)
report("other tanks wait", find("Wrong Tank").status == "nofit")

ok, msg = Inviter.InviteRound(true)
report("max one waiting per role", not ok and #M.invites == 3 and msg:find("Waiting for"), msg)
ok, msg = Inviter.InviteCandidate(find("Rogue Two"), "DAMAGER")
report("hand invite refused while dps waits", not ok and msg:find("Still waiting") and #M.invites == 3, msg)

M.Fire("CHAT_MSG_SYSTEM", "You have invited Fetto Vandike to join your group.")
report("server confirmation keeps waiting", Inviter.pending.TANK and Inviter.pending.TANK.confirmed)

-- 6. Tank declines: no other tank fits, the others keep waiting ---------------------------------------
M.Fire("CHAT_MSG_SYSTEM", "Fetto Vandike declines your group invitation.")
report("tank seat freed", Inviter.pending.TANK == nil and Inviter.pending.HEALER ~= nil)
report("decline remembered", ns.asked["fetto-vandike"].outcome == "declined" and find("Fetto Vandike").status == "asked")
ok, msg = Inviter.InviteRound(true)
report("no tank to invite, nothing sent", not ok and #M.invites == 3 and msg:find("Tank"), msg)

-- 7. Healer joins (surname in the realm slot): never a second healer -----------------------------------
M.Join("Garlick", "Naan", "PRIEST", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("healer joined", Inviter.pending.HEALER == nil and EasyLFGDB.memberRoles["garlick-naan"].role == "HEALER")
M.AddListing({ name = "Holy Paly", class = "PALADIN", level = 30, healer = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("second healer not wanted", find("Holy Paly").reason == "no Healer needed", find("Holy Paly").reason)
ok = Inviter.InviteRound(true)
report("no second healer invited", #M.invites == 3)

-- 8. DPS joins, the next DPS goes out -------------------------------------------------------------
M.Fire("CHAT_MSG_SYSTEM", "Rogue One joins the party.")
M.Join("Rogue", "One", "ROGUE", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("dps joined with role", EasyLFGDB.memberRoles["rogue-one"].role == "DAMAGER" and Inviter.PendingCount() == 0)
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
report("new results: tank and dps together", Inviter.pending.TANK and Inviter.pending.TANK.name == "Big Bear" and Inviter.pending.DAMAGER and Inviter.pending.DAMAGER.name == "Fire Mage", #M.invites)
report("bear not also invited as dps", #M.invites == 8)
-- The join message comes before the roster: the seat stays taken, no extra DPS is invited.
M.AddListing({ name = "Extra Dps", class = "HUNTER", level = 40, dps = true })
M.Fire("CHAT_MSG_SYSTEM", "Fire Mage joins the party.")
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED") -- auto mode tries a round here as well
state = Finder.Evaluate()
report("joiner's seat held before the roster", state.remaining.DAMAGER == 0 and Inviter.pending.DAMAGER == nil and #M.invites == 8, #M.invites)
report("extra dps not a match", find("Extra Dps").status == "nofit", find("Extra Dps").reason)
M.Join("Big", "Bear", "DRUID", "NONE")
M.Join("Fire", "Mage", "MAGE", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("held seat released once in the roster", next(Inviter.joining) == nil)
state = Finder.Evaluate()
report("group complete", state.complete and state.size == 5, state.size)
report("auto off when complete", Inviter.auto == false)
report("complete announced once", M.PrintsContain("Your group is complete") and (M.sound or 0) == 1)
ok, msg = Inviter.InviteRound(true)
report("no invite when complete", not ok and msg:find("complete"), msg)

-- 11. Distinct classes inside one round ------------------------------------------------------------
M.party = {}
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
report("distinct within a round", Inviter.pending.TANK.name == "Pala Tank" and Inviter.pending.DAMAGER.name == "Hunter Dps", Inviter.pending.DAMAGER and Inviter.pending.DAMAGER.name)
report("two invites", #M.invites == before + 2)
ns.settings.distinctClasses = false
-- A message without a name counts only when a single invite waits
M.Fire("CHAT_MSG_SYSTEM", "Your party is full.")
report("plain message ignored with two waiting", Inviter.PendingCount() == 2)
M.Fire("CHAT_MSG_SYSTEM", "Hunter Dps declines your group invitation.")
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
local inviteButton = findFrame(function(f) return f.kind == "Button" and f.text == "Invite" end)
report("buttons found", searchButton and inviteButton)
report("no ask-again box", not findFrame(function(f) return f.text == "Ask again after (min)" end))
local saved = ns.settings.activityID
ns.settings.activityID = nil
ns.UI.Refresh()
report("search button off without dungeon", searchButton.enabled == false and inviteButton.enabled == false)
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
local classButton = findFrame(function(f) return f.scripts.OnClick and type(f.text) == "string" and f.text:find("Warrior") end)
classButton.scripts.OnClick(classButton)
local warrior
for _, item in ipairs(M.menu.items) do if item.kind == "check" and item.data == "WARRIOR" then warrior = item end end
report("class menu toggles", warrior and warrior.b(warrior.data) == 2 and ns.settings.roles.TANK.classes.WARRIOR == false)
ns.InitDB()
report("unticked survives reload", ns.settings.roles.TANK.classes.WARRIOR == false)
ns.settings.roles.TANK.classes.WARRIOR = true
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
	if item.text == "Invite now as DPS" then inviteItem = item end
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

-- Auto mode: DPS and healer are open with nobody to invite, so it refreshes every 10 s.
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
report("tank and healer invited", Inviter.pending.TANK and Inviter.pending.TANK.name == "Bear Tank" and Inviter.pending.HEALER and Inviter.pending.HEALER.name == "Holy Priest", msg)
local polls = M.rolePolls
M.Fire("CHAT_MSG_SYSTEM", "Bear Tank joins the party.")
report("no role check before the roster shows the tank", M.rolePolls == polls)
M.Join("Bear", "Tank", "DRUID", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("role check once the tank is in the roster", M.rolePolls == polls + 1, M.rolePolls - polls)

-- The druid picks healer: the tank seat opens again and auto mode fills it.
M.AddListing({ name = "Spare Tank", class = "WARRIOR", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("tank seat still taken before the answer", Inviter.pending.TANK == nil and find("Spare Tank").status == "nofit")
M.party[1].role = "HEALER"
M.Fire("ROLE_CHANGED_INFORM", "Bear Tank", "Bear Tank", "NONE", "HEALER")
report("answer stored", EasyLFGDB.memberRoles["bear-tank"].chosen == "HEALER")
report("you are told the seat reopened", M.PrintsContain("Bear Tank picked Healer in the role check (invited as Tank)"))
report("too many healers flagged", M.PrintsContain("You now have 2 Healer for 1 wanted"))
report("new tank invited right away", Inviter.pending.TANK and Inviter.pending.TANK.name == "Spare Tank")
state = Finder.Evaluate()
report("answer counts over the invited role", state.filled.HEALER == 2 and state.filled.TANK == 1, state.filled.TANK)

-- Group complete, then a role check reopens a seat: auto mode comes back.
M.Fire("CHAT_MSG_SYSTEM", "Holy Priest declines your group invitation.")
M.Fire("CHAT_MSG_SYSTEM", "Spare Tank joins the party.")
M.Join("Spare", "Tank", "WARRIOR", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
state = Finder.Evaluate()
report("complete with the spare tank", state.complete and Inviter.auto == false)
local pollsBefore = M.rolePolls
M.Advance(6)
report("role check for the new tank too", M.rolePolls > pollsBefore)
M.AddListing({ name = "Last Tank", class = "PALADIN", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.party[2].role = "DAMAGER"
M.Fire("ROLE_CHANGED_INFORM", "Spare Tank", "Spare Tank", "NONE", "DAMAGER")
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
report("role check for the unknown member", M.rolePolls == polls + 1, M.rolePolls - polls)
EasyLFGFrame:Hide()
M.Advance(10)
EasyLFGFrame:Show()
report("no second role check for the same members", M.rolePolls == polls + 1)
M.Join("New", "Face", "MAGE", "NONE")
EasyLFGFrame:Hide()
M.Advance(10)
EasyLFGFrame:Show()
report("new unknown member: role check again", M.rolePolls == polls + 2)
report("overfilled dps shown", findFrame(function(f) return type(f.text) == "string" and f.text:find("3/3") end) ~= nil)
M.party[3].role = "DAMAGER"
M.party[4].role = "DAMAGER"
ns.settings.roles.DAMAGER.need = 2
ns.UI.Refresh()
report("more than wanted is red", findFrame(function(f) return type(f.text) == "string" and f.text:find("ff6060" .. "3/2") end) ~= nil)
ns.settings.roles.DAMAGER.need = 3
report("no errors after window tests", ns.lastError == nil, ns.lastError)

out(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	for i = math.max(1, #M.prints - 12), #M.prints do out("  chat: " .. tostring(M.prints[i])) end
end
