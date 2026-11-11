package.path = arg[1] .. "/?.lua;" .. package.path
local ADDON = arg[2]
local M = require("mock")
M.Install()

local passed, failed = 0, 0
local function realPrint(s)
	io.write(tostring(s), string.char(10))
end
local function check(label, cond, extra)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		realPrint("FAIL: " .. label .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
	end
end

local ns = M.Load(ADDON)
local function report(label, cond, extra) check(label, cond, extra) end

-- 1. Loading ----------------------------------------------------------------------------------
M.Fire("ADDON_LOADED", "EasyLFG")
report("db created", type(EasyLFGDB) == "table" and ns.settings ~= nil)
report("default needs 1/1/3", ns.settings.roles.TANK.need == 1 and ns.settings.roles.HEALER.need == 1 and ns.settings.roles.DAMAGER.need == 3)
report("default tank classes", ns.settings.roles.TANK.classes.WARRIOR and not ns.settings.roles.TANK.classes.MAGE)
report("slash registered", SlashCmdList.EASYLFG ~= nil and SLASH_EASYLFG1 == "/elfg")

-- 2. Activities --------------------------------------------------------------------------------
local groups = ns.Finder.ListActivities()
report("one category (raid left out)", #groups == 1, #groups)
report("three dungeons", #groups[1].activities == 3)
report("sorted by level, short name fallback", groups[1].activities[2].name == "Wailing Caverns" or groups[1].activities[1].name == "Wailing Caverns", groups[1].activities[1].name)
local deadmines
for _, a in ipairs(groups[1].activities) do if a.id == 801 then deadmines = a end end
report("search without dungeon refused", not ns.Finder.Search())
ns.Finder.SetActivity(deadmines)
report("activity saved", ns.settings.activityID == 801 and ns.settings.activityName == "Deadmines" and ns.settings.categoryID == 2)
report("min level follows dungeon", ns.settings.roles.TANK.minLevel == 17 and ns.settings.roles.DAMAGER.minLevel == 17)

-- 3. Search and results ---------------------------------------------------------------------------
local ok, msg = ns.Finder.Search()
report("search ok", ok, msg)
local s = M.searches[1]
report("search args", s and s[1] == 2 and s[7] and s[7][1] == 801, s and s[1])

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

local cands = ns.Finder.candidates
report("searching cleared", ns.Finder.searching == false)
report("solo for dungeon only", #cands == 8, #cands)
report("stats", ns.Finder.stats.groups == 1 and ns.Finder.stats.otherActivity == 1, ns.Finder.stats.groups)
local order = {}
for i, c in ipairs(cands) do order[i] = c.name .. ":" .. tostring(c.status) end
report("tank first", cands[1].name == "Fetto Vandike" and cands[1].role == "TANK", table.concat(order, ", "))
report("healer second", cands[2].name == "Garlick Naan" and cands[2].role == "HEALER", cands[2].name)
report("dps by level", cands[3].name == "Rogue One" and cands[4].name == "Rogue Two" and cands[5].name == "Norole Mage", table.concat(order, ", "))
report("no-role taken as dps", cands[5].guessedRole == true and cands[5].reason:find("no role listed"))
local function find(name) for _, c in ipairs(cands) do if c.name == name then return c end end end
report("low level reason", find("Low Guy").status == "nofit" and find("Low Guy").reason:find("level 15"), find("Low Guy").reason)
report("delisted reason", find("Closed Hunter").status == "delisted")
report("class not wanted", find("Wrong Tank").reason == "Mage not wanted as Tank", find("Wrong Tank").reason)

-- 4. Invite next: whisper + invite --------------------------------------------------------------
ok, msg = ns.Inviter.InviteNext(true)
report("invite ok", ok, msg)
report("whisper text", M.whispers[1] and M.whispers[1].text == "Hi, do you wanna join for Deadmines ?" and M.whispers[1].target == "Fetto Vandike" and M.whispers[1].kind == "WHISPER", M.whispers[1] and M.whispers[1].text)
report("invite sent to leaderName", M.invites[1] == "Fetto Vandike")
report("pending", ns.Inviter.pending and ns.Inviter.pending.role == "TANK")
ok, msg = ns.Inviter.InviteNext(true)
report("one at a time", not ok and msg:find("Still waiting"), msg)
report("only one invite", #M.invites == 1)
report("pending listed first as invited", cands[1].status == "invited")

-- Server confirmation does not end the wait
M.Fire("CHAT_MSG_SYSTEM", "You have invited Fetto Vandike to join your group.")
report("confirmed", ns.Inviter.pending and ns.Inviter.pending.confirmed == true)

-- 5. Decline ---------------------------------------------------------------------------------
M.Fire("CHAT_MSG_SYSTEM", "Fetto Vandike declines your group invitation.")
report("declined resolves", ns.Inviter.pending == nil)
report("declined remembered", EasyLFGDB.asked["fetto-vandike"].outcome == "declined")
report("declined shown", find("Fetto Vandike").status == "asked" and find("Fetto Vandike").reason:find("declined"), find("Fetto Vandike").reason)

-- 6. Healer joins with surname in the realm slot ------------------------------------------------
ok, msg = ns.Inviter.InviteNext(true)
report("healer invited", ok and M.invites[2] == "Garlick Naan", msg)
M.Join("Garlick", "Naan", "PRIEST", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("join via roster", ns.Inviter.pending == nil and EasyLFGDB.asked["garlick-naan"].outcome == "joined")
report("member role stored", EasyLFGDB.memberRoles["garlick-naan"] and EasyLFGDB.memberRoles["garlick-naan"].role == "HEALER")
local state = ns.Finder.Evaluate()
report("healer filled", state.filled.HEALER == 1 and state.unknownRoles == 0, state.unknownRoles)
report("in group status", find("Garlick Naan").status == "ingroup")
-- system "joins" message after the roster must not break anything
M.Fire("CHAT_MSG_SYSTEM", "Garlick Naan joins the party.")
report("double join harmless", ns.Inviter.pending == nil)

-- 7. Distinct classes ------------------------------------------------------------------------------
ns.settings.distinctClasses = true
ns.Finder.Evaluate()
report("same class as me refused", find("Norole Mage").status == "nofit" and find("Norole Mage").reason:find("Mage already"), find("Norole Mage").reason)
ok = ns.Inviter.InviteNext(true)
report("rogue one invited", ok and M.invites[3] == "Rogue One")
report("second rogue blocked while first pending", find("Rogue Two").status == "nofit" and find("Rogue Two").reason:find("Rogue already"), find("Rogue Two").reason)
M.Fire("CHAT_MSG_SYSTEM", "Rogue One joins the party.")
report("join via system message", ns.Inviter.pending == nil and EasyLFGDB.memberRoles["rogue-one"].role == "DAMAGER")
M.Join("Rogue", "One", "ROGUE", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
ns.settings.distinctClasses = false

-- 8. Auto mode with a timeout ---------------------------------------------------------------------
-- Need: tank 1 (none), dps 3 (me + rogue one = 2). Candidates: Rogue Two (dps), Norole Mage (dps).
ok, msg = ns.Inviter.Start()
report("auto starts and invites", ok and ns.Inviter.auto and M.invites[4] == "Rogue Two", msg)
M.Advance(59)
report("still waiting at 59s", ns.Inviter.pending ~= nil)
M.Advance(2)
report("timed out", ns.Inviter.pending == nil and EasyLFGDB.asked["rogue-two"].outcome == "noanswer")
report("next scheduled", ns.Inviter.nextAt ~= nil)
M.Advance(5)
report("auto invited next", M.invites[5] == "Norole Mage", M.invites[5])
-- Late accept from Rogue Two
M.Fire("CHAT_MSG_SYSTEM", "Norole Mage is already in a group.")
report("busy resolves", ns.Inviter.pending == nil and EasyLFGDB.asked["norole-mage"].outcome == "busy")
M.Join("Rogue", "Two", "ROGUE", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
report("late joiner gets their role", EasyLFGDB.memberRoles["rogue-two"] and EasyLFGDB.memberRoles["rogue-two"].role == "DAMAGER")
state = ns.Finder.Evaluate()
report("dps now full", state.remaining.DAMAGER == 0 and state.remaining.TANK == 1, state.remaining.DAMAGER)
-- auto continues; nobody fits (only tank needed; Fetto declined, Wrong Tank is a mage)
M.Advance(6)
report("no extra invite when nobody fits", #M.invites == 5, #M.invites)
report("auto still on", ns.Inviter.auto == true)

-- 9. New results in auto mode bring a tank ---------------------------------------------------------
M.AddListing({ name = "Big Bear", class = "DRUID", level = 26, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("auto picks new tank", M.invites[6] == "Big Bear", M.invites[6])
M.Join("Big", "Bear", "DRUID", "NONE")
M.Fire("GROUP_ROSTER_UPDATE")
state = ns.Finder.Evaluate()
report("group complete", state.complete and state.size == 5, state.size)
report("auto stopped at complete", ns.Inviter.auto == false)
report("complete announced", M.PrintsContain("Your group is complete"))
report("sound played", (M.sound or 0) == 1)
ok, msg = ns.Inviter.InviteNext(true)
report("no invite when complete", not ok and msg:find("complete"), msg)

-- 10. Not the leader ------------------------------------------------------------------------------
M.party = { { name = "Garlick", realm = "Naan", class = "PRIEST" } }
M.leader = false
ok, msg = ns.Inviter.InviteNext(true)
report("not leader refused", not ok and msg:find("leader"), msg)
M.leader = true

-- 11. Message template --------------------------------------------------------------------------------
ns.settings.message = "Hey <name>, <role> for <Dungeon>? 100%"
ns.settings.activityName = "Gnome%Town"
local text = ns.Inviter.FormatMessage({ name = "Fetto Vandike", role = "TANK" })
report("template", text == "Hey Fetto, Tank for Gnome%Town? 100%", text)
ns.settings.message = "   "
report("blank template falls back", ns.Inviter.FormatMessage({ name = "A", role = "DAMAGER" }):find("wanna join"))
ns.settings.activityName = "Deadmines"
ns.settings.message = ns.DEFAULT_MESSAGE

-- 12. Patterns --------------------------------------------------------------------------------------
report("pattern escapes", ("Cannot find player 'Bob Smith'."):match(ns.Inviter.ToPattern(ERR_BAD_PLAYER_NAME_S)) == "Bob Smith")
report("pattern %1$s", ("Ann joins."):match(ns.Inviter.ToPattern("%1$s joins.")) == "Ann")
report("strip link", ns.StripCodes("|Hplayer:Bob-Smith|h[Bob Smith]|h declines your group invitation.") == "Bob Smith declines your group invitation.", ns.StripCodes("|Hplayer:Bob-Smith|h[Bob Smith]|h declines"))

-- 13. Names ------------------------------------------------------------------------------------------
report("same name space/dash", ns.SameName("Garlick Naan", "Garlick-Naan"))
report("loose first name", ns.SameName("Garlick", "Garlick Naan"))
report("different surname", not ns.SameName("Garlick Naan", "Garlick Other"))
report("join name drops realm id", ns.JoinName("Bob", "93") == "Bob")

-- 14. Secret values ------------------------------------------------------------------------------
M.party = {}
wipe(EasyLFGDB.asked)
M.ClearListings()
M.AddListing({ name = "Secret Sam", class = "WARRIOR", level = 30, tank = true })
M.secret["Secret Sam"] = true
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("secret listing hidden", ns.Finder.candidates[1] and ns.Finder.candidates[1].status == "hidden" and ns.Finder.stats.hidden == 1)
M.secret["Secret Sam"] = nil

-- 15. Invite failure and blocked actions ---------------------------------------------------------
M.ClearListings()
M.AddListing({ name = "Fail Guy", class = "WARRIOR", level = 30, tank = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.inviteError = "boom"
ok, msg = ns.Inviter.InviteNext(true)
report("invite error handled", not ok and msg:find("boom") and ns.Inviter.pending == nil, msg)
report("failed remembered", EasyLFGDB.asked["fail-guy"].outcome == "failed")
M.inviteError = nil
wipe(EasyLFGDB.asked)
ns.Inviter.auto = true
M.Fire("ADDON_ACTION_BLOCKED", "EasyLFG", "C_PartyInfo.InviteUnit()")
report("blocked stops auto", ns.Inviter.auto == false and ns.blocked["C_PartyInfo.InviteUnit()"] == 1)
M.Fire("ADDON_ACTION_BLOCKED", "OtherAddon", "Foo()")
report("other addon ignored", ns.blocked["Foo()"] == nil)

-- 16. Empty list click starts a search, and the results then invite ------------------------------
M.ClearListings()
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
M.Advance(20)
local searches = #M.searches
ok, msg = ns.Inviter.InviteNext(true)
report("empty list searches", ok and #M.searches == searches + 1 and ns.Inviter.inviteAfterSearch, msg)
M.AddListing({ name = "Tardy Tank", class = "PALADIN", level = 30, tank = true })
local before = #M.invites
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
report("invite after search", #M.invites == before + 1 and M.invites[#M.invites] == "Tardy Tank")
M.Fire("CHAT_MSG_SYSTEM", "Cannot find player 'Tardy Tank'.")
report("not found resolves", ns.Inviter.pending == nil and EasyLFGDB.asked["tardy-tank"].outcome == "notfound")
-- Without a click, an empty list does not search
M.Advance(20)
searches = #M.searches
ok = ns.Inviter.InviteNext(false)
report("timer never searches", not ok and #M.searches == searches)

-- 17. Forget window ------------------------------------------------------------------------------
M.timeOffset = 31 * 60
ns.Finder.Evaluate()
report("asked again after window", ns.Finder.candidates[1].status == "match", ns.Finder.candidates[1].status)
M.timeOffset = 0

-- 18. UI -----------------------------------------------------------------------------------------
local uiOk, uiErr = pcall(ns.UI.Show)
report("window builds", uiOk, uiErr)
report("window shown", ns.UI.IsShown())
report("no error recorded", ns.lastError == nil, ns.lastError)
local frame = EasyLFGFrame
report("UISpecialFrames", UISpecialFrames[1] == "EasyLFGFrame")
-- Class menu: untick Warrior for tanks
ns.settings.roles.TANK.classes.WARRIOR = true
local classButton
for _, f in ipairs(M.frames) do
	if f.scripts.OnClick and f.text and f.text:find("Warrior") then classButton = f end
end
report("class button found", classButton ~= nil)
if classButton then
	classButton.scripts.OnClick(classButton)
	local menu = M.menu
	local warrior
	for _, item in ipairs(menu.items) do if item.kind == "check" and item.data == "WARRIOR" then warrior = item end end
	report("warrior checked", warrior and warrior.a(warrior.data) == true)
	local response = warrior.b(warrior.data)
	report("warrior unticked", ns.settings.roles.TANK.classes.WARRIOR == false and response == 2)
end
-- Defaults never re-tick an unticked class
ns.InitDB()
report("unticked survives reload", ns.settings.roles.TANK.classes.WARRIOR == false)
ns.settings.roles.TANK.classes.WARRIOR = true
-- Number box clamps
local needBox
for _, f in ipairs(M.frames) do
	if f.kind == "EditBox" and rawget(f, "load") and f.text == "1" and not needBox then needBox = f end
end
if needBox then
	needBox.text = "99"
	needBox:ClearFocus()
	report("need clamped to 5", ns.settings.roles.TANK.need == 5 and needBox.text == "5", ns.settings.roles.TANK.need)
	needBox.text = "1"
	needBox:ClearFocus()
end
-- Dungeon menu selects
local dungeonButton
for _, f in ipairs(M.frames) do if f.text == "Deadmines" and f.scripts.OnClick then dungeonButton = f end end
report("dungeon button shows choice", dungeonButton ~= nil)
if dungeonButton then
	dungeonButton.scripts.OnClick(dungeonButton)
	local wc
	for _, item in ipairs(M.menu.items) do if item.kind == "radio" and item.data.id == 802 then wc = item end end
	report("dungeon menu lists WC", wc ~= nil)
	wc.b(wc.data)
	report("dungeon switched", ns.settings.activityID == 802 and ns.settings.roles.HEALER.minLevel == 15)
end
-- Row menu
ns.Finder.SetActivity(deadmines)
M.ClearListings()
M.AddListing({ name = "Menu Man", class = "WARLOCK", level = 40, dps = true })
M.Fire("LFG_LIST_SEARCH_RESULTS_RECEIVED")
ns.UI.Refresh()
local row
for _, f in ipairs(M.frames) do if rawget(f, "candidate") and f.candidate.name == "Menu Man" then row = f end end
report("row drawn", row ~= nil)
if row then
	row.scripts.OnClick(row)
	local skip
	for _, item in ipairs(M.menu.items) do if item.text == "Skip this player" then skip = item end end
	skip.a()
	report("skip works", ns.Finder.candidates[1].status == "skipped")
	row.scripts.OnEnter(row)
end
-- Slash commands
SlashCmdList.EASYLFG("debug")
report("debug prints", M.PrintsContain("Blocked by the game"))
SlashCmdList.EASYLFG("forget")
report("forget clears skip", ns.Finder.candidates[1].status == "match")
SlashCmdList.EASYLFG("help")
report("no errors at the end", ns.lastError == nil, ns.lastError)

-- 19. LFG frame button ---------------------------------------------------------------------------
LFGBrowseFrame = M.NewFrame("Frame")
LFGBrowseFrame.SendMessageButton = M.NewFrame("Button")
M.Fire("ADDON_LOADED", "Blizzard_GroupFinder_VanillaStyle")
local lfgButton
for _, f in ipairs(M.frames) do if f.text == "EasyLFG" and f.kind == "Button" then lfgButton = f end end
report("group finder button", lfgButton ~= nil)

realPrint(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	for i = math.max(1, #M.prints - 12), #M.prints do realPrint("  chat: " .. M.prints[i]) end
end
