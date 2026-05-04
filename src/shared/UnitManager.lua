-- UnitManager (ModuleScript in ServerScriptService - FINAL FIX FOR STACKING) - FIXED
-- FIX #5: Added PlayerRemoving cleanup to prevent memory leak
local Players = game:GetService("Players")

local UnitManager = {}

-- Key: Player object | Value: Table of Units 
local PlayerUnits = {}
local UnitIDCounter = 0
local DEBUG_MODE = false

-- Public API: Register a new unit
function UnitManager.registerUnit(player, npcModel, unitType)
	if not PlayerUnits[player] then
		PlayerUnits[player] = {}
	end

	UnitIDCounter += 1
	local unitID = UnitIDCounter

	PlayerUnits[player][npcModel] = {
		ID = unitID,
		Type = unitType,
		Model = npcModel,
		Position = npcModel:GetPivot().Position -- Will be updated upon spawn
	}

	npcModel.AncestryChanged:Once(function(_, newParent)
		if not newParent then
			UnitManager.deregisterUnit(player, npcModel)
		end
	end)
	npcModel.Destroying:Once(function()
		UnitManager.deregisterUnit(player, npcModel)
	end)

	return unitID
end

-- Public API: Deregister a unit upon destruction
function UnitManager.deregisterUnit(player, npcModel)
	if PlayerUnits[player] and PlayerUnits[player][npcModel] then
		PlayerUnits[player][npcModel] = nil

		if next(PlayerUnits[player]) == nil then
			PlayerUnits[player] = nil 
		end

		if DEBUG_MODE then print("DEBUG: Deregistered unit " .. tostring(npcModel.Name)) end
	end
end

-- Public API: Gets all unit models and positions for a player
function UnitManager.getPlayerUnits(player)
	return PlayerUnits[player] or {}
end

-- Public API: Returns the number of units currently registered for a player
function UnitManager.getUnitCount(player)
	local count = 0
	if PlayerUnits[player] then
		for _ in pairs(PlayerUnits[player]) do
			count += 1
		end
	end
	return count
end

-- Public API: Updates a unit's stored position after it is moved
function UnitManager.updateUnitPosition(player, npcModel, newPosition)
	if PlayerUnits[player] and PlayerUnits[player][npcModel] then
		PlayerUnits[player][npcModel].Position = newPosition
	end
end

-- FIX #5: Clean up player data when they leave to prevent memory leaks
function UnitManager.clearPlayerUnits(player)
	if PlayerUnits[player] then
		PlayerUnits[player] = nil
		if DEBUG_MODE then print("DEBUG: Cleared all units for player " .. player.Name) end
	end
end

-- FIX #5: Connect to PlayerRemoving to automatically clean up
Players.PlayerRemoving:Connect(function(player)
	UnitManager.clearPlayerUnits(player)
end)

return UnitManager