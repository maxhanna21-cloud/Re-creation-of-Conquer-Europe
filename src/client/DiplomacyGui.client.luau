-- LocalScript inside DiplomacyGui
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
	print("Diplomacy GUI Activated!")
end)

-- 2. GET REMOTES
local DiplomacyRequest = ReplicatedStorage:WaitForChild("DiplomacyRequest", 10)
local DeclareWarEvent = ReplicatedStorage:WaitForChild("DeclareWarEvent", 10)
local SendRequestEvent = ReplicatedStorage:WaitForChild("SendRequestEvent", 10)

-- 3. UI REFERENCES
local warPanel = gui:WaitForChild("WarPanel", 10)
local popup = gui:WaitForChild("RequestPopup", 10)

-- Buttons inside WarPanel
local declareWarBtn = warPanel:WaitForChild("DeclareWar", 10)
local allianceBtn = warPanel:WaitForChild("FormAlliance", 10)
local peaceBtn = warPanel:WaitForChild("SignPeace", 10)

-- Popup Elements
local messageLabel = popup:WaitForChild("Message", 10)
local acceptBtn = popup:WaitForChild("ButtonContainer", 10).AcceptButton
local declineBtn = popup:WaitForChild("ButtonContainer", 10).DeclineButton

-- STATE VARIABLE (Prevents multiple clicks stacking up)
local currentConnection = nil

-- FIX: Improved helper to find country model from any part inside EuropeMap
local function getCountryFromPart(part)
	if not part or not part:IsA("BasePart") then return nil end

	-- Walk up the hierarchy to find the country model
	local current = part.Parent
	while current and current ~= EuropeMap and current ~= Workspace do
		if current.Parent == EuropeMap then
			-- Found the country model (direct child of EuropeMap)
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

	print("Select a country on the map for: " .. actionType)

	currentConnection = Mouse.Button1Down:Connect(function()
		local target = Mouse.Target

		-- FIX: Use robust country detection that handles nested parts
		local targetCountry = getCountryFromPart(target)
		if targetCountry then
			if actionType == "WAR" then
				specificEvent:FireServer(targetCountry)
				print("Sent War Declaration: " .. targetCountry)

			elseif actionType == "ALLIANCE" then
				specificEvent:FireServer(targetCountry, "Alliance")
				print("Sent Alliance Request: " .. targetCountry)

			elseif actionType == "PEACE" then
				specificEvent:FireServer(targetCountry, "Peace")
				print("Sent Peace Offer: " .. targetCountry)
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

---------------------------------------------------------
-- PART 2: POPUP LISTENER (Your Request Logic)
---------------------------------------------------------

DiplomacyRequest.OnClientInvoke = function(senderName, requestType)
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

	-- Wait here until player clicks
	while choice == nil do
		task.wait(0.1)
	end

	-- Cleanup
	conn1:Disconnect()
	conn2:Disconnect()
	popup.Visible = false

	return choice -- Sends answer back to server
end