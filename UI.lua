-- EasyLFG window: the dungeon, the rules per role, the whisper, the buttons, and the list of
-- players found in the Group Finder with what EasyLFG thinks of each.
--
-- There are two windows built the same way: the main one, and the demo one (/elfg demo only),
-- where the demo is always on: opening it starts the demo, closing it ends the demo. Only one is
-- open at a time; `frame` and `widgets` are the ones of the window in use.

local _, ns = ...

local UI = {}
ns.UI = UI

local FRAME_WIDTH, FRAME_HEIGHT = 580, 650
local ROW_HEIGHT = 20
local LIST_TOP = -392
local PARTY_WIDTH = 230 -- the group panel beside the window
local PARTY_ROW = 18

local frame
local widgets = { roles = {}, rows = {} }
local windows = {} -- "main" / "demo" -> { frame, widgets }
local current = "main"

-- Makes this window the one the drawing code works on.
local function use(kind)
	local window = windows[kind]
	if window then
		frame, widgets = window.frame, window.widgets
	end
	current = kind
end

ns.status = "Pick a dungeon, set your rules, then Search."

-- Called from anywhere: shows a new status line (or nil to keep it) and redraws.
function ns.SetStatus(message)
	if message then
		ns.status = message
	end
	ns.Refresh()
end

local guardedRefresh

function ns.Refresh()
	if frame and frame:IsShown() then
		guardedRefresh = guardedRefresh or ns.Guard("refresh", UI.Refresh)
		guardedRefresh()
	end
end

-- Widget helpers ------------------------------------------------------------------------

local function newLabel(parent, text, font)
	local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
	label:SetJustifyH("LEFT")
	label:SetText(text or "")
	return label
end

local function newButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	return button
end

local function newCheck(parent, text)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check.label = newLabel(check, text, "GameFontHighlight")
	check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
	return check
end

-- A number box that saves when you press Enter or click away.
local function newNumberBox(parent, width, low, high, get, set)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(3)
	box:SetJustifyH("CENTER")
	box.load = function(self)
		self:SetText(tostring(get()))
	end
	box:SetScript("OnEnterPressed", box.ClearFocus)
	box:SetScript("OnEscapePressed", function(self)
		self:load()
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusLost", ns.Guard("number box", function(self)
		-- An emptied box keeps its value: only a number you typed is saved.
		local typed = tonumber(self:GetText() or "")
		if typed then
			set(ns.Clamp(typed, low, high))
		end
		self:load()
		ns.Finder.Evaluate()
		ns.Refresh()
	end))
	return box
end

local function newPanel(parent)
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	panel:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0, 0, 0, 0.45)
	panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
	return panel
end

local function openMenu(owner, build)
	if not MenuUtil or not MenuUtil.CreateContextMenu then
		ns.Print("This client has no menus (MenuUtil); /elfg debug has details.")
		return
	end
	MenuUtil.CreateContextMenu(owner, ns.Guard("menu", build))
end

local function keepOpen()
	return MenuResponse and MenuResponse.Refresh or nil
end

-- Role icons as text, with letters when the atlas is missing.
local ROLE_ATLAS = {
	TANK = "groupfinder-icon-role-micro-tank",
	HEALER = "groupfinder-icon-role-micro-heal",
	DAMAGER = "groupfinder-icon-role-micro-dps",
}
local ROLE_LETTER = { TANK = "|cff6fa8ffT|r", HEALER = "|cff60ff60H|r", DAMAGER = "|cffff8060D|r" }

local function roleIcon(role)
	local atlas = ROLE_ATLAS[role]
	if CreateAtlasMarkup and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		return CreateAtlasMarkup(atlas, 14, 14)
	end
	return ROLE_LETTER[role]
end

local function rolesText(roles)
	local parts = {}
	for _, role in ipairs(ns.ROLES) do
		if roles and roles[role] then
			parts[#parts + 1] = roleIcon(role)
		end
	end
	return #parts > 0 and table.concat(parts, " ") or "|cff888888-|r"
end

-- Menus --------------------------------------------------------------------------------------

local function openDungeonMenu(owner)
	openMenu(owner, function(_, root)
		local groups = ns.Finder.ListActivities()
		if #groups == 0 then
			root:CreateTitle("The Group Finder lists nothing yet.")
			return
		end
		local function isSelected(activity)
			return ns.settings.activityID == activity.id
		end
		local function select(activity)
			ns.Finder.SetActivity(activity)
			ns.SetStatus(("Dungeon: %s. Click Search to look for players."):format(activity.name))
		end
		for _, group in ipairs(groups) do
			local parent = root
			if #groups > 1 then
				parent = root:CreateButton(group.name)
			else
				root:CreateTitle(group.name)
			end
			if parent.SetScrollMode then
				parent:SetScrollMode(480)
			end
			for _, activity in ipairs(group.activities) do
				local label = activity.name
				if activity.minLevel > 0 then
					local range = activity.maxLevel > 0 and ("%d-%d"):format(activity.minLevel, activity.maxLevel) or tostring(activity.minLevel)
					label = ("%s  |cff888888%s|r"):format(label, range)
				end
				parent:CreateRadio(label, isSelected, select, activity)
			end
		end
	end)
end

local function openMyRoleMenu(owner)
	openMenu(owner, function(_, root)
		root:CreateTitle("Your own role")
		for _, role in ipairs(ns.ROLES) do
			root:CreateRadio(ns.ROLE_LABEL[role], function(value)
				return ns.settings.myRole == value
			end, function(value)
				ns.settings.myRole = value
				ns.Finder.Evaluate()
				ns.Refresh()
			end, role)
		end
	end)
end

local function openClassMenu(owner, role)
	openMenu(owner, function(_, root)
		local rule = ns.settings.roles[role]
		root:CreateTitle(("Classes wanted as %s"):format(ns.ROLE_LABEL[role]))
		-- Only the classes able to play this role.
		for _, class in ipairs(ns.ROLE_CLASSES[role]) do
			root:CreateCheckbox(ns.Colored(ns.ClassName(class), class), function(value)
				return rule.classes[value] == true
			end, function(value)
				rule.classes[value] = not rule.classes[value]
				ns.Finder.Evaluate()
				ns.Refresh()
				return keepOpen()
			end, class)
		end
		if root.CreateDivider then
			root:CreateDivider()
		end
		root:CreateButton(role == "DAMAGER" and "All classes" or ("All %s classes"):format(ns.ROLE_WORD[role]), function()
			for _, class in ipairs(ns.ROLE_CLASSES[role]) do
				rule.classes[class] = true
			end
			ns.Finder.Evaluate()
			ns.Refresh()
		end)
		root:CreateButton("Default classes", function()
			local defaults = ns.DefaultClasses(role)
			for _, class in ipairs(ns.CLASSES) do
				rule.classes[class] = defaults[class] == true
			end
			ns.Finder.Evaluate()
			ns.Refresh()
		end)
	end)
end

local function openRowMenu(owner, c)
	openMenu(owner, function(_, root)
		root:CreateTitle(c.name or "?")
		local state = ns.Finder.state or ns.Finder.GroupState()
		local role = ns.Inviter.RoleFor(c, state)
		local fits = c.status == "match"
		local label = fits and "Invite as %s" or "Invite anyway as %s"
		local invite = root:CreateButton(label:format(ns.ROLE_LABEL[role]), function()
			local ok, message = ns.Inviter.InviteCandidate(c, role, fits and "by hand" or "by hand, outside the rules")
			if ok then
				ns.Finder.Refresh(true)
			end
			ns.SetStatus(message)
		end)
		if invite.SetEnabled then
			invite:SetEnabled(not ns.Inviter.Busy() and c.status ~= "ingroup" and c.status ~= "invited" and c.name ~= nil)
		end
		root:CreateButton("Whisper", function()
			if ChatFrameUtil and ChatFrameUtil.SendTell then
				ChatFrameUtil.SendTell(c.name)
			elseif ChatFrame_SendTell then
				ChatFrame_SendTell(c.name)
			end
		end)
		if c.key and ns.Finder.skipped[c.key] then
			root:CreateButton("Stop skipping", function()
				ns.Finder.skipped[c.key] = nil
				ns.Finder.Evaluate()
				ns.Refresh()
			end)
		elseif c.key then
			root:CreateButton("Skip this player", function()
				ns.Finder.skipped[c.key] = true
				ns.Log(("Skipped %s by hand"):format(c.name))
				ns.Finder.Evaluate()
				ns.Refresh()
			end)
		end
		if c.key and ns.Finder.AskedRecord(c.key) then
			root:CreateButton("Forget their answer", function()
				ns.asked[c.key] = nil
				ns.Log(("Forgot %s's answer by hand"):format(c.name))
				ns.Finder.Evaluate()
				ns.Refresh()
			end)
		end
	end)
end

-- Building ------------------------------------------------------------------------------------

local function classSummary(rule, role)
	local allowed = ns.ROLE_CLASSES[role]
	local names, count = {}, 0
	for _, class in ipairs(allowed) do
		if rule.classes[class] then
			count = count + 1
			names[#names + 1] = ns.Colored(ns.ClassName(class), class)
		end
	end
	if count == 0 then
		return "|cffff6060No class|r"
	elseif count == #allowed then
		return role == "DAMAGER" and "Any class" or ("Any %s class"):format(ns.ROLE_WORD[role])
	elseif count <= 3 then
		return table.concat(names, ", ")
	end
	return ("%d classes"):format(count)
end

local function buildSettings()
	local y = -44
	local dungeonLabel = newLabel(frame, "Dungeon")
	dungeonLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y - 4)
	widgets.dungeon = newButton(frame, "Choose...", 250)
	widgets.dungeon:SetPoint("TOPLEFT", frame, "TOPLEFT", 84, y)
	widgets.dungeon:SetScript("OnClick", openDungeonMenu)

	local meLabel = newLabel(frame, "I am")
	meLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 356, y - 4)
	widgets.myRole = newButton(frame, "DPS", 110)
	widgets.myRole:SetPoint("TOPLEFT", frame, "TOPLEFT", 396, y)
	widgets.myRole:SetScript("OnClick", openMyRoleMenu)

	y = -82
	local headers = { { "Role", 16 }, { "Needed", 104 }, { "Min level", 168 }, { "Classes", 250 } }
	for _, header in ipairs(headers) do
		local label = newLabel(frame, header[1], "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", frame, "TOPLEFT", header[2], y)
	end

	for index, role in ipairs(ns.ROLES) do
		local rowY = -100 - (index - 1) * 28
		local row = {}
		row.label = newLabel(frame, roleIcon(role) .. " " .. ns.ROLE_LABEL[role], "GameFontHighlight")
		row.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, rowY - 4)
		row.need = newNumberBox(frame, 30, 0, ns.MAX_PARTY, function()
			return ns.settings.roles[role].need
		end, function(value)
			ns.settings.roles[role].need = value
		end)
		row.need:SetPoint("TOPLEFT", frame, "TOPLEFT", 112, rowY)
		row.level = newNumberBox(frame, 30, 1, ns.MAX_LEVEL, function()
			return ns.settings.roles[role].minLevel
		end, function(value)
			ns.settings.roles[role].minLevel = value
		end)
		row.level:SetPoint("TOPLEFT", frame, "TOPLEFT", 180, rowY)
		row.classes = newButton(frame, "", 300)
		row.classes:SetPoint("TOPLEFT", frame, "TOPLEFT", 250, rowY)
		row.classes:SetScript("OnClick", function(self)
			openClassMenu(self, role)
		end)
		widgets.roles[role] = row
	end

	y = -186
	widgets.distinct = newCheck(frame, "Distinct classes only (no two players of the same class)")
	widgets.distinct:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, y)
	widgets.distinct:SetScript("OnClick", function(self)
		ns.settings.distinctClasses = self:GetChecked() and true or false
		ns.Finder.Evaluate()
		ns.Refresh()
	end)

	y = -214
	widgets.whisper = newCheck(frame, "Whisper first:")
	widgets.whisper:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, y)
	widgets.whisper:SetScript("OnClick", function(self)
		ns.settings.whisper = self:GetChecked() and true or false
	end)
	local message = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	message:SetSize(410, 20)
	message:SetPoint("TOPLEFT", frame, "TOPLEFT", 150, y - 2)
	message:SetAutoFocus(false)
	message:SetMaxLetters(240)
	message:SetScript("OnEnterPressed", message.ClearFocus)
	message:SetScript("OnEscapePressed", function(self)
		self:SetText(ns.settings.message or "")
		self:ClearFocus()
	end)
	message:SetScript("OnEditFocusLost", function(self)
		local text = ns.Trim(self:GetText() or "")
		ns.settings.message = text ~= "" and text or ns.DEFAULT_MESSAGE
		self:SetText(ns.settings.message)
	end)
	widgets.message = message
	local hint = newLabel(frame, "<dungeon>, <role> (tank, healer, dps) and <name> are filled in for each player.", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", message, "BOTTOMLEFT", -4, -3)

	y = -262
	local timeoutLabel = newLabel(frame, "Give up on an invite without any answer after (s)", "GameFontHighlightSmall")
	timeoutLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y - 4)
	widgets.timeout = newNumberBox(frame, 36, ns.MIN_TIMEOUT, ns.MAX_TIMEOUT, function()
		return ns.settings.timeout
	end, function(value)
		ns.settings.timeout = value
	end)
	widgets.timeout:SetPoint("TOPLEFT", frame, "TOPLEFT", 330, y)
end

local function buildActions()
	local y = -298
	widgets.search = newButton(frame, "Search", 100)
	widgets.search:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y)
	widgets.search:SetScript("OnClick", ns.Guard("search", function()
		local _, message = ns.Finder.Search()
		ns.SetStatus(message)
	end))

	-- Inviting by hand is the + button on each player's row.
	widgets.auto = newButton(frame, "Start auto", 110)
	widgets.auto:SetPoint("LEFT", widgets.search, "RIGHT", 8, 0)
	widgets.auto:SetScript("OnClick", ns.Guard("auto", function()
		local _, message
		if ns.Inviter.auto then
			_, message = ns.Inviter.Stop()
		else
			_, message = ns.Inviter.Start()
		end
		ns.SetStatus(message)
	end))

	widgets.group = newLabel(frame, "", "GameFontHighlightSmall")
	widgets.group:SetPoint("LEFT", widgets.auto, "RIGHT", 12, 0)
	widgets.group:SetPoint("RIGHT", frame, "RIGHT", -16, 0)

	widgets.status = newLabel(frame, "", "GameFontHighlight")
	widgets.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y - 32)
	widgets.status:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	widgets.status:SetHeight(30)
	widgets.status:SetJustifyV("TOP")

	widgets.listTitle = newLabel(frame, "", "GameFontNormal")
	widgets.listTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, LIST_TOP + 22)
	widgets.listTitle:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
end

local function createRow(content, index)
	local row = CreateFrame("Button", nil, content)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	-- The + button: whisper and invite this player now.
	local invite = CreateFrame("Button", nil, row)
	invite:SetSize(16, 16)
	invite:SetPoint("LEFT", row, "LEFT", 4, 0)
	invite:SetFrameLevel(row:GetFrameLevel() + 2)
	invite:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
	invite:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
	invite:SetDisabledTexture("Interface\\Buttons\\UI-PlusButton-Disabled")
	invite:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
	invite:SetScript("OnClick", ns.Guard("row invite", function(self)
		local c = self:GetParent().candidate
		if c then
			local _, message = ns.Inviter.InviteFromRow(c)
			ns.SetStatus(message)
		end
	end))
	-- Shown on a disabled button too, so you can see why it is off.
	invite:SetMotionScriptsWhileDisabled(true)
	invite:SetScript("OnEnter", function(self)
		local c = self:GetParent().candidate
		if not c then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self:IsEnabled() then
			GameTooltip:AddLine(("Invite %s as %s"):format(c.name, ns.ROLE_LABEL[self.role] or "?"), 1, 1, 1)
			if ns.settings.whisper then
				GameTooltip:AddLine(('Whisper: "%s"'):format(ns.Inviter.FormatMessage(c, self.role)), 0.7, 0.9, 1, true)
			end
		else
			GameTooltip:AddLine(self.why or "Cannot invite now.", 1, 0.6, 0.4, true)
		end
		GameTooltip:Show()
	end)
	invite:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	row.invite = invite

	row.name = newLabel(row, "", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row, "LEFT", 26, 0)
	row.name:SetWidth(140)
	row.name:SetWordWrap(false)
	row.level = newLabel(row, "", "GameFontHighlightSmall")
	row.level:SetPoint("LEFT", row, "LEFT", 170, 0)
	row.level:SetWidth(28)
	row.roles = newLabel(row, "", "GameFontHighlightSmall")
	row.roles:SetPoint("LEFT", row, "LEFT", 202, 0)
	row.roles:SetWidth(56)
	row.reason = newLabel(row, "", "GameFontHighlightSmall")
	row.reason:SetPoint("LEFT", row, "LEFT", 262, 0)
	row.reason:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.reason:SetWordWrap(false)

	row:SetScript("OnClick", function(self)
		if self.candidate then
			openRowMenu(self, self.candidate)
		end
	end)
	row:SetScript("OnEnter", function(self)
		local c = self.candidate
		if not c then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(c.class and ns.Colored(c.name or "?", c.class) or (c.name or "?"))
		if c.level and c.class then
			GameTooltip:AddLine(("Level %d %s"):format(c.level, ns.ClassName(c.class)), 1, 1, 1)
		end
		if c.area then
			GameTooltip:AddLine(c.area, 0.7, 0.7, 0.7)
		end
		if type(c.comment) == "string" and c.comment ~= "" then
			GameTooltip:AddLine(c.comment, 0.9, 0.9, 0.6, true)
		end
		GameTooltip:AddLine(c.reason or "", 0.6, 0.8, 1, true)
		GameTooltip:AddLine("+ invites. Click the row for more options.", 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return row
end

local function buildList()
	local panel = newPanel(frame)
	panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, LIST_TOP)
	panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 14)

	local headers = { { "Player", 30 }, { "Lvl", 174 }, { "Roles", 206 }, { "Status", 266 } }
	for _, header in ipairs(headers) do
		local label = newLabel(panel, header[1], "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", panel, "TOPLEFT", header[2], -8)
	end

	local scroll = CreateFrame("ScrollFrame", (current == "demo" and "EasyLFGDemo" or "EasyLFG") .. "ListScroll", panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -24)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 6)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(FRAME_WIDTH - 66, ROW_HEIGHT)
	scroll:SetScrollChild(content)
	widgets.scroll = scroll
	widgets.content = content

	widgets.empty = newLabel(panel, "", "GameFontDisable")
	widgets.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -34)
	widgets.empty:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
	widgets.empty:SetJustifyV("TOP")
end

-- The group being formed: a small panel beside the window, one line per seat.
local function buildParty()
	local panel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	panel:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	panel:SetBackdropColor(0.06, 0.06, 0.09, 0.96)
	panel:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	panel:SetSize(PARTY_WIDTH, 40 + ns.MAX_PARTY * PARTY_ROW)
	panel:EnableMouse(true)
	widgets.party = panel

	widgets.partyTitle = newLabel(panel, "Group", "GameFontNormal")
	widgets.partyTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -12)
	widgets.partyTitle:SetPoint("RIGHT", panel, "RIGHT", -12, 0)

	widgets.partyRows = {}
	for index = 1, ns.MAX_PARTY + 2 do
		local row = CreateFrame("Frame", nil, panel)
		row:SetHeight(PARTY_ROW)
		row:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -32 - (index - 1) * PARTY_ROW)
		row:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
		row.role = newLabel(row, "", "GameFontHighlightSmall")
		row.role:SetPoint("LEFT", row, "LEFT", 0, 0)
		row.role:SetWidth(18)
		row.name = newLabel(row, "", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row, "LEFT", 20, 0)
		row.name:SetWidth(112)
		row.name:SetWordWrap(false)
		row.state = newLabel(row, "", "GameFontHighlightSmall")
		row.state:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		row.state:SetWidth(78)
		row.state:SetJustifyH("RIGHT")
		row:Hide()
		widgets.partyRows[index] = row
	end
end

-- Beside the window on the right, or on the left when the screen has no room there.
local function placeParty()
	local panel = widgets.party
	local right = frame:GetRight()
	local screen = UIParent:GetRight()
	local side = (right and screen and right + PARTY_WIDTH > screen) and "LEFT" or "RIGHT"
	if panel.side ~= side then
		panel.side = side
		panel:ClearAllPoints()
		if side == "RIGHT" then
			panel:SetPoint("TOPLEFT", frame, "TOPRIGHT", -2, 0)
		else
			panel:SetPoint("TOPRIGHT", frame, "TOPLEFT", 2, 0)
		end
	end
end

local POSITION_KEY = { main = "window", demo = "demoWindow" }

local function restorePosition(kind)
	frame:ClearAllPoints()
	local saved = ns.db and ns.db[POSITION_KEY[kind]]
	if type(saved) == "table" and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x or 0, saved.y or 0)
	else
		frame:SetPoint("CENTER")
	end
end

local FRAME_NAME = { main = "EasyLFGFrame", demo = "EasyLFGDemoFrame" }

local function build(kind)
	widgets = { roles = {}, rows = {} }
	frame = CreateFrame("Frame", FRAME_NAME[kind], UIParent, "BackdropTemplate")
	windows[kind] = { frame = frame, widgets = widgets }
	current = kind
	frame:Hide()
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint()
		ns.db[POSITION_KEY[kind]] = { point = point, relativePoint = relativePoint, x = x, y = y }
		placeParty()
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.06, 0.06, 0.09, 0.96)
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	restorePosition(kind)

	local title = newLabel(frame, "EasyLFG", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
	local version = newLabel(frame, "v" .. ns.VERSION, "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 8, -1)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)

	local logButton = newButton(frame, "Log", 60)
	logButton:SetPoint("RIGHT", close, "LEFT", -4, 0)
	logButton:SetScript("OnClick", function()
		ns.LogWindow.Toggle()
	end)
	widgets.log = logButton

	if kind == "demo" then
		local banner = newLabel(frame, "|cffff9900DEMO|r |cffffd0a0made-up players, nothing is sent to the game|r", "GameFontNormal")
		banner:SetPoint("LEFT", version, "RIGHT", 12, 1)
		widgets.demoBanner = banner
		frame:SetBackdropBorderColor(1, 0.6, 0.1, 1)
		-- Closing the demo window (button, Escape, /elfg demo) ends the demo.
		frame:SetScript("OnHide", ns.Guard("demo window closed", function()
			if ns.Demo.active then
				ns.Demo.Stop()
			end
		end))
	end

	buildSettings()
	buildActions()
	buildList()
	buildParty()

	-- A countdown while an invite waits; cheap, and only while the window is open.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= 1 then
			elapsed = 0
			if next(ns.Inviter.pending) then
				UI.RefreshStatus()
				UI.RefreshParty()
			end
		end
	end)
	-- Opening the window reads the group and its roles afresh, then the list. Each step is
	-- guarded on its own, so one surprise from the client cannot leave the rest blank.
	frame:SetScript("OnShow", function()
		ns.Guard("show: group", ns.Finder.Evaluate)()
		ns.Guard("show: list", ns.Finder.Scan)()
		ns.Guard("show: refresh", UI.Refresh)()
		-- While the window is open, missing roles are searched for until someone is listed.
		ns.Inviter.StartRefreshTicker()
	end)

	tinsert(UISpecialFrames, FRAME_NAME[kind])
end

-- Refreshing --------------------------------------------------------------------------------

local STATUS_COLOR = {
	match = "|cff60ff60",
	invited = "|cffffd100",
	nofit = "|cffc0a080",
	asked = "|cffff7070",
	skipped = "|cff909090",
	delisted = "|cff707070",
	ingroup = "|cff80c0ff",
	hidden = "|cff707070",
}

function UI.RefreshStatus()
	local text = ns.status or ""
	local limit = ns.Clamp(ns.settings.timeout, ns.MIN_TIMEOUT, ns.MAX_TIMEOUT)
	local waiting = {}
	for _, role in ipairs(ns.ROLES) do
		local p = ns.Inviter.pending[role]
		if p then
			local left = math.max(0, limit - math.floor(GetTime() - p.sentAt))
			waiting[#waiting + 1] = ("%s %s (%d s)"):format(roleIcon(role), ns.Colored(p.name, p.class), left)
		end
	end
	if #waiting > 0 then
		text = "Waiting for " .. table.concat(waiting, ", ")
	end
	widgets.status:SetText(text)
end

-- "Tank 1/1  Healer 0/1  DPS 2/3": in the group (invites waiting included) / wanted. Green when
-- the role is filled, red when it has more than wanted.
local function refreshGroup()
	local state = ns.Finder.GroupState()
	local parts = {}
	for _, role in ipairs(ns.ROLES) do
		local need = ns.settings.roles[role].need
		local have = state.filled[role]
		local color = have > need and "|cffff6060" or (have == need and "|cff60ff60" or "|cffffffff")
		parts[#parts + 1] = ("%s %s%d/%d|r"):format(roleIcon(role), color, have, need)
	end
	local text = table.concat(parts, "  ")
	if state.unknownRoles > 0 then
		text = text .. ("  |cff888888(%d unknown = DPS)|r"):format(state.unknownRoles)
	end
	widgets.group:SetText(text)
end

-- The seats of the group being formed, tanks first, then healers, then DPS: you, the members,
-- the invites waiting for an answer, then the seats still open. Each is { role, name, class,
-- kind, left }, kind being "you", "ingroup", "joining", "invited" or "open"; `left` is the
-- seconds an invite still has.
function UI.GroupSlots(state)
	state = state or ns.Finder.GroupState()
	local byRole = { TANK = {}, HEALER = {}, DAMAGER = {} }
	local myRole = ns.ROLE_LABEL[ns.settings.myRole] and ns.settings.myRole or "DAMAGER"
	byRole[myRole][1] = { role = myRole, name = ns.ReadUnitName("player") or "You",
		class = ns.Game.UnitClass("player"), kind = "you" }
	for _, member in ipairs(state.members) do
		local list = byRole[member.role] or byRole.DAMAGER
		list[#list + 1] = { role = member.role, name = member.name, class = member.class,
			kind = member.joining and "joining" or "ingroup", guessed = not member.known }
	end
	local limit = ns.Clamp(ns.settings.timeout, ns.MIN_TIMEOUT, ns.MAX_TIMEOUT)
	for role, invite in pairs(state.pending) do
		local list = byRole[role]
		list[#list + 1] = { role = role, name = invite.name, class = invite.class, kind = "invited",
			left = math.max(0, limit - math.floor(GetTime() - invite.sentAt)) }
	end
	-- Open seats, as many as still wanted and as the group has room for.
	local free = state.free
	for _, role in ipairs(ns.ROLES) do
		for _ = 1, state.remaining[role] do
			if free <= 0 then
				break
			end
			free = free - 1
			local list = byRole[role]
			list[#list + 1] = { role = role, kind = "open" }
		end
	end
	local slots = {}
	for _, role in ipairs(ns.ROLES) do
		for _, slot in ipairs(byRole[role]) do
			slots[#slots + 1] = slot
		end
	end
	return slots
end

local SLOT_STATE = {
	you = "|cff909090you|r",
	ingroup = "|cff60ff60in group|r",
	joining = "|cff80c0ffjoining|r",
	open = "|cff707070open|r",
}

function UI.RefreshParty()
	if not widgets.party then
		return
	end
	placeParty()
	local state = ns.Finder.GroupState()
	local slots = UI.GroupSlots(state)
	for index, row in ipairs(widgets.partyRows) do
		local slot = slots[index]
		if slot then
			local icon = roleIcon(slot.role) or ""
			if slot.kind == "open" then
				row.role:SetText(icon)
				row.role:SetAlpha(0.4)
				row.name:SetText(("|cff707070%s wanted|r"):format(ns.ROLE_LABEL[slot.role]))
			else
				row.role:SetText(icon)
				row.role:SetAlpha(1)
				local name = (tostring(slot.name):gsub("%-", " "))
				row.name:SetText(slot.class and ns.Colored(name, slot.class) or name)
			end
			if slot.kind == "invited" then
				row.state:SetText(("|cffffd100invited %d s|r"):format(slot.left or 0))
			elseif slot.kind == "ingroup" and slot.guessed then
				row.state:SetText("|cff60ff60in group|r |cff888888(?)|r")
			else
				row.state:SetText(SLOT_STATE[slot.kind] or "")
			end
			row.slot = slot
			row:Show()
		else
			row.slot = nil
			row:Hide()
		end
	end
	local title = ("Group %d/%d"):format(state.size, ns.MAX_PARTY)
	if state.complete then
		title = title .. "  |cff60ff60complete|r"
	elseif ns.Inviter.auto then
		title = title .. "  |cffffd100auto|r"
	end
	if ns.Demo.active then
		title = title .. "  |cffff9900demo|r"
	end
	widgets.partyTitle:SetText(title)
end

local function refreshList()
	local list = ns.Finder.candidates
	local stats = ns.Finder.stats or {}
	for index, c in ipairs(list) do
		local row = widgets.rows[index] or createRow(widgets.content, index)
		widgets.rows[index] = row
		row.candidate = c
		row.name:SetText(c.class and ns.Colored(c.name or "?", c.class) or (c.name or "?"))
		row.level:SetText(c.level and tostring(c.level) or "?")
		row.roles:SetText(rolesText(c.roles))
		row.reason:SetText((STATUS_COLOR[c.status] or "|cffffffff") .. (c.reason or "") .. "|r")
		local canInvite, role, why = ns.Inviter.RowInvite(c)
		row.invite:SetEnabled(canInvite)
		row.invite:SetAlpha(canInvite and 1 or 0.35)
		row.invite.role, row.invite.why = role, why
		row:Show()
	end
	for index = #list + 1, #widgets.rows do
		widgets.rows[index].candidate = nil
		widgets.rows[index]:Hide()
	end
	widgets.content:SetHeight(math.max(ROW_HEIGHT, #list * ROW_HEIGHT))

	local title = ns.Demo.active and "Made-up players listed alone (demo)" or "Players listed alone for this dungeon"
	if #list > 0 then
		title = ("%s: %d, |cff60ff60%d match|r"):format(title, #list, stats.eligible or 0)
	end
	widgets.listTitle:SetText(title)

	local empty = ""
	if #list == 0 then
		if not ns.settings.activityID then
			empty = "Choose a dungeon above."
		elseif ns.Finder.searching then
			empty = "Searching..."
		elseif not ns.Finder.lastResultsAt then
			empty = "Click Search. Searches made in Blizzard's Group Finder show up here too."
		else
			empty = ("Nobody is listed alone for %s right now (%d listings seen, %d groups, %d for other dungeons)."):format(
				ns.settings.activityName or "this dungeon", stats.results or 0, stats.groups or 0, stats.otherActivity or 0)
		end
	end
	widgets.empty:SetText(empty)
	widgets.empty:SetShown(#list == 0)
end

function UI.Refresh()
	if not frame then
		return
	end
	local s = ns.settings
	widgets.dungeon:SetText(s.activityName or "Choose...")
	widgets.myRole:SetText(roleIcon(s.myRole) .. " " .. (ns.ROLE_LABEL[s.myRole] or "DPS"))
	for _, role in ipairs(ns.ROLES) do
		local row = widgets.roles[role]
		if not row.need:HasFocus() then
			row.need:load()
		end
		if not row.level:HasFocus() then
			row.level:load()
		end
		row.classes:SetText(classSummary(s.roles[role], role))
	end
	if not widgets.timeout:HasFocus() then
		widgets.timeout:load()
	end
	widgets.distinct:SetChecked(s.distinctClasses == true)
	widgets.whisper:SetChecked(s.whisper == true)
	if not widgets.message:HasFocus() then
		widgets.message:SetText(s.message or "")
	end
	-- No dungeon, no search and no invite.
	local hasDungeon = s.activityID ~= nil
	widgets.auto:SetEnabled(hasDungeon or ns.Inviter.auto)
	widgets.search:SetEnabled(hasDungeon and not ns.Finder.searching)
	widgets.auto:SetText(ns.Inviter.auto and "Stop auto" or "Start auto")
	refreshGroup()
	UI.RefreshStatus()
	UI.RefreshParty()
	refreshList()
end

-- Public --------------------------------------------------------------------------------------

local function shown(kind)
	return windows[kind] ~= nil and windows[kind].frame:IsShown()
end

local function hide(kind)
	if shown(kind) then
		windows[kind].frame:Hide() -- the demo window ends the demo as it closes
	end
end

-- Opens a window, closing the other one first.
local function open(kind)
	hide(kind == "main" and "demo" or "main")
	if windows[kind] then
		use(kind)
	else
		build(kind)
	end
	frame:Show()
end

function UI.Show()
	open("main")
end

function UI.Toggle()
	if current == "main" and shown("main") then
		hide("main")
	else
		UI.Show()
	end
end

-- /elfg demo: opens the demo window, which starts the demo; again closes it, which ends it.
function UI.ToggleDemo()
	if shown("demo") then
		hide("demo")
		use("main")
		return true, "Demo ended."
	end
	hide("main")
	local ok, message = ns.Demo.Start()
	if not ok then
		return false, message
	end
	open("demo")
	return true, message
end

function UI.IsDemoShown()
	return shown("demo")
end

function UI.IsShown()
	return frame ~= nil and frame:IsShown()
end
