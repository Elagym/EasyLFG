-- EasyLFG log window: every action the addon took, oldest at the top, newest at the bottom. The
-- text can be selected and copied (Select all, then Ctrl+C) but not edited.

local _, ns = ...

local LogWindow = {}
ns.LogWindow = LogWindow

local WIDTH, HEIGHT = 680, 440

local frame, scroll, editBox, countLabel
local shownText = ""
local refreshQueued = false

local function logText()
	local lines = {}
	for _, entry in ipairs(ns.db and ns.db.log or {}) do
		lines[#lines + 1] = ns.LogLine(entry)
	end
	return table.concat(lines, "\n")
end

local function scrollToEnd()
	C_Timer.After(0, function()
		if scroll and scroll.GetVerticalScrollRange then
			scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
		end
	end)
end

function LogWindow.Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	shownText = logText()
	editBox:SetText(shownText)
	local count = ns.db and #ns.db.log or 0
	countLabel:SetText(("%d lines (the last %d are kept, also after a reload)"):format(count, ns.LOG_LIMIT))
	scrollToEnd()
end

-- Many lines can arrive at once (a round of invites); one redraw a moment later covers them.
function ns.OnLogChanged()
	if refreshQueued or not frame or not frame:IsShown() then
		return
	end
	refreshQueued = true
	C_Timer.After(0.2, ns.Guard("log refresh", function()
		refreshQueued = false
		LogWindow.Refresh()
	end))
end

local function newButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	return button
end

local function build()
	frame = CreateFrame("Frame", "EasyLFGLogFrame", UIParent, "BackdropTemplate")
	frame:Hide()
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint()
		ns.db.logWindow = { point = point, relativePoint = relativePoint, x = x, y = y }
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	local saved = ns.db and ns.db.logWindow
	if type(saved) == "table" and saved.point then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x or 0, saved.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 40, -40)
	end

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
	title:SetText("EasyLFG log")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)

	scroll = CreateFrame("ScrollFrame", "EasyLFGLogScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -44)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 46)

	editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetAutoFocus(false)
	editBox:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
	editBox:SetWidth(WIDTH - 60)
	editBox:SetTextInsets(2, 2, 2, 2)
	-- Read only: anything typed is undone, selecting and copying still work.
	editBox:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(shownText)
		end
	end)
	editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
	scroll:SetScrollChild(editBox)

	local selectAll = newButton(frame, "Select all", 100)
	selectAll:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 14)
	selectAll:SetScript("OnClick", function()
		editBox:SetFocus()
		editBox:HighlightText()
	end)

	local clear = newButton(frame, "Clear", 80)
	clear:SetPoint("LEFT", selectAll, "RIGHT", 8, 0)
	clear:SetScript("OnClick", function()
		ns.ClearLog()
		ns.Log("Log cleared")
		LogWindow.Refresh()
	end)

	countLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	countLabel:SetPoint("LEFT", clear, "RIGHT", 12, 0)
	countLabel:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	countLabel:SetJustifyH("LEFT")

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -36, -18)
	hint:SetText("Select all, then Ctrl+C to copy")

	frame:SetScript("OnShow", ns.Guard("log window", LogWindow.Refresh))
	tinsert(UISpecialFrames, "EasyLFGLogFrame")
end

function LogWindow.Show()
	if not frame then
		build()
	end
	frame:Show()
end

function LogWindow.Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		LogWindow.Show()
	end
end

function LogWindow.IsShown()
	return frame ~= nil and frame:IsShown()
end

function LogWindow.Text()
	return shownText
end
