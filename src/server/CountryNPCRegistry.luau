-- CountryNPCRegistry
-- Tracks which NPCs (by country) are alive on the server.
-- Used by DiplomacyServer to allow war on unowned countries that still have NPCs.

local CountryNPCRegistry = {}

-- { [countryName] = { [npcModel] = true } }
local CountryNPCIndex = {}

function CountryNPCRegistry.register(countryName, npcModel)
	CountryNPCIndex[countryName] = CountryNPCIndex[countryName] or {}
	CountryNPCIndex[countryName][npcModel] = true
end

function CountryNPCRegistry.unregister(countryName, npcModel)
	local set = CountryNPCIndex[countryName]
	if set then
		set[npcModel] = nil
		-- Release the country table entirely once empty to prevent unbounded growth
		if next(set) == nil then
			CountryNPCIndex[countryName] = nil
		end
	end
end

function CountryNPCRegistry.getNPCs(countryName)
	local set = CountryNPCIndex[countryName]
	if not set then return {} end
	local npcs = {}
	for npc in pairs(set) do
		-- Only include NPCs still present in the data model (guards the Died → Debris window)
		if npc.Parent ~= nil then
			table.insert(npcs, npc)
		end
	end
	return npcs
end

function CountryNPCRegistry.hasNPCs(countryName)
	local set = CountryNPCIndex[countryName]
	if not set then return false end
	-- FIX: Check npc.Parent ~= nil to skip dead NPCs in the Died → Debris window.
	-- Matches the same guard used by getNPCs().
	for npc in pairs(set) do
		if npc.Parent ~= nil then
			return true
		end
	end
	return false
end

return CountryNPCRegistry
