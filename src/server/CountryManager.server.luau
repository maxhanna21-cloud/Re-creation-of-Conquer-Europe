-- CountryManager (ServerScriptService) - FIXED v5
-- FIX v5: Wars and occupied territory persist when player leaves
-- New player inherits wars and occupied tiles

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- Core Data
local CountryOwners = {}

-- Track initialization state
local isInitialized = false

-- Forward-declare modules (assigned after require below)
local TileManager = nil

---------------------------------------------------
-- EARLY SETUP: Register OnServerInvoke BEFORE heavy module requires.
-- If a client calls InvokeServer() before this handler exists, Roblox
-- hangs the call indefinitely — which is the root cause of the intermittent
-- black/missing country-selection screen.
---------------------------------------------------
local GetAvailableCountries = ReplicatedStorage:WaitForChild("GetAvailableCountries", 10)
if GetAvailableCountries then
	GetAvailableCountries.OnServerInvoke = function()
		if not isInitialized or not TileManager then
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
end

-- Configuration (heavy requires — these can yield for seconds while scanning tiles)
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)
local COUNTRY_SELECTION_GUI_NAME = "CountrySelectionScreen"
local ServerState = require(game:GetService("ServerScriptService"):WaitForChild("ServerState", 10))
TileManager = require(game:GetService("ServerScriptService"):WaitForChild("TileManager", 10))
-- DiplomacyManager NOT cleared when player leaves (wars persist)
local DiplomacyManager = require(game:GetService("ServerScriptService"):WaitForChild("DiplomacyManager", 10))
local NPCSpawner = require(game:GetService("ServerScriptService"):WaitForChild("NPCSpawner", 10))
local CountryClaimedEvent = ReplicatedStorage:FindFirstChild("CountryClaimedEvent")

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
-- Manpower Calculation System (Optimized v6)
---------------------------------------------------

local function calculateStartingManpower(stats, globalMins, globalMaxes, weights)
	-- Normalization: Scales values to a 0.0 - 1.0 range
	local function normalize(value, minVal, maxVal)
		if maxVal <= minVal then return 0.5 end 
		return math.clamp((value - minVal) / (maxVal - minVal), 0, 1)
	end

	local normPop = normalize(stats.population, globalMins.population, globalMaxes.population)
	local normTiles = normalize(stats.tileCount, globalMins.tileCount, globalMaxes.tileCount)
	local normArea = normalize(stats.totalArea, globalMins.totalArea, globalMaxes.totalArea)

	-- Weighted score determines where the country sits on the 5k - 90k spectrum
	local finalScore = (normPop * weights.population) + 
					   (normTiles * weights.tileCount) + 
					   (normArea * weights.totalArea)

	local MIN_MANPOWER = 5000
	local MAX_MANPOWER = 90000

	return math.floor(MIN_MANPOWER + ((MAX_MANPOWER - MIN_MANPOWER) * finalScore))
end

local function calculateAllStartingManpower()
	local startingManpower = {}
	local finalStats = {}
	
	-- Pull physical stats already calculated by TileManager
	local physicalStats = TileManager.getAllCountryTileStats()
	
	local globalMins = { population = math.huge, tileCount = math.huge, totalArea = math.huge }
	local globalMaxes = { population = 0, tileCount = 0, totalArea = 0 }
	local countryCount = 0

	-- 1. Combine Physical Stats with Population Data
	for countryName, stats in pairs(physicalStats) do
		local countryModel = EUROPE_MAP:FindFirstChild(countryName)
		if countryModel then
			local popValue = countryModel:FindFirstChild("Population")
			local population = popValue and popValue.Value or 20000 -- Fallback population

			finalStats[countryName] = {
				population = population,
				tileCount = stats.tileCount,
				totalArea = stats.totalArea
			}

			-- Update Global Extremes for normalization
			globalMins.population = math.min(globalMins.population, population)
			globalMaxes.population = math.max(globalMaxes.population, population)
			globalMins.tileCount = math.min(globalMins.tileCount, stats.tileCount)
			globalMaxes.tileCount = math.max(globalMaxes.tileCount, stats.tileCount)
			globalMins.totalArea = math.min(globalMins.totalArea, stats.totalArea)
			globalMaxes.totalArea = math.max(globalMaxes.totalArea, stats.totalArea)
			
			countryCount = countryCount + 1
		end
	end

	if countryCount == 0 then
		warn("[CountryManager] No stats found in TileManager! Manpower defaulted.")
		return startingManpower
	end

	-- 2. Define Weights
	local weights = {
		totalArea = 0.35,  -- 35% weight on physical landmass (Secondary)
		population = 0.50, -- 50% weight on population (Primary)
		tileCount = 0.15   -- 15% weight on administrative density (Modifier)
	}

	-- 3. Run final calculations
	for countryName, stats in pairs(finalStats) do
		local manpower = calculateStartingManpower(stats, globalMins, globalMaxes, weights)
		startingManpower[countryName] = manpower
		print(string.format("[CountryManager] %s Manpower: %d (Pop: %d, Tiles: %d, Area: %.0f)", 
			countryName, manpower, stats.population, stats.tileCount, stats.totalArea))
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
	local releasedAny = false
	for country, owner in pairs(CountryOwners) do
		if owner == player then
			releasedAny = true
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

	-- Hide BuyNPCGui for the released player (client will re-show selection screen via CharacterAdded)
	if releasedAny and player.Parent then
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			local buyGui = playerGui:FindFirstChild("BuyNPCGui")
			if buyGui then
				buyGui.Enabled = false
				local mainFrame = buyGui:FindFirstChild("MainFrame")
				if mainFrame then mainFrame.Visible = false end
			end
		end
	end
end

local function hasAnyOwnedCountries()
	for countryName, ownerValue in pairs(CountryOwners) do
		if typeof(ownerValue) == "Instance" and ownerValue:IsA("Player") then
			return true
		end
		if type(ownerValue) == "string" and ownerValue:sub(1, 10) == "Conquered_" then
			local resolved = ServerState.resolveCountryOwner(countryName)
			if resolved and typeof(resolved) == "Instance" and resolved:IsA("Player") and resolved.Parent then
				return true
			end
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
			local resolvedOwner
			local isDirectlyOwned = false

			if typeof(ownerValue) == "Instance" and ownerValue:IsA("Player") then
				resolvedOwner = ownerValue
				isDirectlyOwned = true
			elseif type(ownerValue) == "string" and ownerValue:sub(1, 10) == "Conquered_" then
				resolvedOwner = ServerState.resolveCountryOwner(countryName)
			end

			if not resolvedOwner or typeof(resolvedOwner) ~= "Instance"
				or not resolvedOwner:IsA("Player") or not resolvedOwner.Parent then
				continue
			end

			local claimTime = playerClaimTime[resolvedOwner]
			if claimTime and (now - claimTime) < COIN_INTERVAL then
				continue
			end

			local leaderstats = resolvedOwner:FindFirstChild("leaderstats")
			local coins = leaderstats and leaderstats:FindFirstChild("Coins")

			if coins then
				local newAmount = math.floor(coins.Value) + BASE_COIN_INCOME
				coins.Value = newAmount
				-- Only mirror to country treasury for directly-owned countries
				if isDirectlyOwned then
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
			local resolvedOwner
			local isDirectlyOwned = false

			if typeof(ownerValue) == "Instance" and ownerValue:IsA("Player") then
				resolvedOwner = ownerValue
				isDirectlyOwned = true
			elseif type(ownerValue) == "string" and ownerValue:sub(1, 10) == "Conquered_" then
				resolvedOwner = ServerState.resolveCountryOwner(countryName)
			end

			if not resolvedOwner or typeof(resolvedOwner) ~= "Instance"
				or not resolvedOwner:IsA("Player") or not resolvedOwner.Parent then
				continue
			end

			local claimTime = playerClaimTime[resolvedOwner]
			if claimTime and (now - claimTime) < MANPOWER_INTERVAL then
				continue
			end

			local leaderstats = resolvedOwner:FindFirstChild("leaderstats")
			local manpower = leaderstats and leaderstats:FindFirstChild("Manpower")

			if manpower then
				local newAmount = math.floor(manpower.Value) + BASE_MANPOWER_INCOME
				manpower.Value = newAmount
				-- Only mirror to country treasury for directly-owned countries
				if isDirectlyOwned then
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

local function spawnStarterNPCs()
	-- Collect all starting manpower values to compute the median
	local allManpowers = {}
	local countryManpowerMap = {}
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if not countryModel:IsA("Model") then continue end
		local countryName = countryModel.Name
		local manpower = ServerState.getCountryManpower(countryName) or 0
		table.insert(allManpowers, manpower)
		countryManpowerMap[countryName] = manpower
	end

	-- Compute 37.5th percentile manpower (~62.5% get DefenderNPC, ~37.5% get AttackerNPC)
	table.sort(allManpowers)
	local n = #allManpowers
	local attackerThreshold
	if n == 0 then
		attackerThreshold = 30000 -- fallback if no countries found
	else
		-- +1 corrects for >= boundary: country AT the index also gets DefenderNPC
		local pIndex = math.max(1, math.floor(n * 0.375) + 1)
		attackerThreshold = allManpowers[pIndex]
	end
	print("[CountryManager] Starter NPC attacker threshold (37.5th percentile): " .. attackerThreshold)

	-- Spawn one starter NPC at each country's capital
	-- Countries at or above the 37.5th percentile get a DefenderNPC; below get an AttackerNPC
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if not countryModel:IsA("Model") then continue end
		local countryName = countryModel.Name

		local capitalPart = TileManager.getCountryCapital(countryName)
		if not capitalPart then
			warn("[CountryManager] No capital found for " .. countryName .. ", skipping starter NPC")
			continue
		end

		local manpower = countryManpowerMap[countryName] or 0
		local npcType = (manpower >= attackerThreshold) and "DefenderNPC" or "AttackerNPC"

		local spawnPos = capitalPart.Position + Vector3.new(0, capitalPart.Size.Y / 2 + 3, 0)
		local tileKey = TileManager.getTileKeyFromPart(capitalPart)

		if not tileKey then
			warn("[CountryManager] Could not get tile key for capital of " .. countryName .. ", skipping starter NPC")
			continue
		end

		NPCSpawner.spawnNPC(countryName, npcType, spawnPos, tileKey, nil) -- nil = country-owned
		print("[CountryManager] Spawned starter " .. npcType .. " for " .. countryName .. " (manpower: " .. manpower .. ")")
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

	-- Spawn one starter NPC at each country's capital
	task.defer(spawnStarterNPCs)
end

---------------------------------------------------
-- Setup
---------------------------------------------------

local SelectCountryEvent = ReplicatedStorage:WaitForChild("SelectCountryEvent", 10)
-- GetAvailableCountries handler was registered early (top of script) to prevent InvokeServer hangs.
local InitializationComplete = ReplicatedStorage:WaitForChild("InitializationComplete", 10)

SelectCountryEvent.OnServerEvent:Connect(handleCountrySelection)

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function(character)
		onCharacterRemoving(player, character)
	end)
	-- Players who join after the initial FireAllClients would never receive InitializationComplete.
	-- Fire it directly to each late joiner so their client can open the selection screen.
	if isInitialized then
		InitializationComplete:FireClient(player)
	end
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