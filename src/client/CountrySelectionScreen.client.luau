-- LocalScript inside CountrySelectionScreen (Server-Authoritative)
-- No longer reads replicated Country stat to decide visibility.
--      The server's GetAvailableCountries response is the single source of truth:
--        • table  → list of available countries (show selection screen)
--        • false  → player already owns a country (hide screen)
--        • nil    → server not ready yet (retry)
local DEBUG = false
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

-- =============================================
-- REMOTE REFERENCES (with nil guards)
-- =============================================
local SelectCountryEvent = ReplicatedStorage:WaitForChild("SelectCountryEvent", 15)
local GetAvailableCountries = ReplicatedStorage:WaitForChild("GetAvailableCountries", 15)
local CountryClaimedEvent = ReplicatedStorage:WaitForChild("CountryClaimedEvent", 15)
local InitializationComplete = ReplicatedStorage:WaitForChild("InitializationComplete", 15)

if not SelectCountryEvent or not GetAvailableCountries or not CountryClaimedEvent or not InitializationComplete then
	warn("[CountrySelection] Missing RemoteEvents in ReplicatedStorage — aborting script")
	return
end

-- =============================================
-- UI REFERENCES (with nil guards for each step)
-- =============================================
local gui = player:WaitForChild("PlayerGui", 15)
if not gui then
	warn("[CountrySelection] PlayerGui not found — aborting script")
	return
end

local countryScreen = gui:WaitForChild("CountrySelectionScreen", 15)
if not countryScreen then
	warn("[CountrySelection] CountrySelectionScreen ScreenGui not found — aborting script")
	return
end

local CountryFrame = countryScreen:WaitForChild("CountryFrame", 10)
if not CountryFrame then
	warn("[CountrySelection] CountryFrame not found — aborting script")
	return
end

local CountryList = CountryFrame:WaitForChild("CountryList", 10)
if not CountryList then
	warn("[CountrySelection] CountryList not found — aborting script")
	return
end

local ButtonTemplate = CountryList:WaitForChild("CountryButtonTemplate", 10)
if not ButtonTemplate then
	warn("[CountrySelection] CountryButtonTemplate not found — aborting script")
	return
end

-- Ensure the screen starts DISABLED so a failed fetch never leaves a black screen
countryScreen.Enabled = false

local buttonConnections = {}
local isOpening = false -- Guard to prevent overlapping polling loops
local retryNow  = false -- Set true by InitializationComplete to short-circuit the retry sleep

-- =============================================
-- BUILD COUNTRY LIST UI
-- =============================================
local function buildCountryList(countries)
	for _, child in ipairs(CountryList:GetChildren()) do
		if child:IsA("TextButton") and child ~= ButtonTemplate then
			local conn = buttonConnections[child.Name]
			if conn then conn:Disconnect() end
			child:Destroy()
		end
	end

	buttonConnections = {}

	-- Sort a shallow copy so the server's original table is never mutated.
	-- Case-insensitive so "Austria" always sorts before "Bosnia" regardless
	-- of how the server capitalises country names.
	local sorted = table.move(countries, 1, #countries, 1, {})
	table.sort(sorted, function(a, b)
		return string.lower(a) < string.lower(b)
	end)

	for i, countryName in ipairs(sorted) do
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

-- =============================================
-- CORE: SERVER-AUTHORITATIVE tryOpenMenu
-- =============================================
-- No client-side Country stat check.  The server tells us definitively
-- whether the player needs to select a country.
local function tryOpenMenu()
	if isOpening then return end
	isOpening = true

	local success, err = pcall(function()
		while true do
			local ok, data = pcall(function()
				return GetAvailableCountries:InvokeServer()
			end)

			if ok then
				if data == false then
					-- Server says the player already owns a country
					countryScreen.Enabled = false
					return
				elseif type(data) == "table" and #data > 0 then
					-- Countries available — show the selection screen
					buildCountryList(data)
					countryScreen.Enabled = true
					return
				end
				-- nil or empty table → server not ready yet, fall through to retry
			end

			-- Wait before retrying; bail if the script's parent is being destroyed
			-- (e.g., ScreenGui removed on death with ResetOnSpawn).
			-- Short-polls in 0.1s ticks so InitializationComplete can wake us
			-- immediately instead of waiting the full 2s safety interval.
			if not countryScreen.Parent then return end
			-- If InitializationComplete already fired while InvokeServer was in flight,
			-- skip the sleep entirely so we don't waste up to 2 seconds consuming a
			-- signal that arrived before we had a chance to check it.
			if not retryNow then
				local elapsed = 0
				while elapsed < 2 and not retryNow do
					task.wait(0.1)
					elapsed += 0.1
				end
			end
			retryNow = false -- consume the signal after the wait (or skip)
		end
	end)

	if not success then
		warn("[CountrySelection] Error in tryOpenMenu: " .. tostring(err))
	end

	isOpening = false
end

-- =============================================
-- TRIGGER EVENTS
-- =============================================

-- 1. Try immediately on script load (deferred so event connections below are set up first)
task.defer(tryOpenMenu)

-- 2. Server Initialization Complete / Respawn notification
--    The server fires this event:
--      • Once for all players when initialization finishes (FireAllClients)
--      • For each late joiner on PlayerAdded
--      • For each respawn where the player doesn't own a country (CharacterAdded)
InitializationComplete.OnClientEvent:Connect(function()
	retryNow = true -- wake the retry loop immediately if it's sleeping
	if not isOpening then
		tryOpenMenu()
	end
end)

-- 3. Country stat change listener (fallback)
--    Catches the case where the server resets Country to "None" after death/reset
--    and the replication arrives after the initial tryOpenMenu already ran.
local leaderstats = player:WaitForChild("leaderstats", 10)
if leaderstats then
	local countryStat = leaderstats:WaitForChild("Country", 5)
	if countryStat then
		countryStat:GetPropertyChangedSignal("Value"):Connect(function()
			local val = countryStat.Value
			if (val == "" or val == "None" or val == "Defeated") and not isOpening then
				tryOpenMenu()
			end
		end)
	end
end

-- 4. Listen for other players claiming countries to auto-refresh the visible list
CountryClaimedEvent.OnClientEvent:Connect(function(claimedCountry, claimingPlayerName)
	if countryScreen.Enabled then
		task.spawn(function()
			local ok, result = pcall(function() return GetAvailableCountries:InvokeServer() end)
			-- Guard: only refresh if we got a valid list (not false/nil)
			if ok and type(result) == "table" and #result > 0 then
				buildCountryList(result)
			end
		end)
	end

	-- If YOU claimed it, hide the screen and fire JoinSuccess
	if claimingPlayerName == player.Name then
		countryScreen.Enabled = false
		local joinSuccess = ReplicatedStorage:FindFirstChild("JoinSuccess")
		if joinSuccess then joinSuccess:Fire() end
	end
end)

if DEBUG then print("[CountrySelectionScreen] Server-authoritative logic initialized.") end
