-- TileOwnershipManager (ModuleScript in ServerScriptService) - FIXED v3
-- FIX v2: Capital capture guard
-- FIX v3: Occupation stored by COUNTRY (not player) - persists when players leave
--         Occupied territory counts as valid tile for the occupying country

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local TileOwnershipManager = {}

-- Lazy-load dependencies
local ServerState = nil
local TileManager = nil
local TileAdjacencyManager = nil
local Combat = nil
local DiplomacyManager = nil

local function getDependencies()
	if not ServerState then
		ServerState = require(game.ServerScriptService:WaitForChild("ServerState", 10))
	end
	if not TileManager then
		TileManager = require(game.ServerScriptService:WaitForChild("TileManager", 10))
	end
	if not TileAdjacencyManager then
		TileAdjacencyManager = require(game.ServerScriptService:WaitForChild("TileAdjacencyManager", 10))
	end
	if not Combat then
		Combat = require(game.ServerScriptService:WaitForChild("NPCCombatSystem", 10))
	end
	if not DiplomacyManager then
		DiplomacyManager = require(game.ServerScriptService:WaitForChild("DiplomacyManager", 10))
	end
end

-- Configuration
local DEBUG = true
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

-- Store original tile colors
local OriginalColors = {}

-- FIX v3: Track occupied territories by COUNTRY name (persists when player leaves)
-- OccupiedTerritories[tilePart] = { occupyingCountry = "France", originalCountry = "Germany", originalColor = Color3 }
local OccupiedTerritories = {}

-- Store country colors
local CountryColors = {}

-- Capital capture guard
local capitalsBeingCaptured = {}

---------------------------------------------------
-- Initialization
---------------------------------------------------

local function scanCountryColors()
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			local countryName = countryModel.Name

			for _, part in ipairs(countryModel:GetDescendants()) do
				if part:IsA("BasePart") then
					CountryColors[countryName] = part.Color
					OriginalColors[part] = part.Color
					break
				end
			end

			for _, part in ipairs(countryModel:GetDescendants()) do
				if part:IsA("BasePart") then
					OriginalColors[part] = part.Color
				end
			end
		end
	end

	print("[TileOwnershipManager] Scanned country colors")
end

---------------------------------------------------
-- Color Management
---------------------------------------------------

function TileOwnershipManager.getCountryColor(countryName)
	return CountryColors[countryName]
end

function TileOwnershipManager.getPlayerColor(player)
	getDependencies()
	local playerCountry = TileManager.getPlayerCountry(player)
	if playerCountry then
		return CountryColors[playerCountry]
	end
	return nil
end

function TileOwnershipManager.getOriginalColor(tilePart)
	return OriginalColors[tilePart]
end

---------------------------------------------------
-- FIX v3: Country-based Occupation System
---------------------------------------------------

-- Check if a tile is occupied by a specific COUNTRY
function TileOwnershipManager.isOccupiedByCountry(tilePart, countryName)
	local data = OccupiedTerritories[tilePart]
	return data and data.occupyingCountry == countryName
end

-- Check if a tile is occupied by a specific PLAYER's country
function TileOwnershipManager.isOccupiedBy(tilePart, player)
	getDependencies()
	if not player then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	return TileOwnershipManager.isOccupiedByCountry(tilePart, playerCountry)
end

-- Check if a tile is occupied by anyone
function TileOwnershipManager.isOccupied(tilePart)
	return OccupiedTerritories[tilePart] ~= nil
end

-- Get which COUNTRY occupies a tile
function TileOwnershipManager.getOccupyingCountry(tilePart)
	local data = OccupiedTerritories[tilePart]
	return data and data.occupyingCountry
end

-- Get the original country of an occupied tile
function TileOwnershipManager.getOriginalCountry(tilePart)
	getDependencies()
	local data = OccupiedTerritories[tilePart]
	if data then
		return data.originalCountry
	end
	return TileAdjacencyManager.getTileCountry(tilePart)
end

-- FIX v3: Check if tile belongs to a country (own territory OR occupied by them)
function TileOwnershipManager.tileEffectivelyBelongsTo(tilePart, countryName)
	getDependencies()

	if not tilePart or not countryName then return false end

	-- Check if it's their home territory
	local tileCountry = TileAdjacencyManager.getTileCountry(tilePart)
	if tileCountry == countryName then
		return true
	end

	-- Check if they've occupied it
	return TileOwnershipManager.isOccupiedByCountry(tilePart, countryName)
end

-- FIX v3: Check if tile belongs to player's country
function TileOwnershipManager.tileBelongsToPlayer(tilePart, player)
	getDependencies()
	if not player then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	return TileOwnershipManager.tileEffectivelyBelongsTo(tilePart, playerCountry)
end

-- FIX v3: Capture a tile (store by country, not player)
function TileOwnershipManager.captureTile(tilePart, player)
	getDependencies()

	if not tilePart or not player then return false end

	local originalCountry = TileAdjacencyManager.getTileCountry(tilePart)
	local playerCountry = TileManager.getPlayerCountry(player)

	if not playerCountry then
		warn("[TileOwnership] Player has no country")
		return false
	end

	-- Don't capture your own tiles
	if originalCountry == playerCountry then
		return false
	end

	-- Don't re-capture already occupied tiles by same country
	if TileOwnershipManager.isOccupiedByCountry(tilePart, playerCountry) then
		return false
	end

	-- Get occupying country's color
	local occupyingColor = CountryColors[playerCountry]
	if not occupyingColor then
		warn("[TileOwnership] Could not get color for country " .. playerCountry)
		return false
	end

	-- Preserve original data if tile is already occupied by another country
	-- This ensures peace treaties revert to the true original owner's color
	local existingOccupation = OccupiedTerritories[tilePart]
	local storedOriginalCountry, storedOriginalColor

	if existingOccupation then
		storedOriginalCountry = existingOccupation.originalCountry
		storedOriginalColor = existingOccupation.originalColor
	else
		storedOriginalCountry = originalCountry
		storedOriginalColor = OriginalColors[tilePart] or tilePart.Color
	end

	OccupiedTerritories[tilePart] = {
		occupyingCountry = playerCountry,
		originalCountry = storedOriginalCountry,
		originalColor = storedOriginalColor
	}

	-- Change tile color
	tilePart.Color = occupyingColor

	if DEBUG then
		print("[TileOwnership] " .. playerCountry .. " captured tile in " .. originalCountry)
	end

	-- Fire event to notify clients
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
	end

	return true
end

-- Release a captured tile (revert color)
function TileOwnershipManager.releaseTile(tilePart)
	local data = OccupiedTerritories[tilePart]
	if not data then return false end

	-- Revert color
	tilePart.Color = data.originalColor

	-- Remove from tracking
	OccupiedTerritories[tilePart] = nil

	if DEBUG then
		print("[TileOwnership] Released tile back to " .. data.originalCountry)
	end

	return true
end

-- Reclaim a tile that was occupied by an enemy back to its original owner
function TileOwnershipManager.reclaimTile(tilePart, player)
	getDependencies()

	if not tilePart or not player then return false end

	local data = OccupiedTerritories[tilePart]
	if not data then return false end

	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return false end

	-- Only reclaim if the tile's original country matches the player's country
	if data.originalCountry ~= playerCountry then
		return false
	end

	-- Revert tile color to the original color
	tilePart.Color = data.originalColor

	local occupyingCountry = data.occupyingCountry

	-- Remove from occupation tracking
	OccupiedTerritories[tilePart] = nil

	if DEBUG then
		print("[TileOwnership] " .. playerCountry .. " reclaimed tile from " .. occupyingCountry)
	end

	-- Notify the reclaiming player
	local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
	if GlobalNotificationEvent then
		GlobalNotificationEvent:FireClient(player, "Territory reclaimed from " .. occupyingCountry .. "!", Color3.fromRGB(100, 255, 100))
	end

	-- Fire tile captured event for UI updates
	local TileCapturedEvent = ReplicatedStorage:FindFirstChild("TileCapturedEvent")
	if TileCapturedEvent then
		TileCapturedEvent:FireAllClients(tilePart, player.Name, playerCountry)
	end

	return true
end

-- Release all tiles occupied by a specific COUNTRY (used in peace treaties)
function TileOwnershipManager.releaseCountryOccupiedTiles(countryName)
	local releasedCount = 0

	-- FIX: Collect keys first to avoid modifying table during pairs() iteration
	local tilesToRelease = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tilesToRelease, tilePart)
		end
	end

	-- Now iterate over the collected keys to release tiles
	for _, tilePart in ipairs(tilesToRelease) do
		local data = OccupiedTerritories[tilePart]
		if data and tilePart and tilePart.Parent then
			tilePart.Color = data.originalColor
		end
		OccupiedTerritories[tilePart] = nil
		releasedCount = releasedCount + 1
	end

	if DEBUG and releasedCount > 0 then
		print("[TileOwnership] Released " .. releasedCount .. " tiles from " .. countryName)
	end

	return releasedCount
end

-- Get all tiles occupied by a specific COUNTRY
function TileOwnershipManager.getCountryOccupiedTiles(countryName)
	local tiles = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			table.insert(tiles, tilePart)
		end
	end
	return tiles
end

-- Get count of tiles occupied by a country
function TileOwnershipManager.getCountryOccupiedCount(countryName)
	local count = 0
	for _, data in pairs(OccupiedTerritories) do
		if data.occupyingCountry == countryName then
			count = count + 1
		end
	end
	return count
end

-- Legacy: Get tiles occupied by player (uses their country)
function TileOwnershipManager.getPlayerOccupiedTiles(player)
	getDependencies()
	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return {} end
	return TileOwnershipManager.getCountryOccupiedTiles(playerCountry)
end

-- Legacy: Get count for player
function TileOwnershipManager.getOccupiedTileCount(player)
	getDependencies()
	local playerCountry = TileManager.getPlayerCountry(player)
	if not playerCountry then return 0 end
	return TileOwnershipManager.getCountryOccupiedCount(playerCountry)
end

---------------------------------------------------
-- Capital Capture & Country Takeover
---------------------------------------------------

function TileOwnershipManager.isCapitalBeingCaptured(countryName)
	return capitalsBeingCaptured[countryName] == true
end

function TileOwnershipManager.captureCapital(losingCountryName, winningPlayer)
	getDependencies()

	if not losingCountryName or not winningPlayer then return false end

	if capitalsBeingCaptured[losingCountryName] then
		if DEBUG then
			print("[TileOwnership] Capital capture already in progress for " .. losingCountryName)
		end
		return false
	end

	-- FIX v4: Check if the country is already conquered
	local CountryOwners = ServerState.getCountryOwners()
	local currentOwner = CountryOwners[losingCountryName]
	if type(currentOwner) == "string" and currentOwner:find("Conquered_") then
		if DEBUG then
			print("[TileOwnership] Cannot capture " .. losingCountryName .. " - already conquered by " .. currentOwner)
		end
		return false
	end

	capitalsBeingCaptured[losingCountryName] = true

	local losingPlayer = currentOwner
	local winningCountry = TileManager.getPlayerCountry(winningPlayer)

	print("[TileOwnership] CAPITAL CAPTURED! " .. winningPlayer.Name .. " (" .. winningCountry .. ") conquered " .. losingCountryName)

	local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
	if GlobalNotificationEvent then
		local msg = "👑 CONQUEST! " .. winningCountry .. " has conquered " .. losingCountryName .. "!"
		GlobalNotificationEvent:FireAllClients(msg, Color3.fromRGB(255, 215, 0))
	end

	TileOwnershipManager.performCountryTakeover(losingCountryName, winningPlayer, losingPlayer)

	-- Clear the guard after takeover is fully complete (not on a timer)
	capitalsBeingCaptured[losingCountryName] = nil

	return true
end

function TileOwnershipManager.performCountryTakeover(losingCountryName, winningPlayer, losingPlayer)
	getDependencies()

	local winningCountry = TileManager.getPlayerCountry(winningPlayer)
	local winningColor = CountryColors[winningCountry]

	-- 1. TRANSFER ALL TILES (change colors permanently)
	local countryModel = EUROPE_MAP:FindFirstChild(losingCountryName)
	if countryModel then
		for _, part in ipairs(countryModel:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Color = winningColor
				OriginalColors[part] = winningColor
				OccupiedTerritories[part] = nil
			end
		end
	end

	-- Release any tiles occupied BY other countries IN the losing country's territory
	-- FIX: Revert tile colors to the conquering country's color before removing from tracking
	-- FIX: Collect keys first to avoid modifying table during pairs() iteration
	local occupiedTilesToRelease = {}
	for tilePart, data in pairs(OccupiedTerritories) do
		if data.originalCountry == losingCountryName then
			table.insert(occupiedTilesToRelease, tilePart)
		end
	end

	for _, tilePart in ipairs(occupiedTilesToRelease) do
		if tilePart and tilePart.Parent then
			tilePart.Color = winningColor
		end
		OccupiedTerritories[tilePart] = nil
	end

	-- Release any tiles the LOSING country had occupied FROM other countries
	-- These revert to their original owners' colors
	TileOwnershipManager.releaseCountryOccupiedTiles(losingCountryName)

	-- 2. TRANSFER RESOURCES
	if losingPlayer and typeof(losingPlayer) == "Instance" and losingPlayer:IsA("Player") and losingPlayer.Parent then
		local loserStats = losingPlayer:FindFirstChild("leaderstats")
		local winnerStats = winningPlayer:FindFirstChild("leaderstats")

		-- FIX: Added proper nil checks for loserStats and winnerStats
		if loserStats and winnerStats then
			local loserCoins = loserStats:FindFirstChild("Coins")
			local winnerCoins = winnerStats:FindFirstChild("Coins")
			if loserCoins and winnerCoins then
				winnerCoins.Value = winnerCoins.Value + loserCoins.Value
				loserCoins.Value = 0
			end

			local loserManpower = loserStats:FindFirstChild("Manpower")
			local winnerManpower = winnerStats:FindFirstChild("Manpower")
			if loserManpower and winnerManpower then
				winnerManpower.Value = winnerManpower.Value + loserManpower.Value
				loserManpower.Value = 0
			end
		elseif DEBUG then
			warn("[TileOwnership] Could not transfer resources - leaderstats missing")
		end
	else
		-- Country was unowned - transfer from ServerState
		local countryCoins = ServerState.getCountryCoins(losingCountryName)
		local countryManpower = ServerState.getCountryManpower(losingCountryName)

		local winnerStats = winningPlayer:FindFirstChild("leaderstats")
		if winnerStats then
			local winnerCoins = winnerStats:FindFirstChild("Coins")
			local winnerManpower = winnerStats:FindFirstChild("Manpower")

			if winnerCoins then
				winnerCoins.Value = winnerCoins.Value + countryCoins
			end
			if winnerManpower then
				winnerManpower.Value = winnerManpower.Value + countryManpower
			end
		end

		ServerState.setCountryCoins(losingCountryName, 0)
		ServerState.setCountryManpower(losingCountryName, 0)
	end

	-- 3. TRANSFER NPCs
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChild("Humanoid") and child:FindFirstChild("NPCOwner") then
			local npcCountry = child:GetAttribute("Country")
			if npcCountry == losingCountryName then
				local ownerValue = child:FindFirstChild("NPCOwner")
				if ownerValue then
					ownerValue.Value = winningPlayer
				end
				child:SetAttribute("Country", winningCountry)
				Combat.transferOwnership(child, winningPlayer)

				-- Recolor NPC to winning country's color
				if winningColor then
					for _, part in ipairs(child:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Color = winningColor
						end
					end
				end

				if DEBUG then
					print("[TileOwnership] Transferred NPC " .. child.Name .. " to " .. winningPlayer.Name)
				end
			end
		end
	end

	-- 4. UPDATE COUNTRY OWNERSHIP
	local CountryOwners = ServerState.getCountryOwners()
	CountryOwners[losingCountryName] = "Conquered_" .. winningCountry
	ServerState.setCountryOwners(CountryOwners)

	-- FIX v4: Clear all wars involving the conquered country
	DiplomacyManager.clearAllWarsForCountry(losingCountryName)

	-- 5. HANDLE LOSING PLAYER
	if losingPlayer and typeof(losingPlayer) == "Instance" and losingPlayer:IsA("Player") and losingPlayer.Parent then
		local loserStats = losingPlayer:FindFirstChild("leaderstats")
		if loserStats then
			local countryStat = loserStats:FindFirstChild("Country")
			if countryStat then
				countryStat.Value = "Defeated"
			end
		end

		if losingPlayer.Character then
			local humanoid = losingPlayer.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end

		local GlobalNotificationEvent = ReplicatedStorage:FindFirstChild("GlobalNotificationEvent")
		if GlobalNotificationEvent then
			GlobalNotificationEvent:FireClient(losingPlayer, "💀 Your capital has fallen! You have been defeated.", Color3.fromRGB(255, 0, 0))
		end

		TileManager.updatePlayerCountryCache(losingPlayer, nil)
	end

	print("[TileOwnership] Country takeover complete: " .. losingCountryName .. " -> " .. winningCountry)
end

---------------------------------------------------
-- Initialize
---------------------------------------------------

scanCountryColors()

-- FIX v3: Do NOT auto-release on player leave - territories persist!

print("[TileOwnershipManager] Initialization complete")

return TileOwnershipManager