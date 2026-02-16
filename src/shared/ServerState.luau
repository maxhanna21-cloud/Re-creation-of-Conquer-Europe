-- ServerState (ModuleScript in ServerScriptService) - UPDATED v2
-- Centralized registry for shared server data
-- Now includes CountryCoins, CountryManpower, AND OccupiedTerritories

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