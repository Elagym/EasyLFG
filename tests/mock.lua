-- A small simulated WoW client for EasyLFG tests.
local M = {}
M.clock = 1000
M.timeOffset = 0
M.prints = {}
M.whispers = {}
M.invites = {}
M.searches = {}
M.results = {} -- resultID -> { info = {...}, player = {...} }
M.resultOrder = {}
M.party = {} -- { name=, realm=, class=, role= }
M.leader = true
M.secret = {} -- values that count as secret
M.frames = {}
M.timers = {}
M.menu = nil

local function noop() end

-- Frames ---------------------------------------------------------------------------------
local FrameMethods = {}
FrameMethods.__index = function(self, key)
	local method = rawget(FrameMethods, key)
	if method then return method end
	return noop
end
function FrameMethods.SetScript(self, name, fn) self.scripts[name] = fn end
function FrameMethods.GetScript(self, name) return self.scripts[name] end
function FrameMethods.RegisterEvent(self, event) self.events[event] = true end
function FrameMethods.UnregisterEvent(self, event) self.events[event] = nil end
function FrameMethods.Show(self) local was = self.shown; self.shown = true; if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
function FrameMethods.Hide(self) self.shown = false end
function FrameMethods.SetShown(self, v) if v then self:Show() else self:Hide() end end
function FrameMethods.IsShown(self) return self.shown end
function FrameMethods.SetText(self, t) self.text = t end
function FrameMethods.GetText(self) return self.text end
function FrameMethods.SetChecked(self, v) self.checked = v and true or false end
function FrameMethods.GetChecked(self) return self.checked end
function FrameMethods.HasFocus(self) return false end
function FrameMethods.ClearFocus(self) if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end end
function FrameMethods.SetEnabled(self, v) self.enabled = v end
function FrameMethods.IsEnabled(self) return self.enabled ~= false end
function FrameMethods.GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function FrameMethods.GetWidth() return 100 end
function FrameMethods.GetHeight() return 20 end
function FrameMethods.CreateFontString(self) return M.NewFrame("FontString") end
function FrameMethods.CreateTexture(self) return M.NewFrame("Texture") end

function M.NewFrame(kind, name)
	local f = setmetatable({ kind = kind, scripts = {}, events = {}, shown = true, text = "" }, FrameMethods)
	if name then _G[name] = f end
	table.insert(M.frames, f)
	return f
end

function M.Fire(event, ...)
	for _, f in ipairs(M.frames) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end

function M.Advance(seconds)
	local target = M.clock + seconds
	while true do
		table.sort(M.timers, function(a, b) return a.at < b.at end)
		local t = M.timers[1]
		if not t or t.at > target then break end
		table.remove(M.timers, 1)
		M.clock = t.at
		t.fn()
	end
	M.clock = target
end

-- Install globals ---------------------------------------------------------------------------
function M.Install()
	_G.CreateFrame = function(kind, name) return M.NewFrame(kind, name) end
	_G.UIParent = M.NewFrame("Frame")
	_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(M.prints, msg) end }
	_G.print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end table.insert(M.prints, table.concat(parts, " ")) end
	_G.GetTime = function() return M.clock end
	local realTime = os.time
	_G.time = function() return realTime() + M.timeOffset end
	_G.date = os.date
	_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	_G.tinsert = table.insert
	_G.UISpecialFrames = {}
	_G.SlashCmdList = {}
	_G.issecretvalue = function(v) return v ~= nil and M.secret[v] == true end
	_G.C_Timer = { After = function(delay, fn) table.insert(M.timers, { at = M.clock + delay, fn = fn }) end }
	_G.C_AddOns = { GetAddOnMetadata = function() return "1.0.0" end }
	_G.SOUNDKIT = { READY_CHECK = 8960 }
	_G.PlaySound = function() M.sound = (M.sound or 0) + 1 end
	_G.UNKNOWNOBJECT = "Unknown"
	_G.GameTooltip = M.NewFrame("GameTooltip")
	_G.MenuResponse = { Refresh = 2 }
	_G.ERR_JOINED_GROUP_S = "%s joins the party."
	_G.ERR_RAID_MEMBER_ADDED_S = "%s has joined the raid group."
	_G.ERR_DECLINE_GROUP_S = "%s declines your group invitation."
	_G.ERR_ALREADY_IN_GROUP_S = "%s is already in a group."
	_G.ERR_BAD_PLAYER_NAME_S = "Cannot find player '%s'."
	_G.ERR_IGNORING_YOU_S = "%s is ignoring you."
	_G.ERR_INVITE_PLAYER_S = "You have invited %s to join your group."
	_G.ERR_GROUP_FULL = "Your party is full."
	_G.LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid" }
	_G.RAID_CLASS_COLORS = {}
	for class in pairs(LOCALIZED_CLASS_NAMES_MALE) do RAID_CLASS_COLORS[class] = { r = 1, g = 1, b = 1, colorStr = "ffffffff" } end

	-- Units and group
	M.myClass = "MAGE"
	local function partyIndex(unit) return tonumber(unit:match("^party(%d)$")) end
	_G.UnitExists = function(unit) if unit == "player" then return true end local i = partyIndex(unit) return i ~= nil and M.party[i] ~= nil end
	_G.UnitIsPlayer = function() return true end
	_G.UnitName = function(unit)
		if unit == "player" then return "Me Myself", nil end
		local m = M.party[partyIndex(unit) or 0]
		if m then return m.name, m.realm end
	end
	_G.UnitClass = function(unit)
		if unit == "player" then return "Mage", M.myClass end
		local m = M.party[partyIndex(unit) or 0]
		if m then return m.class, m.class end
	end
	_G.UnitGroupRolesAssigned = function(unit) local m = M.party[partyIndex(unit) or 0] return m and m.role or "NONE" end
	_G.UnitIsUnit = function(a, b) return a == b end
	_G.IsInGroup = function() return #M.party > 0 end
	_G.IsInRaid = function() return false end
	_G.GetNumSubgroupMembers = function() return #M.party end
	_G.GetNumGroupMembers = function() return #M.party + 1 end
	_G.UnitIsGroupLeader = function() return M.leader end
	_G.UnitIsGroupAssistant = function() return false end

	_G.C_PartyInfo = { InviteUnit = function(name) table.insert(M.invites, name) if M.inviteError then error(M.inviteError) end end }
	_G.C_ChatInfo = { SendChatMessage = function(text, kind, lang, target) table.insert(M.whispers, { text = text, kind = kind, target = target }) end }
	_G.C_Secrets = { HasSecretRestrictions = function() return true end }

	-- Group Finder
	M.activities = {
		[801] = { fullName = "The Deadmines", shortName = "Deadmines", categoryID = 2, maxNumPlayers = 5, minLevelSuggestion = 17, maxLevelSuggestion = 26, orderIndex = 3 },
		[802] = { fullName = "Wailing Caverns", shortName = "", categoryID = 2, maxNumPlayers = 5, minLevelSuggestion = 15, maxLevelSuggestion = 25, orderIndex = 2 },
		[803] = { fullName = "Gnome%Town", shortName = "", categoryID = 2, maxNumPlayers = 5, minLevelSuggestion = 0, maxLevelSuggestion = 0, orderIndex = 9 },
		[901] = { fullName = "Molten Core", shortName = "MC", categoryID = 114, maxNumPlayers = 40, minLevelSuggestion = 60, maxLevelSuggestion = 60, orderIndex = 1 },
	}
	_G.C_LFGList = {
		GetAvailableCategories = function() return { 2, 114 } end,
		GetLfgCategoryInfo = function(id) return { name = id == 2 and "Dungeons" or "Raids" } end,
		GetAvailableActivities = function(cat) local list = {} for id, a in pairs(M.activities) do if a.categoryID == cat then list[#list + 1] = id end end table.sort(list) return list end,
		GetActivityInfoTable = function(id) return M.activities[id] end,
		Search = function(...) table.insert(M.searches, { ... }) end,
		GetSearchResults = function() return #M.resultOrder, M.resultOrder end,
		GetSearchResultInfo = function(id) local r = M.results[id] return r and r.info end,
		GetSearchResultPlayerInfo = function(id, i) local r = M.results[id] return r and i == 1 and r.player or nil end,
		GetSearchResultLeaderInfo = function(id) local r = M.results[id] return r and r.player end,
	}

	-- Menus: the last menu built is kept so tests can click in it.
	local function newDescription()
		local d = { items = {} }
		local function add(kind, text, a, b, data)
			local item = newDescription()
			item.kind, item.text, item.a, item.b, item.data = kind, text, a, b, data
			table.insert(d.items, item)
			return item
		end
		d.CreateTitle = function(_, text) return add("title", text) end
		d.CreateButton = function(_, text, fn) return add("button", text, fn) end
		d.CreateRadio = function(_, text, isSel, setSel, data) return add("radio", text, isSel, setSel, data) end
		d.CreateCheckbox = function(_, text, isSel, setSel, data) return add("check", text, isSel, setSel, data) end
		d.CreateDivider = function() return add("divider") end
		d.SetScrollMode = function() end
		d.SetEnabled = function(self, v) self.enabled = v end
		return d
	end
	_G.MenuUtil = { CreateContextMenu = function(owner, fn) local root = newDescription() fn(owner, root) M.menu = root end }
	_G.C_Texture = { GetAtlasInfo = function() return nil end }
end

-- Helpers for tests -------------------------------------------------------------------------
local nextResult = 100
function M.AddListing(opts)
	nextResult = nextResult + 1
	local id = nextResult
	M.results[id] = {
		info = {
			leaderName = opts.name, numMembers = opts.members or 1, isDelisted = opts.delisted or false,
			hasSelf = false, age = opts.age or 100, comment = opts.comment or "",
			activityIDs = opts.activities or { 801 },
		},
		player = {
			name = opts.name, level = opts.level, classFilename = opts.class, className = opts.class,
			lfgRoles = { tank = opts.tank or false, healer = opts.healer or false, dps = opts.dps or false },
			assignedRole = "NONE", isLeader = true,
		},
	}
	table.insert(M.resultOrder, id)
	return id
end

function M.ClearListings()
	M.results = {}
	M.resultOrder = {}
end

function M.Join(name, realm, class, role)
	table.insert(M.party, { name = name, realm = realm, class = class, role = role })
end

function M.Load(dir)
	local ns = {}
	for _, file in ipairs({ "Core.lua", "Finder.lua", "Inviter.lua", "UI.lua", "Slash.lua" }) do
		local chunk = assert(loadfile(dir .. "/" .. file))
		chunk("EasyLFG", ns)
	end
	return ns
end

function M.LastPrint()
	return M.prints[#M.prints]
end

function M.PrintsContain(text)
	for _, p in ipairs(M.prints) do
		if p:find(text, 1, true) then return true end
	end
	return false
end

return M
