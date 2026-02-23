-- ServerState (ModuleScript in ServerScriptService) - UPDATED v3
-- Centralized registry for shared server data
-- Now includes CountryCoins, CountryManpower, AND OccupiedTerritories

-- Module-level service references (evaluated once at require time, zero per-call overhead)
local RunService = game:GetService("RunService")

-- Rate-limit tracker for resolveTarget unknown-value warnings (one warn per unique pair)
local _warnedUnknown = {}

local ServerState = {
	CountryOwners = {},
	CountryCoins = {},       -- { ["France"] = 150, ["Germany"] = 0, ... }
	CountryManpower = {},    -- { ["France"] = 5000, ["Germany"] = 0, ... }
	OccupiedTerritories = {}, -- NEW: { [tilePart] = { occupier = Player, originalCountry = "Germany" } }
	PendingDiplomacyRequests = {} -- FIX: { [requestId] = { ... } }
}

---------------------------------------------------
-- Country Owners
---------------------------------------------------

function ServerState.setCountryOwners(ownersTable)
	ServerState.CountryOwners = ownersTable
end

function ServerState.getCountryOwners()
	-- CONTRACT: returns the actual CountryOwners table by reference (not a copy).
	-- All callers read the same live table. Do NOT change this to return a copy —
	-- doing so would let resolveTarget() and other callers silently diverge.
	return ServerState.CountryOwners
end

-- FIX: Resolve the actual controlling player for a country, following conquest chains
-- Example: France → Conquered_Germany → Conquered_Poland → PlayerPolish
-- Returns: Player instance if chain resolves to a player, nil otherwise
-- CRITICAL for multi-conquest scenarios (Bug 1 + Bug 2 fixes)
function ServerState.resolveCountryOwner(countryName)
	local seen = {} -- Cycle detection

	while true do
		local owner = ServerState.CountryOwners[countryName]

		-- If we found a Player, return it
		if typeof(owner) == "Instance" and owner:IsA("Player") then
			return owner
		end

		-- If it's not a string, we can't resolve further
		if type(owner) ~= "string" then
			return nil  -- Unowned or invalid
		end

		-- Try to extract the conquering country from "Conquered_X" format
		local conquerorCountry = owner:match("^Conquered_(.+)$")
		if not conquerorCountry then
			return nil  -- Not a conquest string
		end

		-- Cycle detection (shouldn't happen, but defensive)
		if seen[conquerorCountry] then
			warn("[ServerState] Cycle detected in conquest chain: " .. countryName)
			return nil
		end
		seen[conquerorCountry] = true

		-- Follow the chain to the conquering country
		countryName = conquerorCountry
	end
end

-- SERVER-ONLY: Resolve a country name through "Conquered_X" chains, returning
-- BOTH the canonical controlling country name AND the controlling Player (or nil).
--
-- Allowed CountryOwners values: Player instance | "Unowned" | "Conquered_X"
-- Unknown string values are warned once and returned as (countryName, nil) so
-- callers can still show a meaningful error instead of an opaque nil failure.
--
-- Returns: (canonicalCountryName: string, controllingPlayer: Player|nil)
--          (nil, nil) only on cycle detection or invalid input.
function ServerState.resolveTarget(countryName)
	-- Server-only guard (module-level RunService, zero per-call overhead)
	if RunService:IsClient() then
		error("[ServerState.resolveTarget] This function is server-only and must not be called on the client.")
	end

	-- Input validation
	if type(countryName) ~= "string" or countryName == "" then
		warn("[ServerState.resolveTarget] Invalid countryName: " .. tostring(countryName))
		return nil, nil
	end

	local owners = ServerState.getCountryOwners()  -- stable backing table by reference
	local seen = {}

	while true do
		-- Cycle guard on the CURRENT node (before following any link)
		if seen[countryName] then
			warn(("[ServerState.resolveTarget] Cycle detected at: %s"):format(countryName))
			return nil, nil
		end
		seen[countryName] = true

		local owner = owners[countryName]

		if typeof(owner) == "Instance" and owner:IsA("Player") then
			return countryName, owner        -- player-owned: both values known
		end
		if type(owner) ~= "string" then
			return countryName, nil          -- nil or unknown type: name resolved, no player
		end
		if owner == "Unowned" then
			return countryName, nil          -- unowned country
		end

		local conqueror = owner:match("^Conquered_(.+)$")
		if not conqueror then
			-- Unknown string — warn once per (countryName, owner) pair to avoid log spam
			local warnKey = countryName .. "|" .. owner
			if not _warnedUnknown[warnKey] then
				_warnedUnknown[warnKey] = true
				warn(("[ServerState.resolveTarget] Unknown owner value for '%s': '%s'")
					:format(countryName, owner))
			end
			return countryName, nil
		end

		countryName = conqueror  -- follow the chain
	end
end

function ServerState.isCountryUnowned(countryName)
	local owners = ServerState.getCountryOwners()
	return owners[countryName] == "Unowned"
end

---------------------------------------------------
-- Country Coins
---------------------------------------------------

function ServerState.setCountryCoins(countryName, amount)
	ServerState.CountryCoins[countryName] = amount
end

function ServerState.getCountryCoins(countryName)
	return ServerState.CountryCoins[countryName] or 0
end

function ServerState.addCountryCoins(countryName, amount)
	ServerState.CountryCoins[countryName] = (ServerState.CountryCoins[countryName] or 0) + amount
	return ServerState.CountryCoins[countryName]
end

function ServerState.getAllCountryCoins()
	return ServerState.CountryCoins
end

function ServerState.initializeCountryCoins(countryName, startingAmount)
	if ServerState.CountryCoins[countryName] == nil then
		ServerState.CountryCoins[countryName] = startingAmount or 0
	end
end

---------------------------------------------------
-- Country Manpower
---------------------------------------------------

function ServerState.setCountryManpower(countryName, amount)
	ServerState.CountryManpower[countryName] = amount
end

function ServerState.getCountryManpower(countryName)
	return ServerState.CountryManpower[countryName] or 0
end

function ServerState.addCountryManpower(countryName, amount)
	ServerState.CountryManpower[countryName] = (ServerState.CountryManpower[countryName] or 0) + amount
	return ServerState.CountryManpower[countryName]
end

function ServerState.getAllCountryManpower()
	return ServerState.CountryManpower
end

function ServerState.initializeCountryManpower(countryName, startingAmount)
	if ServerState.CountryManpower[countryName] == nil then
		ServerState.CountryManpower[countryName] = startingAmount or 0
	end
end

---------------------------------------------------
-- NEW: Occupied Territories
---------------------------------------------------

-- Add an occupied territory
function ServerState.addOccupiedTerritory(tilePart, occupier, originalCountry)
	ServerState.OccupiedTerritories[tilePart] = {
		occupier = occupier,
		originalCountry = originalCountry
	}
end

-- Remove an occupied territory
function ServerState.removeOccupiedTerritory(tilePart)
	ServerState.OccupiedTerritories[tilePart] = nil
end

-- Get occupation data for a tile
function ServerState.getOccupiedTerritory(tilePart)
	return ServerState.OccupiedTerritories[tilePart]
end

-- Get all occupied territories
function ServerState.getAllOccupiedTerritories()
	return ServerState.OccupiedTerritories
end

-- Check if a tile is occupied
function ServerState.isTileOccupied(tilePart)
	return ServerState.OccupiedTerritories[tilePart] ~= nil
end

-- Get all tiles occupied by a specific player
function ServerState.getPlayerOccupiedTerritories(player)
	local tiles = {}
	for tilePart, data in pairs(ServerState.OccupiedTerritories) do
		if data.occupier == player then
			table.insert(tiles, tilePart)
		end
	end
	return tiles
end

-- Clear all occupied territories for a player
-- FIX: Collect keys first to avoid modifying table during iteration
function ServerState.clearPlayerOccupiedTerritories(player)
	local tilesToRemove = {}
	for tilePart, data in pairs(ServerState.OccupiedTerritories) do
		if data.occupier == player then
			table.insert(tilesToRemove, tilePart)
		end
	end
	for _, tilePart in ipairs(tilesToRemove) do
		ServerState.OccupiedTerritories[tilePart] = nil
	end
end

-- Get count of territories a player has occupied
function ServerState.getPlayerOccupiedCount(player)
	local count = 0
	for _, data in pairs(ServerState.OccupiedTerritories) do
		if data.occupier == player then
			count = count + 1
		end
	end
	return count
end

---------------------------------------------------
-- FIX: Pending Diplomacy Requests
---------------------------------------------------

-- Store a pending diplomacy request
function ServerState.setPendingDiplomacyRequest(requestId, requestData)
	ServerState.PendingDiplomacyRequests[requestId] = requestData
end

-- Get a pending diplomacy request
function ServerState.getPendingDiplomacyRequest(requestId)
	return ServerState.PendingDiplomacyRequests[requestId]
end

-- Clear a pending diplomacy request
function ServerState.clearPendingDiplomacyRequest(requestId)
	ServerState.PendingDiplomacyRequests[requestId] = nil
end

return ServerState