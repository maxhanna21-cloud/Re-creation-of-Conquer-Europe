-- LocalScript inside CountrySelectionScreen (FIXED - Auto-refresh on country claim)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

local SelectCountryEvent = ReplicatedStorage:WaitForChild("SelectCountryEvent", 10)
local GetAvailableCountries = ReplicatedStorage:WaitForChild("GetAvailableCountries", 10)

-- NEW: Listen for when countries are claimed to refresh the list
local CountryClaimedEvent = ReplicatedStorage:WaitForChild("CountryClaimedEvent", 10)

-- Wait for PlayerGui to be ready
local gui = player:WaitForChild("PlayerGui", 10)
local countryScreen = gui:WaitForChild("CountrySelectionScreen", 10)
local CountryList = countryScreen:WaitForChild("CountryFrame", 10):WaitForChild("CountryList", 10)
local ButtonTemplate = CountryList:WaitForChild("CountryButtonTemplate", 10)

local buttonConnections = {}

-- Build country buttons
local function buildCountryList(countries)
	-- Clear old buttons
	for _, child in ipairs(CountryList:GetChildren()) do
		if child:IsA("TextButton") and child ~= ButtonTemplate then
			local conn = buttonConnections[child.Name]
			if conn then conn:Disconnect() end
			child:Destroy()
		end
	end

	-- Clear old connections
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

-- Function to fetch from server
local function fetchCountries()
	local ok, result = pcall(function()
		return GetAvailableCountries:InvokeServer()
	end)

	if ok and type(result) == "table" then
		buildCountryList(result)
		return true
	end

	return false
end

-- Initial fetch with retry
local function initialFetch()
	local MAX_WAIT_TIME = 10
	local startTime = os.clock()

	repeat
		if fetchCountries() then
			return
		end
		task.wait(0.2)
	until os.clock() - startTime > MAX_WAIT_TIME

	warn("Could not retrieve country list. Check server logs.")
end

-- Start the initial fetch
initialFetch()

-- NEW: Listen for country claims and refresh the list
CountryClaimedEvent.OnClientEvent:Connect(function(claimedCountry, claimingPlayerName)
	-- 1. Refresh list for everyone else
	if countryScreen.Enabled then
		print("[CountrySelection] " .. claimedCountry .. " was claimed by " .. claimingPlayerName .. ", refreshing list...")
		fetchCountries()
	end

	-- 2. Check if the person who just claimed a country is ME
	if claimingPlayerName == player.Name then
		print("I have claimed " .. claimedCountry .. ". Hiding selection screen.")
		countryScreen.Enabled = false

		-- FIX: Signal to the Diplomacy script with proper error handling
		local joinSuccess = ReplicatedStorage:FindFirstChild("JoinSuccess")
		if joinSuccess and joinSuccess:IsA("BindableEvent") then
			joinSuccess:Fire()
		else
			warn("[CountrySelection] JoinSuccess BindableEvent not found or wrong type")
		end
	end
end)