-- LocalScript inside CountrySelectionScreen (INSTANT LOAD + Respawn Fix)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

-- Wait for required RemoteEvents (Does not yield if they already exist)
local SelectCountryEvent = ReplicatedStorage:WaitForChild("SelectCountryEvent", 15)
local GetAvailableCountries = ReplicatedStorage:WaitForChild("GetAvailableCountries", 15)
local CountryClaimedEvent = ReplicatedStorage:WaitForChild("CountryClaimedEvent", 15)
local InitializationComplete = ReplicatedStorage:WaitForChild("InitializationComplete", 15)

-- Get UI Elements
local gui = player:WaitForChild("PlayerGui", 15)
local countryScreen = gui:WaitForChild("CountrySelectionScreen", 15)
local CountryList = countryScreen:WaitForChild("CountryFrame", 10):WaitForChild("CountryList", 10)
local ButtonTemplate = CountryList:WaitForChild("CountryButtonTemplate", 10)

-- Ensure the screen starts DISABLED so a failed fetch never leaves a black screen
-- (the ScreenGui's default Enabled state in Studio is unpredictable)
countryScreen.Enabled = false

local buttonConnections = {}
local isOpening = false -- Guard to prevent overlapping logic

-- Build country buttons
local function buildCountryList(countries)
	for _, child in ipairs(CountryList:GetChildren()) do
		if child:IsA("TextButton") and child ~= ButtonTemplate then
			local conn = buttonConnections[child.Name]
			if conn then conn:Disconnect() end
			child:Destroy()
		end
	end

	buttonConnections = {}

	for i, countryName in ipairs(countries) do
		local btn = ButtonTemplate:Clone()
		btn.Name = countryName
		btn.Text = countryName
		btn.Visible = true
		btn.LayoutOrder = i
		btn.Parent = CountryList

		buttonConnections[countryName] = btn.MouseButton1Click:Connect(function()
			for _, b in ipairs(CountryList:GetChildren()) do
				if b:IsA("TextButton") then b.Active = false end
			end
			SelectCountryEvent:FireServer(countryName)
		end)
	end
end

-- Core function to instantly open menu
-- Added 'force' parameter to override isOpening guard during critical transitions (death/switch)
local function tryOpenMenu(force)
	if isOpening and not force then return end
	isOpening = true

	local success = pcall(function()
		-- 1. Check if player already owns a country
		local leaderstats = player:WaitForChild("leaderstats", 5)
		local countryStat = leaderstats and leaderstats:FindFirstChild("Country")
		
		local statVal = countryStat and countryStat.Value or ""
		
		-- If they have a valid country, make sure the menu is OFF and exit
		if statVal ~= "" and statVal ~= "None" and statVal ~= "Defeated" then
			countryScreen.Enabled = false
			return
		end

		-- 2. Fetch countries - retry indefinitely until server is ready.
		--    Hard attempt cap removed: the old 30-attempt ceiling caused permanent
		--    silent failure whenever server init exceeded 30 s or InvokeServer hiccuped.
		local successData = nil
		local pollAttempt = 0

		while not successData do
			pollAttempt += 1
			local ok, result = pcall(function()
				return GetAvailableCountries:InvokeServer()
			end)

			if ok and type(result) == "table" and #result > 0 then
				successData = result
			else
				task.wait(2)
				-- Re-check mid-wait: bail if the player claimed a country another way
				local ls = player:FindFirstChild("leaderstats")
				local cs = ls and ls:FindFirstChild("Country")
				local cv = cs and cs.Value or ""
				if cv ~= "" and cv ~= "None" and cv ~= "Defeated" then
					countryScreen.Enabled = false
					return
				end
			end
		end

		-- Final check before showing UI
		local currentStat = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Country")
		local currentVal = currentStat and currentStat.Value or ""

		if currentVal == "" or currentVal == "None" or currentVal == "Defeated" then
			buildCountryList(successData)
			countryScreen.Enabled = true
		else
			countryScreen.Enabled = false
		end
	end)

	if not success then
		warn("[CountrySelection] Critical error in tryOpenMenu")
	end
	
	isOpening = false
end

-- ==========================================
-- TRIGGER EVENTS
-- ==========================================

-- 1. Try Immediately on Script Load
task.defer(function()
	tryOpenMenu(false)
end)

-- 2. Server Initialization Complete
-- Only trigger if the polling loop isn't already running. Prevents a second
-- concurrent loop from spawning and conflicting with the first.
InitializationComplete.OnClientEvent:Connect(function()
	if not isOpening then
		tryOpenMenu(false)
	end
end)

-- 3. Respawn / Character Added Handler
-- With ResetOnSpawn=true a brand-new LocalScript handles every spawn, so this
-- only fires for a subsequent spawn while THIS script instance is still alive.
-- Guard against spawning a second loop if the first one is still running.
player.CharacterAdded:Connect(function()
	if not isOpening then
		tryOpenMenu(false)
	end
end)

-- 4. Listen for other players claiming countries to auto-refresh
CountryClaimedEvent.OnClientEvent:Connect(function(claimedCountry, claimingPlayerName)
	if countryScreen.Enabled then
		task.spawn(function()
			local ok, result = pcall(function() return GetAvailableCountries:InvokeServer() end)
			-- Guard against a transient empty result destroying the existing button list
			if ok and type(result) == "table" and #result > 0 then buildCountryList(result) end
		end)
	end

	-- If YOU claimed it, hide the screen and initialize gameplay
	if claimingPlayerName == player.Name then
		countryScreen.Enabled = false
		local joinSuccess = ReplicatedStorage:FindFirstChild("JoinSuccess")
		if joinSuccess then joinSuccess:Fire() end
	end
end)

print("[CountrySelectionScreen] Reinforced logic initialized.")