-- TileManager (ModuleScript)
-- Now uses centralized TileKeyUtils for consistent tile key generation
-- Added: Global tile occupation tracking for movement system
-- Added: Helper functions for checking tile occupation by player
-- TileId is 100% authoritative for all occupancy reads and writes.
-- Positional key maps (GlobalOccupiedTiles, OccupiedTiles[country][key])
-- are DEBUG mirrors only — never read by gameplay logic.

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local EUROPE_MAP = Workspace:WaitForChild("EuropeMap", 10)

local TileManager = {}
local DEBUG = false
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

-- OCCUPIED TILES (by country): { [countryName] = { [tileId] = npcModel } }
-- Now keyed by tileId (not positional tileKey).
local OccupiedTiles = {}

-- DEBUG MIRROR — positional-key global table.
-- MUST NOT be read by gameplay logic. Maintained only for debugging convenience.
-- All occupancy reads must use GlobalOccupiedTilesById.
local GlobalOccupiedTiles = {} -- DEBUG ONLY — not read by gameplay logic

-- AUTHORITATIVE global occupancy map: { [tileId] = npcModel }
-- This is the ONLY table that gameplay logic reads for occupancy.
local GlobalOccupiedTilesById = {}

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
		if DEBUG then print(string.format("[TileManager] %s: Using center fallback (1 tile)", countryName)) end
	else
		if DEBUG then print(string.format("[TileManager] %s: %d valid tiles found, total area: %.0f", countryName, validCount, totalArea)) end
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
	if DEBUG then print("[TileManager] All countries scanned.") end
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
		if DEBUG then print(string.format("[TileManager] Cache updated: %s -> %s", player.Name, countryName)) end
	else
		PlayerCountryCache[player] = nil
		if DEBUG then print(string.format("[TileManager] Cache cleared for: %s", player.Name)) end
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
	if DEBUG then print("[TileManager] Cache rebuilt from ServerState") end
end

---------------------------------------------------
-- Core API
---------------------------------------------------

function TileManager.getSpawnPosition(player)
	local countryName = TileManager.getPlayerCountry(player)
	if not countryName then return nil end

	local tiles = ValidTiles[countryName]
	if not tiles or #tiles == 0 then return nil end

	local TOM = getTileOwnershipManager()
	local TAM = getTileAdjacencyManager()

	local function getSafeSpawnPos(tilePart, fallbackPos)
		if tilePart then
			local safeCenter = TAM.getSafeCenter(tilePart)
			if safeCenter then return safeCenter end
		end
		return fallbackPos
	end

	-- Check if a tile is occupied by an enemy country (diplomatic occupation, not NPC occupancy)
	local function isEnemyDiplomaticOccupied(tilePart)
		if not tilePart then return false end
		if TOM.isOccupied(tilePart) and not TOM.isOccupiedByCountry(tilePart, countryName) then
			return true
		end
		return false
	end

	-- Build unified pool of all available tiles (home + conquered)
	local allCandidates = {}

	-- Add home tiles: filter out NPC-occupied tiles (by TileId) and enemy-occupied tiles
	for _, tilePos in ipairs(tiles) do
		local tileKey = getTileKey(tilePos)
		local tilePart = TAM.getTileFromKey(tileKey)
		local tileId = tilePart and TAM.getTileId(tilePart)
		-- Skip tiles with standing NPCs (TileId-authoritative) or enemy diplomatic occupants
		if not TileManager.isTileOccupiedById(tileId) and not isEnemyDiplomaticOccupied(tilePart) then
			table.insert(allCandidates, { tilePart = tilePart, tileKey = tileKey, pos = tilePos })
		end
	end

	-- Add conquered/occupied territory tiles: filter by TileId occupancy
	local conqueredTiles = TOM.getCountryOccupiedTiles(countryName)
	for _, tilePart in ipairs(conqueredTiles) do
		if tilePart and tilePart.Parent then
			local tileId = TAM.getTileId(tilePart)
			if not TileManager.isTileOccupiedById(tileId) then
				local spawnPos = tilePart.Position + Vector3.new(0, tilePart.Size.Y / 2 + 3, 0)
				local tileKey = getTileKey(tilePart.Position)
				table.insert(allCandidates, { tilePart = tilePart, tileKey = tileKey, pos = spawnPos })
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
	return getSafeSpawnPos(chosen.tilePart, chosen.pos), chosen.tileKey
end

---------------------------------------------------
-- Authoritative Occupancy API (TileId-based)
-- These are the preferred low-level occupancy functions.
-- All other occupancy functions must delegate to these.
---------------------------------------------------

-- PRIMARY: Occupy a tile using a pre-resolved tilePart.
-- Always writes to GlobalOccupiedTilesById (authoritative) and OccupiedTiles[country] (by tileId).
-- GlobalOccupiedTiles is updated as a DEBUG mirror only.
function TileManager.occupyResolvedTile(countryName, tilePart, npcModel)
	local TAM = getTileAdjacencyManager()
	local tileId = TAM.getTileId(tilePart)
	if not tileId then
		warn("[TileManager] occupyResolvedTile: no TileId for part '" .. tilePart.Name .. "' — occupancy not registered")
		return
	end

	-- Authoritative write
	GlobalOccupiedTilesById[tileId] = npcModel

	-- Country-local write (keyed by tileId, not positional key)
	if countryName then
		if not OccupiedTiles[countryName] then
			OccupiedTiles[countryName] = {}
		end
		OccupiedTiles[countryName][tileId] = npcModel
	end

	-- DEBUG mirror: update positional-key map for tooling/inspection
	GlobalOccupiedTiles[getTileKey(tilePart.Position)] = npcModel
end

-- PRIMARY: Release a tile using a pre-resolved tilePart.
function TileManager.releaseResolvedTile(countryName, tilePart)
	local TAM = getTileAdjacencyManager()
	local tileId = TAM.getTileId(tilePart)
	if not tileId then
		warn("[TileManager] releaseResolvedTile: no TileId for part '" .. tilePart.Name .. "' — occupancy not cleared")
		return
	end

	-- Authoritative clear
	GlobalOccupiedTilesById[tileId] = nil

	-- Country-local clear
	if countryName and OccupiedTiles[countryName] then
		OccupiedTiles[countryName][tileId] = nil
	end

	-- DEBUG mirror
	GlobalOccupiedTiles[getTileKey(tilePart.Position)] = nil
end

-- Occupy a tile by tileId directly (lowest-level write, no resolution needed).
function TileManager.occupyTileById(tileId, npcModel)
	if not tileId then return end
	GlobalOccupiedTilesById[tileId] = npcModel
end

-- Release a tile by tileId directly.
function TileManager.releaseTileById(tileId)
	if not tileId then return end
	GlobalOccupiedTilesById[tileId] = nil
end

-- Get the NPC occupying a tile by tileId (authoritative read).
function TileManager.getTileOccupantById(tileId)
	if not tileId then return nil end
	return GlobalOccupiedTilesById[tileId]
end

-- Check if a tile is occupied by tileId (authoritative read).
function TileManager.isTileOccupiedById(tileId)
	if not tileId then return false end
	return GlobalOccupiedTilesById[tileId] ~= nil
end

---------------------------------------------------
-- Compatibility Shims (tileKey-based)
-- These resolve tilePart from the legacy tileKey and delegate to the
-- TileId-authoritative functions above. Use only when tilePart is not already available.
---------------------------------------------------

-- Resolve tilePart from tileKey (tries primary lookup then fallback).
local function resolveTilePartFromKey(tileKey)
	local TAM = getTileAdjacencyManager()
	local tilePart = TAM.getTileFromKey(tileKey)
	if not tilePart and TAM.getTileFromKeyWithFallback then
		tilePart = TAM.getTileFromKeyWithFallback(tileKey)
	end
	return tilePart
end

-- Compatibility shim: resolves tilePart from tileKey, then calls occupyResolvedTile.
-- Prefer occupyResolvedTile when tilePart is already available.
function TileManager.occupyTile(countryName, tileKey, npcModel)
	local tilePart = resolveTilePartFromKey(tileKey)
	if not tilePart then
		warn("[TileManager] occupyTile: could not resolve tilePart for key '" .. tostring(tileKey) .. "' — occupancy not registered")
		return
	end
	TileManager.occupyResolvedTile(countryName, tilePart, npcModel)
end

-- Compatibility shim: resolves tilePart from tileKey, then calls releaseResolvedTile.
-- Prefer releaseResolvedTile when tilePart is already available.
function TileManager.releaseTile(countryName, tileKey)
	local tilePart = resolveTilePartFromKey(tileKey)
	if not tilePart then
		warn("[TileManager] releaseTile: could not resolve tilePart for key '" .. tostring(tileKey) .. "' — occupancy not cleared")
		return
	end
	TileManager.releaseResolvedTile(countryName, tilePart)
end

---------------------------------------------------
-- Global Tile Occupation (for movement system)
---------------------------------------------------

-- Occupy a tile globally (regardless of country).
-- Compatibility shim: resolves tilePart and country from tileKey/npcModel, then calls occupyResolvedTile.
-- Prefer occupyResolvedTile with an explicit countryName when possible.
function TileManager.occupyTileGlobal(tileKey, npcModel)
	local tilePart = resolveTilePartFromKey(tileKey)
	if not tilePart then
		warn("[TileManager] occupyTileGlobal: could not resolve tilePart for key '" .. tostring(tileKey) .. "'")
		return
	end
	local npcCountry = npcModel:GetAttribute("Country")
	TileManager.occupyResolvedTile(npcCountry, tilePart, npcModel)
end

-- Release a tile globally.
-- Compatibility shim: resolves tilePart and country, then calls releaseResolvedTile.
function TileManager.releaseTileGlobal(tileKey)
	local tilePart = resolveTilePartFromKey(tileKey)
	if not tilePart then
		-- Fallback: clear DEBUG mirror at least
		GlobalOccupiedTiles[tileKey] = nil
		warn("[TileManager] releaseTileGlobal: could not resolve tilePart for key '" .. tostring(tileKey) .. "'")
		return
	end
	-- Determine country from authoritative occupant
	local TAM = getTileAdjacencyManager()
	local tileId = TAM.getTileId(tilePart)
	local npcModel = (tileId and GlobalOccupiedTilesById[tileId]) or GlobalOccupiedTiles[tileKey]
	local npcCountry = npcModel and npcModel:GetAttribute("Country")
	TileManager.releaseResolvedTile(npcCountry, tilePart)
end

-- Check if a tile is occupied globally (TileId-authoritative).
-- Compatibility shim for callers that only have a tileKey.
function TileManager.isTileOccupied(tileKey)
	local tilePart = resolveTilePartFromKey(tileKey)
	if not tilePart then return false end
	local TAM = getTileAdjacencyManager()
	local tileId = TAM.getTileId(tilePart)
	return TileManager.isTileOccupiedById(tileId)
end

-- Get the NPC occupying a tile (TileId-authoritative).
-- Compatibility shim for callers that only have a tileKey.
function TileManager.getTileOccupant(tileKey)
	local tilePart = resolveTilePartFromKey(tileKey)
	if not tilePart then return nil end
	local TAM = getTileAdjacencyManager()
	local tileId = TAM.getTileId(tilePart)
	return TileManager.getTileOccupantById(tileId)
end

-- Check if a tile is occupied by a specific player's NPC (TileId-authoritative).
function TileManager.isTileOccupiedByPlayer(tileKey, player)
	local npc = TileManager.getTileOccupant(tileKey)
	if not npc then return false end

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
	if not tiles then return 0 end

	local TAM = getTileAdjacencyManager()
	local available = 0
	for _, tilePos in ipairs(tiles) do
		local tileKey = getTileKey(tilePos)
		local tilePart = TAM.getTileFromKey(tileKey)
		local tileId = tilePart and TAM.getTileId(tilePart)
		-- isTileOccupiedById returns false for nil tileId (counts unresolvable tiles as available)
		if not TileManager.isTileOccupiedById(tileId) then
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
