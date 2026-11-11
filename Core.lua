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

ns.DEFAULT_MESSAGE = "Hi, do you wanna join for <dungeon> ?"

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
	delay = 5, -- seconds between two invites in auto mode
	timeout = 60, -- seconds to wait for an answer before moving on
	forgetMinutes = 30, -- a player who said no is not asked again for this long
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

-- Runs a handler protected: one error is announced once and kept for /elfg debug, so a client
-- surprise can never break the rest or spam the chat.
function ns.Guard(label, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			ns.lastError = label .. ": " .. tostring(err)
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
	db.version = 1
	db.settings = type(db.settings) == "table" and db.settings or {}
	fillDefaults(db.settings, DEFAULT_SETTINGS)
	db.asked = type(db.asked) == "table" and db.asked or {}
	db.memberRoles = type(db.memberRoles) == "table" and db.memberRoles or {}
	ns.db = db
	ns.settings = db.settings
	ns.ForgetOld()
end

-- Drops what is too old to matter: answers past the memory window, roles of people long gone.
function ns.ForgetOld()
	local now = time()
	local window = (ns.settings.forgetMinutes or 30) * 60
	for key, record in pairs(ns.db.asked) do
		if type(record) ~= "table" or not record.time or now - record.time > math.max(window, 3600) then
			ns.db.asked[key] = nil
		end
	end
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
