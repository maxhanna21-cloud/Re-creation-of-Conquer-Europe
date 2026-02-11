-- CountryManager (ServerScriptService) - FIXED v5
-- FIX v5: Wars and occupied territory persist when player leaves
--         New player inherits wars and occupied tiles

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- Configuration
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)
local COUNTRY_SELECTION_GUI_NAME = "CountrySelectionScreen"
local ServerState = require(game:GetService("ServerScriptService"):WaitForChild("ServerState", 10))
local TileManager = require(game:GetService("ServerScriptService"):WaitForChild("TileManager", 10))
-- DiplomacyManager NOT cleared when player leaves (wars persist)
local DiplomacyManager = require(game:GetService("ServerScriptService"):WaitForChild("DiplomacyManager", 10))
local CountryClaimedEvent = ReplicatedStorage:FindFirstChild("CountryClaimedEvent")

-- Core Data
local CountryOwners = {}

-- Track initialization state
local isInitialized = false

-- Income Loop States
local CoinLoopRunning = false
local ManpowerLoopRunning = false

-- Income Configuration
local COIN_INTERVAL = 10
local BASE_COIN_INCOME = 50

local MANPOWER_INTERVAL = 3
local BASE_MANPOWER_INCOME = 100

-- Starting resource configuration
local STARTING_COINS = 250

-- Per-player claiming lock
local playerClaiming = {}
local playerClaimTime = {}

---------------------------------------------------
-- Manpower Calculation System
---------------------------------------------------

local function calculateStartingManpower(population, globalAvgPopulation, minPopulation, maxPopulation)
	if not population or population <= 0 then
		warn("[CountryManager] Invalid population value, using default 20000")
		return 20000
	end

	local minMP, maxMP

	if population < globalAvgPopulation * 0.7 then
		-- Small population tier
		minMP, maxMP = 10000, 30000
	elseif population > globalAvgPopulation * 1.3 then
		-- Large population tier
		minMP, maxMP = 60000, 90000
	else
		-- Medium population tier
		minMP, maxMP = 30000, 60000
	end

	-- Normalize within the tier based on overall population range
	local normalizedScore = 0.5
	if maxPopulation > minPopulation then
		normalizedScore = (population - minPopulation) / (maxPopulation - minPopulation)
	end

	normalizedScore = math.clamp(normalizedScore, 0, 1)
	local manpower = math.floor(minMP + (maxMP - minMP) * normalizedScore)

	return manpower
end

local function calculateAllStartingManpower()
	local startingManpower = {}
	local populations = {}

	local totalPopulation = 0
	local countryCount = 0
	local minPopulation = math.huge
	local maxPopulation = 0

	-- Read Population IntValue from each country model
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			local popValue = countryModel:FindFirstChild("Population")
			local population = popValue and popValue.Value or 0

			if population <= 0 then
				warn("[CountryManager] " .. countryModel.Name .. " has no Population value, using default 20000")
				populations[countryModel.Name] = nil
			else
				populations[countryModel.Name] = population
				totalPopulation = totalPopulation + population
				countryCount = countryCount + 1
				minPopulation = math.min(minPopulation, population)
				maxPopulation = math.max(maxPopulation, population)
			end
		end
	end

	if countryCount == 0 then
		warn("[CountryManager] No countries with Population values found for manpower calculation!")
		return startingManpower
	end

	local globalAvgPopulation = totalPopulation / countryCount

	for countryName, population in pairs(populations) do
		local manpower = calculateStartingManpower(
			population,
			globalAvgPopulation,
			minPopulation,
			maxPopulation
		)
		startingManpower[countryName] = manpower
		print(string.format("[CountryManager] %s: population=%d, manpower=%d", countryName, population, manpower))
	end

	return startingManpower
end

---------------------------------------------------
-- Helper Functions
---------------------------------------------------

local function getCapitalCFrame(countryName)
	local countryModel = EUROPE_MAP:FindFirstChild(countryName)
	if not countryModel then return nil end
	local capitalPart = countryModel:FindFirstChild("Capital")
	if not capitalPart then
		return countryModel:GetPivot() * CFrame.new(0,5,0)
	end
	return capitalPart.CFrame * CFrame.new(0, capitalPart.Size.Y/2 + 5, 0)
end

local function getCountryNPCs(countryName)
	local npcs = {}
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChild("Humanoid") and child:FindFirstChild("NPCOwner") then
			local npcCountry = child:GetAttribute("Country")
			if npcCountry == countryName then
				table.insert(npcs, child)
			end
		end
	end
	return npcs
end

local function transferCountryNPCs(countryName, newOwner)
	local Combat = require(game:GetService("ServerScriptService"):WaitForChild("NPCCombatSystem", 10))
	local npcs = getCountryNPCs(countryName)

	for _, npc in ipairs(npcs) do
		local ownerValue = npc:FindFirstChild("NPCOwner")
		if ownerValue then
			ownerValue.Value = newOwner
		end

		if newOwner then
			local role = Combat.getRole(npc)
			if role then
				Combat.transferOwnership(npc, newOwner)
				print("[CountryManager] Transferred " .. npc.Name .. " to " .. newOwner.Name)
			end
		else
			Combat.transferOwnership(npc, nil)
			print("[CountryManager] " .. npc.Name .. " now country-owned (no player)")
		end
	end

	return #npcs
end

-- FIX v5: Release countries WITHOUT clearing diplomacy or occupied territories
local function releasePlayerCountries(player, reason)
	for country, owner in pairs(CountryOwners) do
		if owner == player then
			local leaderstats = player:FindFirstChild("leaderstats")

			-- Save coins to country (for next player)
			local coins = leaderstats and leaderstats:FindFirstChild("Coins")
			if coins then
				ServerState.setCountryCoins(country, math.floor(coins.Value))
				print("[CountryManager] Saved " .. coins.Value .. " coins to " .. country)
				coins.Value = 0
			end

			-- Save manpower to country
			local manpower = leaderstats and leaderstats:FindFirstChild("Manpower")
			if manpower then
				ServerState.setCountryManpower(country, math.floor(manpower.Value))
				print("[CountryManager] Saved " .. manpower.Value .. " manpower to " .. country)
				manpower.Value = 0
			end

			-- Transfer NPCs to country ownership (no player)
			local npcCount = transferCountryNPCs(country, nil)
			print("[CountryManager] " .. country .. " now has " .. npcCount .. " NPCs waiting for next player")

			-- FIX v5: Do NOT clear diplomacy - wars persist!
			-- DiplomacyManager.clearCountryDiplomacy(country) -- REMOVED

			-- FIX v5: Do NOT release occupied territories - they persist!
			-- Occupied territories remain owned by the COUNTRY

			-- Release the country (mark as Unowned but keep wars active)
			CountryOwners[country] = "Unowned"
			print("[CountryManager] " .. country .. " released - " .. player.Name .. " " .. reason)
			print("[CountryManager] Wars and occupied territories for " .. country .. " remain active")

			-- Clear TileManager cache for this player
			TileManager.updatePlayerCountryCache(player, nil)

			-- Reset leaderstats
			local countryStat = leaderstats and leaderstats:FindFirstChild("Country")
			if countryStat then
				countryStat.Value = "None"
			end
		end
	end
	ServerState.setCountryOwners(CountryOwners)
end

local function hasAnyOwnedCountries()
	for _, ownerValue in pairs(CountryOwners) do
		if typeof(ownerValue) == "Instance" and ownerValue:IsA("Player") then
			return true
		end
	end
	return false
end

-- COIN INCOME LOOP
local function startCoinIncomeLoop()
	while CoinLoopRunning do
		if not hasAnyOwnedCountries() then
			print("[CountryManager] No owned countries remaining. Stopping coin income loop.")
			CoinLoopRunning = false
			break
		end

		local now = os.clock()

		for countryName, ownerValue in pairs(CountryOwners) do
			if typeof(ownerValue) == "Instance" and ownerValue:IsA("Player") and ownerValue.Parent then
				local claimTime = playerClaimTime[ownerValue]
				if claimTime and (now - claimTime) < COIN_INTERVAL then
					continue
				end

				local leaderstats = ownerValue:FindFirstChild("leaderstats")
				local coins = leaderstats and leaderstats:FindFirstChild("Coins")

				if coins then
					local newAmount = math.floor(coins.Value) + BASE_COIN_INCOME
					coins.Value = newAmount
					ServerState.setCountryCoins(countryName, newAmount)
				end
			end
		end
		task.wait(COIN_INTERVAL)
	end
	print("[CountryManager] Coin income loop stopped.")
end

-- MANPOWER INCOME LOOP
local function startManpowerIncomeLoop()
	while ManpowerLoopRunning do
		if not hasAnyOwnedCountries() then
			print("[CountryManager] No owned countries remaining. Stopping manpower income loop.")
			ManpowerLoopRunning = false
			break
		end

		local now = os.clock()

		for countryName, ownerValue in pairs(CountryOwners) do
			if typeof(ownerValue) == "Instance" and ownerValue:IsA("Player") and ownerValue.Parent then
				local claimTime = playerClaimTime[ownerValue]
				if claimTime and (now - claimTime) < MANPOWER_INTERVAL then
					continue
				end

				local leaderstats = ownerValue:FindFirstChild("leaderstats")
				local manpower = leaderstats and leaderstats:FindFirstChild("Manpower")

				if manpower then
					local newAmount = math.floor(manpower.Value) + BASE_MANPOWER_INCOME
					manpower.Value = newAmount
					ServerState.setCountryManpower(countryName, newAmount)
				end
			end
		end
		task.wait(MANPOWER_INTERVAL)
	end
	print("[CountryManager] Manpower income loop stopped.")
end

local function onCharacterRemoving(player, character)
	releasePlayerCountries(player, "died/reset")
end

local function handleCountrySelection(player, countryName)
	if not isInitialized then
		warn("[CountryManager] " .. player.Name .. " tried to claim before initialization complete.")
		return
	end

	if playerClaiming[player] then
		warn("[CountryManager] " .. player.Name .. " is already claiming a country.")
		return
	end
	playerClaiming[player] = true

	local claimSucceeded = false
	local claimedCountryName = nil

	local success, errorMsg = pcall(function()
		-- Check if country is available (Unowned, not owned by another player)
		local currentOwner = CountryOwners[countryName]
		if currentOwner and currentOwner ~= "Unowned" then
			-- Check if it's a player
			if typeof(currentOwner) == "Instance" and currentOwner:IsA("Player") then
				error(player.Name .. " attempted to claim " .. countryName .. " but it is already owned by " .. currentOwner.Name)
				-- Check if conquered
			elseif type(currentOwner) == "string" and currentOwner:find("Conquered_") then
				error(player.Name .. " attempted to claim " .. countryName .. " but it has been conquered")
			end
		end

		for country, owner in pairs(CountryOwners) do
			if owner == player then
				error(player.Name .. " already owns " .. country .. ". Cannot claim another.")
			end
		end

		CountryOwners[countryName] = player
		ServerState.setCountryOwners(CountryOwners)
		claimedCountryName = countryName
		claimSucceeded = true
		print("[CountryManager] " .. player.Name .. " claimed " .. countryName)

		if CountryClaimedEvent then
			CountryClaimedEvent:FireAllClients(countryName, player.Name)
		end

		TileManager.updatePlayerCountryCache(player, countryName)

		local leaderstats = player:FindFirstChild("leaderstats")

		local countryStat = leaderstats and leaderstats:FindFirstChild("Country")
		if countryStat then
			countryStat.Value = countryName
		end

		-- FIX v5: Inherit resources (coins saved when previous player left)
		local coins = leaderstats and leaderstats:FindFirstChild("Coins")
		if coins then
			local countryCoins = ServerState.getCountryCoins(countryName)
			coins.Value = countryCoins
			print("[CountryManager] " .. player.Name .. " inherited " .. countryCoins .. " coins from " .. countryName)
		end

		local manpower = leaderstats and leaderstats:FindFirstChild("Manpower")
		if manpower then
			local countryManpower = ServerState.getCountryManpower(countryName)
			manpower.Value = countryManpower
			print("[CountryManager] " .. player.Name .. " inherited " .. countryManpower .. " manpower from " .. countryName)
		end

		-- FIX v5: Transfer NPCs to new player (they inherit country's army)
		local npcCount = transferCountryNPCs(countryName, player)
		if npcCount > 0 then
			print("[CountryManager] " .. player.Name .. " inherited " .. npcCount .. " NPCs from " .. countryName)
		end

		-- FIX v5: Notify about inherited wars
		local enemies = DiplomacyManager.getEnemies(countryName)
		if #enemies > 0 then
			print("[CountryManager] " .. player.Name .. " inherits wars against: " .. table.concat(enemies, ", "))
			local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
			if GlobalNotificationEvent then
				GlobalNotificationEvent:FireClient(player, "⚠️ You are at war with: " .. table.concat(enemies, ", "), Color3.fromRGB(255, 200, 100))
			end
		end

		-- FIX v5: Notify about inherited occupied territory
		local TileOwnershipManager = require(game:GetService("ServerScriptService"):WaitForChild("TileOwnershipManager", 10))
		local occupiedCount = TileOwnershipManager.getCountryOccupiedCount(countryName)
		if occupiedCount > 0 then
			print("[CountryManager] " .. player.Name .. " inherits " .. occupiedCount .. " occupied tiles")
		end

		if not CoinLoopRunning then
			CoinLoopRunning = true 
			task.spawn(startCoinIncomeLoop)
		end

		if not ManpowerLoopRunning then
			ManpowerLoopRunning = true
			task.spawn(startManpowerIncomeLoop)
		end

		local capitalCFrame = getCapitalCFrame(countryName)
		if capitalCFrame and player.Character then
			player.Character:PivotTo(capitalCFrame)
		end

		-- NOTE: CountryClaimedEvent is already fired at line 348, removed duplicate here

		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			local gui = playerGui:FindFirstChild(COUNTRY_SELECTION_GUI_NAME)
			if gui then
				gui.Enabled = false
			end

			local buyGui = playerGui:FindFirstChild("BuyNPCGui")
			if buyGui and buyGui:FindFirstChild("MainFrame") then
				buyGui.MainFrame.Visible = true
				buyGui.Enabled = true
			end
		end
	end)

	if claimSucceeded then
		playerClaimTime[player] = os.clock()
	end

	playerClaiming[player] = nil

	if not success then
		if claimedCountryName and CountryOwners[claimedCountryName] == player then
			CountryOwners[claimedCountryName] = "Unowned"
			ServerState.setCountryOwners(CountryOwners)
			TileManager.updatePlayerCountryCache(player, nil)
			warn("[CountryManager] Rolled back failed claim of " .. claimedCountryName)
		end
		print("[CountryManager] Country selection failed: " .. tostring(errorMsg))
	end
end

local function initializeCountries()
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			CountryOwners[countryModel.Name] = "Unowned"
		end
	end
	ServerState.setCountryOwners(CountryOwners)

	local startingManpowerValues = calculateAllStartingManpower()

	for countryName, _ in pairs(CountryOwners) do
		ServerState.initializeCountryCoins(countryName, STARTING_COINS)
		local manpower = startingManpowerValues[countryName] or 20000
		ServerState.initializeCountryManpower(countryName, manpower)
	end

	isInitialized = true
end

---------------------------------------------------
-- Setup
---------------------------------------------------

local SelectCountryEvent = ReplicatedStorage:WaitForChild("SelectCountryEvent", 10)
local GetAvailableCountries = ReplicatedStorage:WaitForChild("GetAvailableCountries", 10)
local InitializationComplete = ReplicatedStorage:WaitForChild("InitializationComplete", 10)

SelectCountryEvent.OnServerEvent:Connect(handleCountrySelection)

GetAvailableCountries.OnServerInvoke = function()
	if not isInitialized then
		warn("[CountryManager] GetAvailableCountries called before initialization.")
		return {}
	end

	local ok, result = pcall(TileManager.getAvailableCountries)
	if ok then
		return result
	else
		warn("GetAvailableCountries crashed!")
		return {}
	end
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function(character)
		onCharacterRemoving(player, character)
	end)
end)

for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterRemoving:Connect(function(character)
		onCharacterRemoving(player, character)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	releasePlayerCountries(player, "left the game")
	playerClaiming[player] = nil
	playerClaimTime[player] = nil
end)

initializeCountries()
InitializationComplete:FireAllClients()

print("DEBUG: Map setup complete. CountryOwners table populated.")