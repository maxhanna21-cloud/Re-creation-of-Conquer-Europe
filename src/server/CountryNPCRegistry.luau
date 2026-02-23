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
	end
end

function CountryNPCRegistry.getNPCs(countryName)
	local set = CountryNPCIndex[countryName]
	if not set then return {} end
	local npcs = {}
	for npc in pairs(set) do
		table.insert(npcs, npc)
	end
	return npcs
end

function CountryNPCRegistry.hasNPCs(countryName)
	local set = CountryNPCIndex[countryName]
	if not set then return false end
	for _ in pairs(set) do
		return true
	end
	return false
end

return CountryNPCRegistry
