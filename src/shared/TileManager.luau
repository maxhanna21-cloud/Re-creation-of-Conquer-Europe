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
-- TileId-primary occupancy map (enabled conditionally when positional key ambiguity is high)
local GlobalOccupiedTilesById = {}
local UseTileIdOccupancy = nil

-- Tile statistics for manpower calculation
-- { [countryName] = { tileCount = N, totalArea = X, avgArea = Y } }
local CountryTileStats = {}

-- Player → Country cache for O(1) lookups
-- { [Player] = countryName }
local PlayerCountryCache = {}

-- FIX: Capital tile registry (keyed by country Model instance for immutability)
-- { [countryModel] = capitalTilePart }
local CapitalTilesByModel = {}

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

local function shouldUseTileIdOccupancy()
	if UseTileIdOccupancy ~= nil then
		return UseTileIdOccupancy
	end

	local tam = getTileAdjacencyManager()
	local ambiguous = 0
	if tam.getAmbiguousPositionalBucketCount then
		ambiguous = tam.getAmbiguousPositionalBucketCount() or 0
	end
	UseTileIdOccupancy = ambiguous > 10
	print(string.format("[TileManager] TileId occupancy gate: ambiguous positional buckets=%d -> %s",
		ambiguous, UseTileIdOccupancy and "ENABLED" or "DISABLED"))
	return UseTileIdOccupancy
end

local function getTileIdFromKey(tileKey)
	if not tileKey then return nil end
	local tam = getTileAdjacencyManager()
	local tilePart = tam.getTileFromKey(tileKey)
	if not tilePart then
		tilePart = tam.getTileFromKeyWithFallback(tileKey)
	end
	return tam.getTileId(tilePart)
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
				-- FIX: Register this tile as the country's capital (keyed by Model instance)
				CapitalTilesByModel[countryModel] = part
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

	local function isEnemyOccupied(tileKey)
		local tilePart = TAM.getTileFromKey(tileKey)
		if not tilePart then return false end
		if TOM.isOccupied(tilePart) and not TOM.isOccupiedByCountry(tilePart, countryName) then
			return true
		end
		return false
	end

	-- Build unified pool of all available tiles (home + conquered)
	local allCandidates = {}

	-- Add home tiles
	for _, tilePos in ipairs(tiles) do
		local key = getTileKey(tilePos)
		if not occupied[key] and not isEnemyOccupied(key) then
			table.insert(allCandidates, { key = key, pos = tilePos })
		end
	end

	-- Add conquered/occupied territory tiles
	local conqueredTiles = TOM.getCountryOccupiedTiles(countryName)
	for _, tilePart in ipairs(conqueredTiles) do
		if tilePart and tilePart.Parent then
			local spawnPos = tilePart.Position + Vector3.new(0, tilePart.Size.Y / 2 + 3, 0)
			local key = getTileKey(spawnPos)
			if not GlobalOccupiedTiles[key] then
				table.insert(allCandidates, { key = key, pos = spawnPos })
			end
		end
	end

	if #allCandidates == 0 then
		warn("[TileManager] " .. countryName .. " is full!")
		return nil
	end

	-- Shuffle all candidates uniformly
	for i = #allCandidates, 2, -1 do
		local j = math.random(1, i)
		allCandidates[i], allCandidates[j] = allCandidates[j], allCandidates[i]
	end

	local chosen = allCandidates[1]
	return getSafeSpawnPos(chosen.key, chosen.pos), chosen.key
end

-- Occupy a tile within a country
function TileManager.occupyTile(countryName, tileKey, npcModel)
	if not OccupiedTiles[countryName] then
		OccupiedTiles[countryName] = {}
	end
	OccupiedTiles[countryName][tileKey] = npcModel

	-- Also update global tracking
	GlobalOccupiedTiles[tileKey] = npcModel
	if shouldUseTileIdOccupancy() then
		local tileId = getTileIdFromKey(tileKey)
		if tileId then
			GlobalOccupiedTilesById[tileId] = npcModel
		end
	end
end

-- Release a tile within a country
function TileManager.releaseTile(countryName, tileKey)
	if OccupiedTiles[countryName] then
		OccupiedTiles[countryName][tileKey] = nil
	end

	-- Also update global tracking
	GlobalOccupiedTiles[tileKey] = nil
	if shouldUseTileIdOccupancy() then
		local tileId = getTileIdFromKey(tileKey)
		if tileId then
			GlobalOccupiedTilesById[tileId] = nil
		end
	end
end

---------------------------------------------------
-- Global Tile Occupation (for movement system)
---------------------------------------------------

-- Occupy a tile globally (regardless of country)
function TileManager.occupyTileGlobal(tileKey, npcModel)
	GlobalOccupiedTiles[tileKey] = npcModel
	if shouldUseTileIdOccupancy() then
		local tileId = getTileIdFromKey(tileKey)
		if tileId then
			GlobalOccupiedTilesById[tileId] = npcModel
		end
	end

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
	if shouldUseTileIdOccupancy() then
		local tileId = getTileIdFromKey(tileKey)
		if tileId then
			GlobalOccupiedTilesById[tileId] = nil
		end
	end

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
	if shouldUseTileIdOccupancy() then
		local tileId = getTileIdFromKey(tileKey)
		if tileId and GlobalOccupiedTilesById[tileId] ~= nil then
			return true
		end
	end
	return GlobalOccupiedTiles[tileKey] ~= nil
end

-- Get the NPC occupying a tile
function TileManager.getTileOccupant(tileKey)
	if shouldUseTileIdOccupancy() then
		local tileId = getTileIdFromKey(tileKey)
		if tileId and GlobalOccupiedTilesById[tileId] then
			return GlobalOccupiedTilesById[tileId]
		end
	end
	return GlobalOccupiedTiles[tileKey]
end

-- Check if a tile is occupied by a specific player's NPC
function TileManager.isTileOccupiedByPlayer(tileKey, player)
	local npc = TileManager.getTileOccupant(tileKey)
	if not npc then return false end

	-- Check if NPC is owned by this player
	local ownerVal = npc:FindFirstChild("NPCOwner")
	if ownerVal and ownerVal.Value == player then
		return true
	end

	return false
end

function TileManager.occupyTileById(tileId, npcModel)
	if not tileId then return end
	GlobalOccupiedTilesById[tileId] = npcModel
end

function TileManager.releaseTileById(tileId)
	if not tileId then return end
	GlobalOccupiedTilesById[tileId] = nil
end

function TileManager.getTileOccupantById(tileId)
	if not tileId then return nil end
	return GlobalOccupiedTilesById[tileId]
end

function TileManager.isTileOccupiedById(tileId)
	if not tileId then return false end
	return GlobalOccupiedTilesById[tileId] ~= nil
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
-- FIX: Capital Tile Registry API
---------------------------------------------------

-- Get the capital tile for a country by its Model instance (primary API)
function TileManager.getCountryCapitalByModel(countryModel)
	return CapitalTilesByModel[countryModel]
end

-- Get the capital tile for a country by name (convenience wrapper)
function TileManager.getCountryCapital(countryName)
	local countryModel = EUROPE_MAP:FindFirstChild(countryName)
	if not countryModel then return nil end
	return CapitalTilesByModel[countryModel]
end

---------------------------------------------------
-- Player Cleanup
---------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
	TileManager.clearPlayerCache(player)
end)

initializeAllCountries()

return TileManager
