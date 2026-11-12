-- EasyLFG: builds a dungeon group from the Group Finder. You say which dungeon, how many of each
-- role, the classes and minimum level for each role, and it invites matching players who listed
-- themselves, one at a time, each with a short whisper first.
--
-- Core: shared helpers, names, saved settings and the event hub.

local addonName, ns = ...

ns.NAME = addonName
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version"))
	or (GetAddOnMetadata and GetAddOnMetadata(addonName, "Version")) or "?"

local PREFIX = "|cff33ccffEasyLFG|r: "

ns.MAX_PARTY = 5
ns.MAX_LEVEL = 60

-- Roles in the order they are hardest to find, which is also the order they are filled in.
ns.ROLES = { "TANK", "HEALER", "DAMAGER" }
ns.ROLE_LABEL = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
-- The keys of the lfgRoles table on a Group Finder listing.
ns.ROLE_FLAG = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

-- The nine classes of the Vanilla world. The retail client knows more, but nobody here plays them.
ns.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- The classes able to play each role in the Vanilla world, in the order of ns.CLASSES. Only these
-- can be picked for a role; a hunter can never be wanted as tank or healer.
ns.ROLE_CLASSES = {
	TANK = { "WARRIOR", "PALADIN", "DRUID" },
	HEALER = { "PALADIN", "PRIEST", "SHAMAN", "DRUID" },
	DAMAGER = ns.CLASSES,
}

function ns.CanPlay(class, role)
	for _, allowed in ipairs(ns.ROLE_CLASSES[role] or {}) do
		if allowed == class then
			return true
		end
	end
	return false
end

-- The role in the whisper, as in "... as tank ?".
ns.ROLE_WORD = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

ns.DEFAULT_MESSAGE = "Hi, do you wanna join for <dungeon> as <role> ?"
local OLD_DEFAULT_MESSAGE = "Hi, do you wanna join for <dungeon> ?"

-- An unanswered invite closes itself on the other side after 60 s (Blizzard's StaticPopup
-- timeout) and comes back as a decline. EasyLFG only gives up later than that, so a player can
-- never accept after their seat was offered to someone else.
ns.MIN_TIMEOUT = 70
ns.MAX_TIMEOUT = 180

local function classSet(list)
	local set = {}
	for _, class in ipairs(list) do
		set[class] = true
	end
	return set
end

local DEFAULT_SETTINGS = {
	activityID = nil,
	activityName = nil,
	categoryID = nil,
	myRole = "DAMAGER",
	roles = {
		TANK = { need = 1, minLevel = 1, classes = classSet({ "WARRIOR", "DRUID", "PALADIN" }) },
		HEALER = { need = 1, minLevel = 1, classes = classSet({ "PRIEST", "DRUID", "PALADIN", "SHAMAN" }) },
		DAMAGER = { need = 3, minLevel = 1, classes = classSet(ns.CLASSES) },
	},
	distinctClasses = false,
	whisper = true,
	message = ns.DEFAULT_MESSAGE,
	timeout = 90, -- seconds before an invite without any answer is given up
}

-- Helpers --------------------------------------------------------------------------------

function ns.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value) == true
end

-- The value, or nil when the client hides it from addons.
function ns.Readable(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

function ns.Trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function ns.Print(message)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
end

function ns.Clamp(value, low, high)
	value = tonumber(value)
	if not value then
		return low
	end
	value = math.floor(value + 0.5)
	return math.max(low, math.min(high, value))
end

-- The log ----------------------------------------------------------------------------------
-- Every action EasyLFG takes, one timestamped line each, kept in the saved variables (the last
-- LOG_LIMIT lines) so it survives a reload. The same line twice in a row is counted, not repeated.
-- Lines are plain text, so the log window can be copied as is.

ns.LOG_LIMIT = 500
local earlyLog = {} -- lines logged before the saved variables are loaded

local function logList()
	return ns.db and ns.db.log or earlyLog
end

function ns.Log(text)
	text = ns.StripCodes and ns.StripCodes(tostring(text)) or tostring(text)
	local list = logList()
	local last = list[#list]
	local now = date("%H:%M:%S")
	if last and last.text == text then
		last.count = (last.count or 1) + 1
		last.last = now
	else
		list[#list + 1] = { day = date("%Y-%m-%d"), at = now, text = text }
		while #list > ns.LOG_LIMIT do
			table.remove(list, 1)
		end
	end
	if ns.OnLogChanged then
		ns.OnLogChanged()
	end
end

-- One line of the log as text: "12:01:05  Invited Fetto Vandike as Tank (x3, last 12:03:10)".
function ns.LogLine(entry)
	local line = entry.at .. "  " .. entry.text
	if entry.count and entry.count > 1 then
		line = line .. ("  (x%d, last %s)"):format(entry.count, entry.last or entry.at)
	end
	return line
end

function ns.ClearLog()
	local list = logList()
	for i = #list, 1, -1 do
		list[i] = nil
	end
	if ns.OnLogChanged then
		ns.OnLogChanged()
	end
end

-- Runs a handler protected: one error is announced once and kept for /elfg debug, so a client
-- surprise can never break the rest or spam the chat.
function ns.Guard(label, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			ns.lastError = label .. ": " .. tostring(err)
			ns.Log("Error in " .. ns.lastError)
			if not ns.errorShown then
				ns.errorShown = true
				ns.Print("|cffff6060Something went wrong; /elfg debug has the details.|r")
			end
		end
		return ok
	end
end

-- Classes --------------------------------------------------------------------------------

function ns.ClassName(class)
	local names = LOCALIZED_CLASS_NAMES_MALE
	if names and names[class] then
		return names[class]
	end
	if type(class) ~= "string" then
		return "?"
	end
	return class:sub(1, 1) .. class:sub(2):lower()
end

function ns.ClassColorCode(class)
	local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.colorStr then
		return "|c" .. color.colorStr
	end
	if color then
		return ("|cff%02x%02x%02x"):format(color.r * 255, color.g * 255, color.b * 255)
	end
	return "|cffffffff"
end

function ns.Colored(text, class)
	return ns.ClassColorCode(class) .. tostring(text) .. "|r"
end

-- Names ----------------------------------------------------------------------------------
-- Names on Forever are "First Surname", and the game spells them in several ways: with a space,
-- with a dash, or the surname in the realm slot of UnitName. A key makes them comparable.

local function nameParts(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local parts = {}
	for part in raw:gmatch("[^%s%-]+") do
		parts[#parts + 1] = part
	end
	return #parts > 0 and parts or nil
end

-- "Fetto Vandike", "Fetto-Vandike" and "fetto vandike" -> "fetto-vandike"
function ns.MakeKey(raw)
	local parts = nameParts(raw)
	if not parts then
		return nil
	end
	return table.concat(parts, "-"):lower()
end

-- Two spellings of the same player: equal keys, or the same first name when one side has no
-- surname (some messages leave it out).
function ns.SameName(a, b)
	local keyA, keyB = ns.MakeKey(a), ns.MakeKey(b)
	if not keyA or not keyB then
		return false
	end
	if keyA == keyB then
		return true
	end
	local firstA, firstB = keyA:match("^[^%-]+"), keyB:match("^[^%-]+")
	if firstA ~= firstB then
		return false
	end
	return not keyA:find("-", 1, true) or not keyB:find("-", 1, true)
end

-- The second value from UnitName is a surname on Forever. Character names have no digits, so a
-- value with digits is a real realm id and is dropped.
function ns.JoinName(name, realm)
	if type(realm) == "string" and realm ~= "" and not realm:find("%d") then
		return name .. "-" .. realm
	end
	return name
end

-- The name of a player unit, or nil when there is none or it cannot be read.
function ns.ReadUnitName(unit)
	local exists = ns.Readable(UnitExists(unit))
	if not exists then
		return nil
	end
	local name, realm = UnitName(unit)
	if ns.IsSecret(name) or ns.IsSecret(realm) then
		return nil
	end
	if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then
		return nil
	end
	return ns.JoinName(name, realm)
end

-- Removes colour codes and player links from a chat message.
function ns.StripCodes(text)
	if type(text) ~= "string" then
		return text
	end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("|H[^|]*|h%[?([^|%]]*)%]?|h", "%1")
	return text
end

-- Saved settings ---------------------------------------------------------------------------

-- Missing keys get their default. A class you unticked is stored as false, not nil, so the
-- defaults never tick it again.
local function fillDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			fillDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

function ns.InitDB()
	if type(EasyLFGDB) ~= "table" then
		EasyLFGDB = {}
	end
	local db = EasyLFGDB
	db.settings = type(db.settings) == "table" and db.settings or {}
	local settings = db.settings
	-- Version 2: no "ask again after" setting, answers kept for the session only, the role in
	-- the default whisper, and a time limit past the 60 s of the invite popup.
	if (db.version or 1) < 2 then
		settings.forgetMinutes = nil
		db.asked = nil
		if settings.message == OLD_DEFAULT_MESSAGE then
			settings.message = ns.DEFAULT_MESSAGE
		end
	end
	-- Version 3: auto mode invites right after an answer, so there is no delay setting.
	if (db.version or 1) < 3 then
		settings.delay = nil
	end
	db.version = 3
	fillDefaults(settings, DEFAULT_SETTINGS)
	settings.timeout = ns.Clamp(settings.timeout, ns.MIN_TIMEOUT, ns.MAX_TIMEOUT)
	-- A group that needs nobody is a leftover of emptied number boxes (fixed in 1.1.0), not a choice.
	local total = 0
	for role, defaults in pairs(DEFAULT_SETTINGS.roles) do
		-- A class that cannot play the role is never wanted for it, whatever was saved.
		for _, class in ipairs(ns.CLASSES) do
			if settings.roles[role].classes[class] and not ns.CanPlay(class, role) then
				settings.roles[role].classes[class] = false
			end
		end
		settings.roles[role].need = ns.Clamp(settings.roles[role].need, 0, ns.MAX_PARTY)
		settings.roles[role].minLevel = ns.Clamp(settings.roles[role].minLevel, 1, ns.MAX_LEVEL)
		total = total + settings.roles[role].need
	end
	if total == 0 then
		for role, defaults in pairs(DEFAULT_SETTINGS.roles) do
			settings.roles[role].need = defaults.need
		end
		ns.repairedNeeds = true
	end
	db.memberRoles = type(db.memberRoles) == "table" and db.memberRoles or {}
	db.log = type(db.log) == "table" and db.log or {}
	ns.db = db
	ns.settings = settings
	ns.ForgetOld()
	if not ns.sessionLogged then
		ns.sessionLogged = true
		ns.Log(("=== Session start %s, EasyLFG %s ==="):format(date("%Y-%m-%d"), ns.VERSION))
		for _, entry in ipairs(earlyLog) do
			ns.Log(entry.text)
		end
		earlyLog = {}
		if ns.repairedNeeds then
			ns.Log("Saved needs were 0/0/0: reset to 1 tank, 1 healer, 3 DPS")
		end
	end
end

-- Who was asked and what they answered, for this session only: a player who declined or did not
-- answer is not invited again until you reload or use "Forget".
ns.asked = {}

-- Drops the roles of people who joined long ago.
function ns.ForgetOld()
	local now = time()
	for key, record in pairs(ns.db.memberRoles) do
		if type(record) ~= "table" or not record.time or now - record.time > 12 * 3600 then
			ns.db.memberRoles[key] = nil
		end
	end
end

-- Puts the class lists back to the defaults for one role.
function ns.DefaultClasses(role)
	local set = {}
	for class in pairs(DEFAULT_SETTINGS.roles[role].classes) do
		set[class] = true
	end
	return set
end

-- Events -----------------------------------------------------------------------------------

local handlers = {}
local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

function ns.On(event, label, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], ns.Guard(label, fn))
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if list then
		for _, handler in ipairs(list) do
			handler(event, ...)
		end
	end
end)

-- Something the client refused to let EasyLFG do (a protected call without a click).
ns.blocked = {}

local function onBlocked(event, blockedAddon, functionName)
	if blockedAddon ~= addonName then
		return
	end
	local fn = tostring(functionName)
	ns.blocked[fn] = (ns.blocked[fn] or 0) + 1
	ns.Log("The game blocked " .. fn)
	if ns.blocked[fn] == 1 then
		ns.Print(("|cffff6060The game blocked %s.|r /elfg debug has the details."):format(fn))
	end
	if ns.Inviter and ns.Inviter.OnBlocked then
		ns.Inviter.OnBlocked(fn)
	end
end

ns.On("ADDON_ACTION_BLOCKED", "blocked", onBlocked)
ns.On("ADDON_ACTION_FORBIDDEN", "forbidden", onBlocked)

ns.On("ADDON_LOADED", "load", function(_, loaded)
	if loaded == addonName then
		ns.InitDB()
		if ns.OnReady then
			ns.OnReady()
		end
	end
end)
