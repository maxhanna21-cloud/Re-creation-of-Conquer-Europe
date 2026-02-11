-- TileManager (ModuleScript - ACTUAL TILES VERSION) - UPDATED v4
-- FIX: Now uses centralized TileKeyUtils for consistent tile key generation
-- Added: Global tile occupation tracking for movement system
-- Added: Helper functions for checking tile occupation by player

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

local TileManager = {}
local ServerState = require(game:GetService("ServerScriptService"):WaitForChild("ServerState", 10))

-- FIX: Use centralized tile key utility
local TileKeyUtils = require(game:GetService("ServerScriptService"):WaitForChild("TileKeyUtils", 10))

-- Lazy-load dependencies to avoid circular requires
local TileOwnershipManager = nil
local function getTileOwnershipManager()
	if not TileOwnershipManager then
		TileOwnershipManager = require(game:GetService("ServerScriptService"):WaitForChild("TileOwnershipManager", 10))
	end
	return TileOwnershipManager
end

local TileAdjacencyManager = nil
local function getTileAdjacencyManager()
	if not TileAdjacencyManager then
		TileAdjacencyManager = require(game:GetService("ServerScriptService"):WaitForChild("TileAdjacencyManager", 10))
	end
	return TileAdjacencyManager
end

-- VALID TILES CACHE: { [countryName] = { Vector3, Vector3, ... } }
local ValidTiles = {}

-- OCCUPIED TILES (by country): { [countryName] = { ["x,z"] = npcModel } }
local OccupiedTiles = {}

-- NEW: GLOBAL TILE OCCUPATION (for movement system): { ["x,z"] = npcModel }
local GlobalOccupiedTiles = {}

-- Tile statistics for manpower calculation
-- { [countryName] = { tileCount = N, totalArea = X, avgArea = Y } }
local CountryTileStats = {}

-- Player → Country cache for O(1) lookups
-- { [Player] = countryName }
local PlayerCountryCache = {}

---------------------------------------------------
-- FIX: Use centralized getTileKey function
---------------------------------------------------
local function getTileKey(position)
	return TileKeyUtils.getTileKey(position)
end

-- Expose getTileKey for external use (delegates to TileKeyUtils)
function TileManager.getTileKey(position)
	return TileKeyUtils.getTileKey(position)
end

-- Get the tile key from a BasePart (tile)
function TileManager.getTileKeyFromPart(tilePart)
	return TileKeyUtils.getTileKeyFromPart(tilePart)
end

---------------------------------------------------
-- Initialization: Scan actual tile parts
---------------------------------------------------
local function scanCountryTiles(countryModel)
	local countryName = countryModel.Name
	ValidTiles[countryName] = {}
	OccupiedTiles[countryName] = {}

	local validCount = 0
	local capitalPos = nil
	local totalArea = 0

	-- Scan all BaseParts inside the country
	for _, part in ipairs(countryModel:GetDescendants()) do
		if part:IsA("BasePart") then
			local spawnPos = part.Position + Vector3.new(0, part.Size.Y / 2 + 3, 0)

			-- Calculate tile footprint area (X * Z)
			local tileArea = part.Size.X * part.Size.Z
			totalArea = totalArea + tileArea

			if part.Name == "Capital" then
				-- Store capital position separately
				capitalPos = spawnPos
			else
				table.insert(ValidTiles[countryName], spawnPos)
			end
			validCount += 1
		end
	end

	-- Insert Capital at the FRONT so it's used first
	if capitalPos then
		table.insert(ValidTiles[countryName], 1, capitalPos)
	end

	-- FALLBACK: If no parts found, use model center
	if validCount == 0 then
		local center = countryModel:GetPivot().Position + Vector3.new(0, 5, 0)
		table.insert(ValidTiles[countryName], center)
		validCount = 1
		totalArea = 100 -- Default area for fallback
		print(string.format("[TileManager] %s: Using center fallback (1 tile)", countryName))
	else
		print(string.format("[TileManager] %s: %d valid tiles found, total area: %.0f", countryName, validCount, totalArea))
	end

	-- Store tile statistics
	CountryTileStats[countryName] = {
		tileCount = validCount,
		totalArea = totalArea,
		avgArea = totalArea / validCount
	}
end

local function initializeAllCountries()
	for _, countryModel in ipairs(EUROPE_MAP:GetChildren()) do
		if countryModel:IsA("Model") then
			scanCountryTiles(countryModel)
		end
	end
	print("[TileManager] All countries scanned.")
end

---------------------------------------------------
-- Tile Statistics API
---------------------------------------------------

function TileManager.getCountryTileStats(countryName)
	return CountryTileStats[countryName]
end

function TileManager.getAllCountryTileStats()
	return CountryTileStats
end

---------------------------------------------------
-- Cache Management Functions
---------------------------------------------------

function TileManager.updatePlayerCountryCache(player, countryName)
	if countryName then
		PlayerCountryCache[player] = countryName
		print(string.format("[TileManager] Cache updated: %s -> %s", player.Name, countryName))
	else
		PlayerCountryCache[player] = nil
		print(string.format("[TileManager] Cache cleared for: %s", player.Name))
	end
end

function TileManager.clearPlayerCache(player)
	PlayerCountryCache[player] = nil
end

function TileManager.rebuildCache()
	PlayerCountryCache = {}
	local CountryOwners = ServerState.getCountryOwners()
	for countryName, owner in pairs(CountryOwners) do
		if typeof(owner) == "Instance" and owner:IsA("Player") then
			PlayerCountryCache[owner] = countryName
		end
	end
	print("[TileManager] Cache rebuilt from ServerState")
end

---------------------------------------------------
-- Core API
---------------------------------------------------

function TileManager.getSpawnPosition(player)
	local countryName = TileManager.getPlayerCountry(player)
	if not countryName then return nil end

	local tiles = ValidTiles[countryName]
	if not tiles or #tiles == 0 then return nil end

	local occupied = OccupiedTiles[countryName]

	-- Helper: resolve a tile key to a safe spawn position (rasterization centroid)
	local TOM = getTileOwnershipManager()
	local TAM = getTileAdjacencyManager()
	local function getSafeSpawnPos(tileKey, fallbackPos)
		local tilePart = TAM.getTileFromKey(tileKey)
		if tilePart then
			local safeCenter = TAM.getSafeCenter(tilePart)
			if safeCenter then return safeCenter end
		end
		return fallbackPos
	end

	-- Helper: check if a home tile is enemy-occupied (captured by another country)
	local function isEnemyOccupied(tileKey)
		local tilePart = TAM.getTileFromKey(tileKey)
		if not tilePart then return false end
		-- Check if tile is occupied AND not by our own country
		if TOM.isOccupied(tilePart) and not TOM.isOccupiedByCountry(tilePart, countryName) then
			return true
		end
		return false
	end

	-- Check Capital first (index 1)
	local capitalKey = getTileKey(tiles[1])
	if not occupied[capitalKey] and not isEnemyOccupied(capitalKey) then
		return getSafeSpawnPos(capitalKey, tiles[1]), capitalKey
	end

	-- Shuffle remaining tiles (skip index 1)
	local remaining = {}
	for i = 2, #tiles do
		table.insert(remaining, tiles[i])
	end

	for i = #remaining, 2, -1 do
		local j = math.random(1, i)
		remaining[i], remaining[j] = remaining[j], remaining[i]
	end

	for _, tilePos in ipairs(remaining) do
		local key = getTileKey(tilePos)
		if not occupied[key] and not isEnemyOccupied(key) then
			return getSafeSpawnPos(key, tilePos), key
		end
	end

	-- Also check occupied territory tiles (tiles captured from other countries)
	local occupiedTiles = TOM.getCountryOccupiedTiles(countryName)
	if #occupiedTiles > 0 then
		-- Shuffle for random placement
		for i = #occupiedTiles, 2, -1 do
			local j = math.random(1, i)
			occupiedTiles[i], occupiedTiles[j] = occupiedTiles[j], occupiedTiles[i]
		end

		for _, tilePart in ipairs(occupiedTiles) do
			if tilePart and tilePart.Parent then
				local spawnPos = tilePart.Position + Vector3.new(0, tilePart.Size.Y / 2 + 3, 0)
				local key = getTileKey(spawnPos)
				if not GlobalOccupiedTiles[key] then
					local safeCenter = TAM.getSafeCenter(tilePart)
					return safeCenter or spawnPos, key
				end
			end
		end
	end

	warn("[TileManager] " .. countryName .. " is full!")
	return nil
end

-- Occupy a tile within a country
function TileManager.occupyTile(countryName, tileKey, npcModel)
	if not OccupiedTiles[countryName] then
		OccupiedTiles[countryName] = {}
	end
	OccupiedTiles[countryName][tileKey] = npcModel

	-- Also update global tracking
	GlobalOccupiedTiles[tileKey] = npcModel
end

-- Release a tile within a country
function TileManager.releaseTile(countryName, tileKey)
	if OccupiedTiles[countryName] then
		OccupiedTiles[countryName][tileKey] = nil
	end

	-- Also update global tracking
	GlobalOccupiedTiles[tileKey] = nil
end

---------------------------------------------------
-- Global Tile Occupation (for movement system)
---------------------------------------------------

-- Occupy a tile globally (regardless of country)
function TileManager.occupyTileGlobal(tileKey, npcModel)
	GlobalOccupiedTiles[tileKey] = npcModel

	-- Also try to update country-specific tracking if we can determine the country
	local npcCountry = npcModel:GetAttribute("Country")
	if npcCountry then
		if not OccupiedTiles[npcCountry] then
			OccupiedTiles[npcCountry] = {}
		end
		OccupiedTiles[npcCountry][tileKey] = npcModel
	end
end

-- Release a tile globally
function TileManager.releaseTileGlobal(tileKey)
	local npcModel = GlobalOccupiedTiles[tileKey]
	GlobalOccupiedTiles[tileKey] = nil

	-- Also try to update country-specific tracking
	if npcModel then
		local npcCountry = npcModel:GetAttribute("Country")
		if npcCountry and OccupiedTiles[npcCountry] then
			OccupiedTiles[npcCountry][tileKey] = nil
		end
	end
end

-- Check if a tile is occupied globally
function TileManager.isTileOccupied(tileKey)
	return GlobalOccupiedTiles[tileKey] ~= nil
end

-- Get the NPC occupying a tile
function TileManager.getTileOccupant(tileKey)
	return GlobalOccupiedTiles[tileKey]
end

-- Check if a tile is occupied by a specific player's NPC
function TileManager.isTileOccupiedByPlayer(tileKey, player)
	local npc = GlobalOccupiedTiles[tileKey]
	if not npc then return false end

	-- Check if NPC is owned by this player
	local ownerVal = npc:FindFirstChild("NPCOwner")
	if ownerVal and ownerVal.Value == player then
		return true
	end

	return false
end

---------------------------------------------------
-- Existing API
---------------------------------------------------

function TileManager.getAvailableTileCount(countryName)
	local tiles = ValidTiles[countryName]
	local occupied = OccupiedTiles[countryName]
	if not tiles then return 0 end

	local available = 0
	for _, tilePos in ipairs(tiles) do
		local key = getTileKey(tilePos)
		if not occupied or not occupied[key] then
			available += 1
		end
	end
	return available
end

function TileManager.getPlayerCountry(player)
	-- First, try the cache (O(1) lookup)
	local cachedCountry = PlayerCountryCache[player]
	if cachedCountry then
		-- Verify it's still valid (in case ServerState changed without cache update)
		local CountryOwners = ServerState.getCountryOwners()
		if CountryOwners[cachedCountry] == player then
			return cachedCountry
		else
			-- Cache is stale, clear it
			PlayerCountryCache[player] = nil
		end
	end

	-- Fallback: iterate through all countries (O(n) but only on cache miss)
	local CountryOwners = ServerState.getCountryOwners()
	for countryName, owner in pairs(CountryOwners) do
		if owner == player then
			-- Update cache for next time
			PlayerCountryCache[player] = countryName
			return countryName
		end
	end
	return nil
end

function TileManager.getCountryModel(countryName)
	return EUROPE_MAP:FindFirstChild(countryName)
end

function TileManager.getAvailableCountries()
	local CountryOwners = ServerState.getCountryOwners()
	local list = {}
	for countryName, owner in pairs(CountryOwners) do
		if owner == "Unowned" then
			table.insert(list, countryName)
		end
	end
	return list
end

---------------------------------------------------
-- Player Cleanup
---------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
	TileManager.clearPlayerCache(player)
end)

initializeAllCountries()

return TileManager