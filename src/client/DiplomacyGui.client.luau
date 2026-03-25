-- LocalScript inside DiplomacyGui
local DEBUG = false
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Mouse = Players.LocalPlayer:GetMouse()

-- Get reference to EuropeMap
local EuropeMap = Workspace:WaitForChild("EuropeMap", 10)

-- 1. WAIT FOR JOIN SUCCESS
local JoinSuccess = ReplicatedStorage:WaitForChild("JoinSuccess", 10)
local gui = script.Parent
gui.Enabled = false -- Keep it off until we join

JoinSuccess.Event:Connect(function()
	gui.Enabled = true -- Turn on the war/alliance buttons
	if DEBUG then print("Diplomacy GUI Activated!") end
end)

-- 2. GET REMOTES
-- Wait longer for server-created RemoteEvents
local DiplomacyRequest = ReplicatedStorage:WaitForChild("DiplomacyRequest", 30)
local DiplomacyResponse = ReplicatedStorage:WaitForChild("DiplomacyResponse", 30)
local DeclareWarEvent = ReplicatedStorage:WaitForChild("DeclareWarEvent", 10)
local SendRequestEvent = ReplicatedStorage:WaitForChild("SendRequestEvent", 10)
local BreakAllianceEvent = ReplicatedStorage:WaitForChild("BreakAllianceEvent", 10)
local DiplomacyReminderEvent = ReplicatedStorage:WaitForChild("DiplomacyReminderEvent", 10)

if not DiplomacyRequest then
	warn("[DiplomacyGui] DiplomacyRequest RemoteEvent not found!")
	return
end

if not DiplomacyResponse then
	warn("[DiplomacyGui] DiplomacyResponse RemoteEvent not found!")
	return
end

-- 3. UI REFERENCES
local warPanel = gui:WaitForChild("WarPanel", 10)
local popup = gui:WaitForChild("RequestPopup", 10)

-- Buttons inside WarPanel
local declareWarBtn = warPanel:WaitForChild("DeclareWar", 10)
local allianceBtn = warPanel:WaitForChild("FormAlliance", 10)
local peaceBtn = warPanel:WaitForChild("SignPeace", 10)
local breakAllianceBtn = warPanel:WaitForChild("BreakAlliance", 10)

-- Popup Elements
local messageLabel = popup:WaitForChild("Message", 10)
local acceptBtn = popup:WaitForChild("ButtonContainer", 10).AcceptButton
local declineBtn = popup:WaitForChild("ButtonContainer", 10).DeclineButton

-- ReminderPopup Elements
local reminderPopup = gui:WaitForChild("ReminderPopup", 10)
local reminderMessage = reminderPopup:WaitForChild("Message", 10)
local reminderOkayBtn = reminderPopup:WaitForChild("ButtonContainer", 10):WaitForChild("OkayButton", 10)

-- STATE VARIABLE (Prevents multiple clicks stacking up)
local currentConnection = nil

-- Returns the effective owner of a tile.
-- OwnerCountry is set on BOTH capture and annexation (server-side).
-- BasePart attributes replicate to clients automatically.
local function getCountryFromPart(part)
	if not part or not part:IsA("BasePart") then return nil end

	-- Check OwnerCountry attribute first (set on captured/annexed tiles)
	local ownerAttr = part:GetAttribute("OwnerCountry")
	if ownerAttr and ownerAttr ~= "" then
		return ownerAttr
	end

	-- Fallback: walk hierarchy (tile was never captured/annexed)
	local current = part.Parent
	while current and current ~= EuropeMap and current ~= Workspace do
		if current.Parent == EuropeMap then
			return current.Name
		end
		current = current.Parent
	end
	return nil
end

-- HELPER: Function to handle map clicking
local function startMapSelection(actionType, specificEvent)
	-- If we were already selecting something, stop that first
	if currentConnection then currentConnection:Disconnect() end

	if DEBUG then print("Select a country on the map for: " .. actionType) end

	currentConnection = Mouse.Button1Down:Connect(function()
		local target = Mouse.Target

		-- Use robust country detection that handles nested parts
		local targetCountry = getCountryFromPart(target)
		if targetCountry then
			if actionType == "WAR" then
				specificEvent:FireServer(targetCountry)
				if DEBUG then print("Sent War Declaration: " .. targetCountry) end

			elseif actionType == "ALLIANCE" then
				specificEvent:FireServer(targetCountry, "Alliance")
				if DEBUG then print("Sent Alliance Request: " .. targetCountry) end

			elseif actionType == "PEACE" then
				specificEvent:FireServer(targetCountry, "Peace")
				if DEBUG then print("Sent Peace Offer: " .. targetCountry) end

			elseif actionType == "BREAKALLIANCE" then
				specificEvent:FireServer(targetCountry)
				if DEBUG then print("Sent Break Alliance: " .. targetCountry) end
			end

			-- Stop listening after one click
			if currentConnection then
				currentConnection:Disconnect()
				currentConnection = nil
			end
		end
	end)
end

---------------------------------------------------------
-- PART 1: BUTTON LISTENERS (Your Button Logic)
---------------------------------------------------------

declareWarBtn.MouseButton1Click:Connect(function()
	startMapSelection("WAR", DeclareWarEvent)
end)

allianceBtn.MouseButton1Click:Connect(function()
	startMapSelection("ALLIANCE", SendRequestEvent)
end)

peaceBtn.MouseButton1Click:Connect(function()
	startMapSelection("PEACE", SendRequestEvent)
end)

breakAllianceBtn.MouseButton1Click:Connect(function()
	startMapSelection("BREAKALLIANCE", BreakAllianceEvent)
end)

---------------------------------------------------------
-- PART 2: POPUP LISTENER (Your Request Logic)
---------------------------------------------------------

-- Changed from OnClientInvoke to OnClientEvent + DiplomacyResponse
-- This prevents the "OnFireClient can only be used on the server" error
DiplomacyRequest.OnClientEvent:Connect(function(senderName, requestType, requestId)
	-- Update the UI text
	if requestType == "Alliance" then
		messageLabel.Text = senderName .. " wants to form an ALLIANCE!"
		messageLabel.TextColor3 = Color3.fromRGB(100, 255, 100) -- Green text
	elseif requestType == "Peace" then
		messageLabel.Text = senderName .. " is offering a PEACE TREATY."
		messageLabel.TextColor3 = Color3.fromRGB(100, 200, 255) -- Blue text
	end

	popup.Visible = true

	-- Variable to store choice
	local choice = nil

	-- Connect buttons purely for this specific request
	local conn1, conn2
	conn1 = acceptBtn.MouseButton1Click:Connect(function() choice = true end)
	conn2 = declineBtn.MouseButton1Click:Connect(function() choice = false end)

	-- Wait here until player clicks or popup is destroyed
	while choice == nil and popup.Parent do
		task.wait(0.1)
	end

	-- Cleanup
	conn1:Disconnect()
	conn2:Disconnect()
	if popup.Parent then
		popup.Visible = false
	end

	-- Send response back to server via DiplomacyResponse RemoteEvent
	if choice ~= nil then
		DiplomacyResponse:FireServer(requestId, choice)
	end
end)

---------------------------------------------------------
-- PART 3: REMINDER POPUP (War declared / Alliance broken)
---------------------------------------------------------
-- Queue so that rapid-fire reminders show one at a time instead of
-- stomping each other.  Each entry is { message, textColor }.
local reminderQueue = {}
local reminderActive = false

local function processReminderQueue()
	if reminderActive or #reminderQueue == 0 then return end
	reminderActive = true

	local entry = table.remove(reminderQueue, 1)
	reminderMessage.Text = entry.message
	reminderMessage.TextColor3 = entry.color
	reminderPopup.Visible = true

	-- Wait for the player to dismiss, or bail if the GUI gets destroyed
	-- (e.g. character reset with ResetOnSpawn = true removes the ScreenGui)
	local dismissed = false
	local conn = reminderOkayBtn.MouseButton1Click:Connect(function()
		dismissed = true
	end)

	while not dismissed and reminderPopup.Parent do
		task.wait(0.1)
	end

	conn:Disconnect()
	-- Guard: the popup may have been destroyed while we were waiting
	if reminderPopup.Parent then
		reminderPopup.Visible = false
	end
	reminderActive = false

	-- Show the next queued reminder, if any
	if #reminderQueue > 0 then
		task.defer(processReminderQueue)
	end
end

DiplomacyReminderEvent.OnClientEvent:Connect(function(aggressorCountry, eventType)
	local message, color

	if eventType == "War" then
		message = "⚔️ " .. aggressorCountry .. " has declared war on you!"
		color = Color3.fromRGB(255, 80, 80)
	elseif eventType == "BreakAlliance" then
		message = "💔 " .. aggressorCountry .. " has broken their alliance with you!"
		color = Color3.fromRGB(255, 180, 50)
	elseif eventType == "AllianceAccepted" then
		message = "🤝 " .. aggressorCountry .. " has accepted your alliance!"
		color = Color3.fromRGB(100, 255, 100)
	elseif eventType == "PeaceAccepted" then
		message = "🕊️ " .. aggressorCountry .. " has signed your peace treaty!"
		color = Color3.fromRGB(100, 200, 255)
	else
		-- Unknown type — log and ignore rather than show a blank popup
		warn("[DiplomacyGui] Unknown reminder type: " .. tostring(eventType))
		return
	end

	table.insert(reminderQueue, { message = message, color = color })
	task.defer(processReminderQueue)
end)