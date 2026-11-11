-- EasyLFG window: the dungeon, the rules per role, the whisper, the buttons, and the list of
-- players found in the Group Finder with what EasyLFG thinks of each.

local _, ns = ...

local UI = {}
ns.UI = UI

local FRAME_WIDTH, FRAME_HEIGHT = 580, 650
local ROW_HEIGHT = 20
local LIST_TOP = -392

local frame
local widgets = { roles = {}, rows = {} }

ns.status = "Pick a dungeon, set your rules, then Search."

-- Called from anywhere: shows a new status line (or nil to keep it) and redraws.
function ns.SetStatus(message)
	if message then
		ns.status = message
	end
	ns.Refresh()
end

function ns.Refresh()
	if frame and frame:IsShown() then
		UI.Refresh()
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
		set(ns.Clamp(self:GetText(), low, high))
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
		for _, class in ipairs(ns.CLASSES) do
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
		root:CreateButton("All classes", function()
			for _, class in ipairs(ns.CLASSES) do
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
		local invite = root:CreateButton("Invite now", function()
			local _, message = ns.Inviter.InviteCandidate(c)
			ns.SetStatus(message)
		end)
		if invite.SetEnabled then
			invite:SetEnabled(ns.Inviter.pending == nil and c.status ~= "ingroup" and c.name ~= nil)
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
				ns.Finder.Evaluate()
				ns.Refresh()
			end)
		end
		if c.key and ns.Finder.AskedRecord(c.key) then
			root:CreateButton("Forget their answer", function()
				ns.db.asked[c.key] = nil
				ns.Finder.Evaluate()
				ns.Refresh()
			end)
		end
	end)
end

-- Building ------------------------------------------------------------------------------------

local function classSummary(rule)
	local names, count = {}, 0
	for _, class in ipairs(ns.CLASSES) do
		if rule.classes[class] then
			count = count + 1
			names[#names + 1] = ns.Colored(ns.ClassName(class), class)
		end
	end
	if count == 0 then
		return "|cffff6060No class|r"
	elseif count == #ns.CLASSES then
		return "Any class"
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
	local hint = newLabel(frame, "<dungeon>, <role> and <name> are filled in for each player.", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", message, "BOTTOMLEFT", -4, -3)

	y = -262
	local delayLabel = newLabel(frame, "Seconds between invites", "GameFontHighlightSmall")
	delayLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y - 4)
	widgets.delay = newNumberBox(frame, 30, 1, 60, function()
		return ns.settings.delay
	end, function(value)
		ns.settings.delay = value
	end)
	widgets.delay:SetPoint("TOPLEFT", frame, "TOPLEFT", 166, y)
	local timeoutLabel = newLabel(frame, "Wait for an answer (s)", "GameFontHighlightSmall")
	timeoutLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 222, y - 4)
	widgets.timeout = newNumberBox(frame, 30, 10, 120, function()
		return ns.settings.timeout
	end, function(value)
		ns.settings.timeout = value
	end)
	widgets.timeout:SetPoint("TOPLEFT", frame, "TOPLEFT", 362, y)
	local forgetLabel = newLabel(frame, "Ask again after (min)", "GameFontHighlightSmall")
	forgetLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 412, y - 4)
	widgets.forget = newNumberBox(frame, 30, 1, 600, function()
		return ns.settings.forgetMinutes
	end, function(value)
		ns.settings.forgetMinutes = value
	end)
	widgets.forget:SetPoint("TOPLEFT", frame, "TOPLEFT", 540, y)
end

local function buildActions()
	local y = -298
	widgets.search = newButton(frame, "Search", 100)
	widgets.search:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, y)
	widgets.search:SetScript("OnClick", ns.Guard("search", function()
		local _, message = ns.Finder.Search()
		ns.SetStatus(message)
	end))

	widgets.next = newButton(frame, "Invite next", 110)
	widgets.next:SetPoint("LEFT", widgets.search, "RIGHT", 8, 0)
	widgets.next:SetScript("OnClick", ns.Guard("invite next", function()
		local _, message = ns.Inviter.InviteNext(true)
		ns.SetStatus(message)
	end))

	widgets.auto = newButton(frame, "Start auto", 110)
	widgets.auto:SetPoint("LEFT", widgets.next, "RIGHT", 8, 0)
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

	row.name = newLabel(row, "", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
	row.name:SetWidth(150)
	row.name:SetWordWrap(false)
	row.level = newLabel(row, "", "GameFontHighlightSmall")
	row.level:SetPoint("LEFT", row, "LEFT", 160, 0)
	row.level:SetWidth(28)
	row.roles = newLabel(row, "", "GameFontHighlightSmall")
	row.roles:SetPoint("LEFT", row, "LEFT", 192, 0)
	row.roles:SetWidth(56)
	row.reason = newLabel(row, "", "GameFontHighlightSmall")
	row.reason:SetPoint("LEFT", row, "LEFT", 252, 0)
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
		GameTooltip:AddLine("Click for options.", 0.5, 0.5, 0.5)
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

	local headers = { { "Player", 10 }, { "Lvl", 164 }, { "Roles", 196 }, { "Status", 256 } }
	for _, header in ipairs(headers) do
		local label = newLabel(panel, header[1], "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", panel, "TOPLEFT", header[2], -8)
	end

	local scroll = CreateFrame("ScrollFrame", "EasyLFGListScroll", panel, "UIPanelScrollFrameTemplate")
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

local function restorePosition()
	frame:ClearAllPoints()
	local saved = ns.db and ns.db.window
	if type(saved) == "table" and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x or 0, saved.y or 0)
	else
		frame:SetPoint("CENTER")
	end
end

local function build()
	frame = CreateFrame("Frame", "EasyLFGFrame", UIParent, "BackdropTemplate")
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
		ns.db.window = { point = point, relativePoint = relativePoint, x = x, y = y }
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.06, 0.06, 0.09, 0.96)
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	restorePosition()

	local title = newLabel(frame, "EasyLFG", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
	local version = newLabel(frame, "v" .. ns.VERSION, "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 8, -1)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)

	buildSettings()
	buildActions()
	buildList()

	-- A countdown while an invite waits; cheap, and only while the window is open.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= 1 then
			elapsed = 0
			if ns.Inviter.pending or ns.Inviter.nextAt then
				UI.RefreshStatus()
			end
		end
	end)
	frame:SetScript("OnShow", ns.Guard("show", function()
		ns.Finder.Scan()
		UI.Refresh()
	end))

	tinsert(UISpecialFrames, "EasyLFGFrame")
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
	local p = ns.Inviter.pending
	if p then
		local waited = math.floor(GetTime() - p.sentAt)
		local limit = ns.Clamp(ns.settings.timeout, 10, 120)
		text = ("Waiting for %s to answer (%d s left)."):format(ns.Colored(p.name, p.class), math.max(0, limit - waited))
	elseif ns.Inviter.nextAt then
		text = ("Next invite in %d s."):format(math.max(0, math.ceil(ns.Inviter.nextAt - GetTime())))
	end
	widgets.status:SetText(text)
end

local function refreshGroup()
	local state = ns.Finder.state or ns.Finder.GroupState()
	local parts = {}
	for _, role in ipairs(ns.ROLES) do
		local need = ns.settings.roles[role].need
		local have = math.min(state.filled[role], need)
		local color = have >= need and "|cff60ff60" or "|cffffffff"
		parts[#parts + 1] = ("%s %s%d/%d|r"):format(roleIcon(role), color, have, need)
	end
	local text = table.concat(parts, "  ")
	if state.unknownRoles > 0 then
		text = text .. ("  |cff888888(%d as DPS?)|r"):format(state.unknownRoles)
	end
	widgets.group:SetText(text)
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
		row:Show()
	end
	for index = #list + 1, #widgets.rows do
		widgets.rows[index].candidate = nil
		widgets.rows[index]:Hide()
	end
	widgets.content:SetHeight(math.max(ROW_HEIGHT, #list * ROW_HEIGHT))

	local title = "Players listed alone for this dungeon"
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
		row.classes:SetText(classSummary(s.roles[role]))
	end
	for _, box in ipairs({ widgets.delay, widgets.timeout, widgets.forget }) do
		if not box:HasFocus() then
			box:load()
		end
	end
	widgets.distinct:SetChecked(s.distinctClasses == true)
	widgets.whisper:SetChecked(s.whisper == true)
	if not widgets.message:HasFocus() then
		widgets.message:SetText(s.message or "")
	end
	widgets.next:SetEnabled(ns.Inviter.pending == nil)
	widgets.search:SetEnabled(not ns.Finder.searching)
	widgets.auto:SetText(ns.Inviter.auto and "Stop auto" or "Start auto")
	refreshGroup()
	UI.RefreshStatus()
	refreshList()
end

-- Public --------------------------------------------------------------------------------------

function UI.Show()
	if not frame then
		build()
	end
	frame:Show()
end

function UI.Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		UI.Show()
	end
end

function UI.IsShown()
	return frame ~= nil and frame:IsShown()
end
